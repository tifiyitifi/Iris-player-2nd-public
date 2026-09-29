import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/view/control_target_indicator.dart';
import 'package:iris/globals.dart' show controlPanelKeyNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart'
    show PhoneLandscapeUseModeHelper;
import 'package:iris/pages/player/control_bar/legacy_control_bar.dart';
import 'package:iris/pages/player/overlays/controls_overlay.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// `ControlsOverlay` decides THREE things about the child it renders: where it
/// PLACES the bar box, the DIRECTION it translates the bar away on hide, and
/// the `isSide` it passes to the 副音 align editor. All three used to derive
/// from the one-handed use mode alone, while the child itself is chosen
/// separately — `useLegacy ? LegacyControlBar : ControlBar`.
///
/// `useLegacyControlBar` is a user-facing switch with no gate on it
/// (`show_legacy_compat_dialog.dart` leaves it interactable while the master
/// gate is off), and `LegacyControlBar` never imports `CircleSliderLayout` or
/// `PhoneOneHandedScrubber`. So a one-handed mode under the legacy bar rendered
/// a FULL-WIDTH linear bar that the overlay then placed by the side anchor,
/// translated sideways on hide — leaving a strip of it on screen, since a
/// full-width box shifted by one panel width is not off-screen.
///
/// The PLACEMENT carries the same legacy veto, with one exception: the legacy
/// bar's own narrow circle column (gate OFF + a stored circle placement) really
/// is a side box, and the resolver's legacy corner is exactly where it belongs.
const Size _window = Size(800, 360);

MediaPlayer _player() => MediaPlayer(
      isInitializing: false,
      isPlaying: false,
      externalSubtitles: const [],
      position: const Duration(seconds: 12),
      duration: const Duration(hours: 1),
      buffer: Duration.zero,
      width: 16,
      height: 9,
      saveProgress: () async {},
      play: () async {},
      pause: () async {},
      backward: (_) async {},
      forward: (_) async {},
      stepBackward: () async {},
      stepForward: () async {},
      seek: (_) async {},
    );

Widget _shell(Widget body, BackgroundPlaybackEngine engine) =>
    InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: Provider<MediaPlayer>.value(
        value: _player(),
        child: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
          value: engine,
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              body: SizedBox(
                width: _window.width,
                height: _window.height,
                child: body,
              ),
            ),
          ),
        ),
      ),
    );

Widget _overlay(FileItem file) => ControlsOverlay(
      file: file,
      title: 'clip.mp4',
      showControl: () {},
      showControlForHover: (_) async {},
      hideControl: () {},
      showProgress: () {},
    );

const FileItem _video = FileItem(name: 'clip.mp4', uri: 'file:///clip.mp4');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  late BackgroundPlaybackEngine engine;
  setUp(() {
    engine = BackgroundPlaybackEngine(
      backend: PlayerBackend.mediaKit,
      attachNative: false,
    );
  });
  tearDown(() => engine.dispose());

  /// The REAL Android pair: the panel's host gate reads `isDesktop`, so leaving
  /// that true on this desktop runner would answer with the runner's platform.
  void asPhone() {
    debugIsMobilePlatformOverride = true;
    debugIsDesktopOverride = false;
    addTearDown(() {
      debugIsMobilePlatformOverride = null;
      debugIsDesktopOverride = null;
    });
  }

  /// The runner already answers desktop, but the panel's host gate reads
  /// `isDesktop`, so pin BOTH seams the way [asPhone] does — a case that only
  /// forced the phone side would answer with the runner's platform for the
  /// other half of every `isPhone` / `isDesktop` branch.
  void asDesktop() {
    debugIsMobilePlatformOverride = false;
    debugIsDesktopOverride = true;
    addTearDown(() {
      debugIsMobilePlatformOverride = null;
      debugIsDesktopOverride = null;
    });
  }

  void sizeTo(WidgetTester tester) {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
  }

  void configure({
    required bool legacyControlBar,
    required bool showControl,
    SidePanelCornerHideMode cornerHide = SidePanelCornerHideMode.vertical,
    bool metadata = true,
    PhoneSidePositionH posH = PhoneSidePositionH.right,
    PhoneSidePositionV posV = PhoneSidePositionV.bottom,
    PhoneLandscapeSliderType sliderType = PhoneLandscapeSliderType.normal,
  }) {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: metadata,
          useLegacyControlBar: legacyControlBar,
          phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
          mobileSidePositionH: PhoneSidePositionH.right,
          phoneSidePositionH: posH,
          phoneSidePositionV: posV,
          phoneLandscapeSliderType: sliderType,
          sidewayPanelWidthPct: 40,
          sidewayPanelHeightPct: 90,
          // `vertical` is the default and slides a BOTTOM-RIGHT panel straight
          // down — the same axis a linear bar uses, so it cannot tell the two
          // layouts apart. `horizontal` is the discriminating case, and it is
          // the one the bug was reported against: a full-width bar shifted
          // sideways by one panel width is not off-screen.
          mobileSidePanelCornerHideMode: cornerHide,
          runtimeOrientation: ScreenOrientation.landscape,
        ));
    usePlayerUiStore().updateIsShowControl(showControl);
  }

  testWidgets('a one-handed mode under the legacy bar hides DOWNWARD, not '
      'sideways', (tester) async {
    asPhone();
    sizeTo(tester);
    configure(
      legacyControlBar: true,
      showControl: false,
      cornerHide: SidePanelCornerHideMode.horizontal,
    );

    await tester.pumpWidget(_shell(_overlay(_video), engine));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // Precondition: the child really is the legacy (linear) bar, and the stored
    // mode really is one-handed — otherwise this case proves nothing.
    expect(find.byType(LegacyControlBar), findsOneWidget);
    expect(useAppStore().state.phoneLandscapeUseMode.usesOneHandedControls,
        isTrue);

    final GlobalKey? key = controlPanelKeyNotifier.value;
    expect(key, isNotNull, reason: 'the bar must publish its box');
    final Rect rect = tester.getRect(find.byKey(key!));
    // A linear bar always leaves through the bottom edge, whatever the side
    // panel's corner mode is. Treating it as a side panel would have shifted it
    // right by (panel width + margin) instead, leaving the bar sitting on screen
    // with its right half off the edge.
    expect(rect.top, greaterThanOrEqualTo(_window.height),
        reason: 'a hidden linear bar leaves through the bottom edge');
  });

  testWidgets('the legacy bar gets a square frame, not the side panel radius',
      (tester) async {
    asPhone();
    sizeTo(tester);
    configure(legacyControlBar: true, showControl: true);

    await tester.pumpWidget(_shell(_overlay(_video), engine));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    // The 副音 target frame rounds its corners only for a side panel. This
    // signal holds whether the bar is shown or hidden, so it pins the flag
    // independently of the hide direction.
    final Iterable<BackgroundControlTargetIndicator> frames = tester
        .widgetList<BackgroundControlTargetIndicator>(
            find.byType(BackgroundControlTargetIndicator));
    expect(frames, isNotEmpty);
    for (final BackgroundControlTargetIndicator frame in frames) {
      expect(frame.borderRadius, const BorderRadius.all(Radius.circular(0)),
          reason: 'a full-width linear bar is not a side panel');
    }
  });

  testWidgets('the veto must not take the one-handed panel with it',
      (tester) async {
    asPhone();
    sizeTo(tester);
    // The real bar, one-handed phone in landscape: the whole feature.
    configure(
      legacyControlBar: false,
      showControl: false,
      cornerHide: SidePanelCornerHideMode.horizontal,
    );

    await tester.pumpWidget(_shell(_overlay(_video), engine));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final GlobalKey? key = controlPanelKeyNotifier.value;
    expect(key, isNotNull);
    final Rect rect = tester.getRect(find.byKey(key!));
    // A side panel is NOT full width, and with the horizontal corner mode it
    // leaves through its own edge — the window's right one at a right anchor.
    expect(rect.width, lessThan(_window.width));
    expect(rect.right, greaterThan(_window.width),
        reason: 'the panel slid clear through the right edge');
    expect(rect.left, greaterThan(0),
        reason: 'and it is a panel, not a full-width bar pinned at x=0');

    final Iterable<BackgroundControlTargetIndicator> frames = tester
        .widgetList<BackgroundControlTargetIndicator>(
            find.byType(BackgroundControlTargetIndicator));
    expect(frames, isNotEmpty);
    for (final BackgroundControlTargetIndicator frame in frames) {
      expect(frame.borderRadius, const BorderRadius.all(Radius.circular(12)),
          reason: 'the side panel keeps its rounded corner');
    }
  });

  // ── The ALIGNMENT the veto governs ────────────────────────────────────────
  //
  // A full-width linear bar is byte-identical at bottomLeft and bottomCenter,
  // so the horizontal half of the side anchor is invisible here and needs no
  // case. The vertical half is not: posV is the side PANEL's row, and pairing
  // it with the linear downward hide parks the bar against the top edge and
  // then sends it across the whole video on every hide. posV only reaches the
  // resolver on desktop (the phone branch hard-codes the bottom), so this case
  // has to run as one.

  testWidgets('a linear legacy bar stays at the bottom whatever posV says',
      (tester) async {
    asDesktop();
    sizeTo(tester);
    configure(
      legacyControlBar: true,
      showControl: true,
      posH: PhoneSidePositionH.right,
      posV: PhoneSidePositionV.top,
    );

    await tester.pumpWidget(_shell(_overlay(_video), engine));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byType(LegacyControlBar), findsOneWidget);
    final GlobalKey? key = controlPanelKeyNotifier.value;
    expect(key, isNotNull, reason: 'the bar must publish its box');
    final Rect rect = tester.getRect(find.byKey(key!));
    expect(rect.top, greaterThan(_window.height / 2),
        reason: 'a linear bar belongs at the bottom edge, not the panel\'s');
    // Paired with the one above so a HIDDEN bar cannot pass: the linear hide
    // translates it past the bottom edge, which only satisfies the first.
    expect(rect.bottom, lessThanOrEqualTo(_window.height),
        reason: 'and it must still be inside the window — i.e. actually shown');
  });

  testWidgets('the veto must not take the legacy narrow circle column with it',
      (tester) async {
    asPhone();
    sizeTo(tester);
    // Gate OFF + a legacy circle placement: the ONE child that really is a side
    // box, since its column is sized to a fraction of the window. The
    // resolver's legacy branch docks that column at the corner, and a blanket
    // "legacy means bottom-centre" would silently relocate a frozen layout.
    configure(
      legacyControlBar: true,
      showControl: true,
      metadata: false,
      sliderType: PhoneLandscapeSliderType.circleRight,
    );

    await tester.pumpWidget(_shell(_overlay(_video), engine));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(find.byType(LegacyControlBar), findsOneWidget);
    final GlobalKey? key = controlPanelKeyNotifier.value;
    expect(key, isNotNull);
    final Rect rect = tester.getRect(find.byKey(key!));
    expect(rect.width, lessThan(_window.width),
        reason: 'a sized column, not a full-width bar');
    expect(rect.right, closeTo(_window.width, 1.0),
        reason: 'circleRight still docks at the right corner');
  });
}
