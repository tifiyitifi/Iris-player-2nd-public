import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/features/control_group/model/enum/player_control_group.dart';
import 'package:iris/features/control_group/store/use_control_group_store.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/globals.dart'
    show controlPanelKeyNotifier, sidePanelLayoutWidthNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/overlays/controls_overlay.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// The side panel's hide translation is computed by `ControlsOverlay`, but the
/// box it must clear is rendered by `CircleSliderLayout` — and that box is WIDER
/// than the panel alone: the 副音 quick column is magnetically attached to the
/// panel's centre-facing side, OUTSIDE it (see `withQuickBar`).
///
/// A horizontal hide shifted by the panel width only, so the column — which
/// sits on the far side of the panel, i.e. the side the panel travels TOWARDS —
/// stayed on screen: a column of 副音 buttons stranded next to the video after
/// the panel had gone.
///
/// A vertical drop is unaffected (the column shares the panel's height), so the
/// widget case pins the `horizontal` corner mode.
///
/// The column-OFF case is asserted arithmetically rather than through a second
/// widget mount: the quick-bar switch lives on a `PersistentStore` whose async
/// load can land after the test configures it, so a "must be absent" finder
/// would be measuring load timing, not the hide.
const Size _window = Size(1600, 900);
const double _panelW = 380;

/// Zone widths for the dock sequence: the docked playlist takes the video zone
/// down to a strip the 380px panel just fits in, which is below the budget the
/// 副音 column needs — so the layout drops it there and re-attaches it when the
/// dock closes.
const double _dockClosedWidth = 1600;
const double _dockOpenWidth = 420;

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

Widget _overlay() => ControlsOverlay(
      file: const FileItem(name: 'clip.mp4', uri: 'file:///clip.mp4'),
      title: 'clip.mp4',
      showControl: () {},
      showControlForHover: (_) async {},
      hideControl: () {},
      showProgress: () {},
    );

void _configure() {
  useAppStore().set(useAppStore().state.copyWith(
        useMetadataSettings: true,
        phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
        phoneSidePositionH: PhoneSidePositionH.right,
        phoneSidePositionV: PhoneSidePositionV.bottom,
        sidePanelCornerHideMode: SidePanelCornerHideMode.horizontal,
        sidewayPanelWidthPx: 380,
        sidewayPanelHeightPx: 420,
        runtimeOrientation: ScreenOrientation.landscape,
      ));
  // The install default is ON, so the column is attached without a write.
  useBackgroundPlaybackStore().set(
    useBackgroundPlaybackStore().state.copyWith(quickBarEnabled: true),
  );
  // Group 1 (playback) — group 2 REPLACES the button rows and hides the column.
  useControlGroupStore()
      .set(useControlGroupStore().state.copyWith(group: PlayerControlGroup.playback));
  usePlayerUiStore().updateIsShowControl(false);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
          const MethodChannel('plugins.it_nomads.com/flutter_secure_storage'),
          (call) async => null);
  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    debugIsMobilePlatformOverride = false;
    debugIsDesktopOverride = true;
  });

  late BackgroundPlaybackEngine engine;
  setUp(() {
    engine = BackgroundPlaybackEngine(
      backend: PlayerBackend.mediaKit,
      attachNative: false,
    );
  });
  tearDown(() => engine.dispose());

  /// [areaWidth] is the video zone the overlay is laid out in. The window stays
  /// [_window]: the docked playlist takes the zone, not the screen, and the
  /// overlay sizes the panel off `MediaQuery` — so this reproduces exactly what
  /// the dock does to the bar.
  Widget harness({double areaWidth = _dockClosedWidth}) =>
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
                body: Align(
                  alignment: Alignment.topRight,
                  child: SizedBox(
                    width: areaWidth,
                    height: _window.height,
                    child: _overlay(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );

  testWidgets('a right-docked horizontal hide clears the 副音 column too',
      (tester) async {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    _configure();

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    expect(BackgroundPlaybackGate.enabled, isTrue,
        reason: 'precondition: the feature gate is open on this runner');
    expect(find.byType(BackgroundQuickBar), findsOneWidget,
        reason: 'precondition: the column really is attached');

    final GlobalKey? key = controlPanelKeyNotifier.value;
    expect(key, isNotNull);
    final Rect hidden = tester.getRect(find.byKey(key!));
    // The whole bar — panel AND the column beside it — is off-screen. A
    // panel-width-only shift left the column (which sits to the panel's left)
    // still inside the window.
    expect(hidden.left, greaterThanOrEqualTo(_window.width),
        reason: 'the quick column must leave with the panel');
    expect(hidden.right, greaterThanOrEqualTo(_window.width));
  });

  /// The hide distance is budgeted off the bar's REAL layout zone, which
  /// `CircleSliderLayout` publishes into `sidePanelLayoutWidthNotifier` — and
  /// the docked playlist shrinks it. A bare `.value` read froze both: the
  /// overlay builds before the descendant republishes the zone, and nothing
  /// re-ran the build when it did. The bar was then hidden with a footprint
  /// measured against the wrong zone — and once the zone grew back, the
  /// re-attached column was left standing on screen.
  ///
  /// Dock open → dock closed, with the panel HIDDEN throughout (a hide is only
  /// observable while the bar is off-screen).
  testWidgets('the hide re-budgets when the bar layout zone changes',
      (tester) async {
    tester.view.physicalSize = _window;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    addTearDown(() => sidePanelLayoutWidthNotifier.value = null);
    _configure();

    Future<double> setZone(double width) async {
      await tester.pumpWidget(harness(areaWidth: width));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      return tester.getRect(find.byKey(controlPanelKeyNotifier.value!)).left;
    }

    final double closedLeft = await setZone(_dockClosedWidth);
    final double? wideZone = sidePanelLayoutWidthNotifier.value;
    expect(wideZone, isNotNull,
        reason: 'precondition: the bar published its layout zone');
    expect(find.byType(BackgroundQuickBar), findsOneWidget,
        reason: 'precondition: the wide zone attaches the column');
    expect(closedLeft, greaterThanOrEqualTo(_dockClosedWidth),
        reason: 'precondition: the column starts off-screen');

    // Dock open: the zone drops below `panel + gap + min`, so the layout
    // itself drops the column.
    expect(await setZone(_dockOpenWidth), greaterThanOrEqualTo(_dockOpenWidth));
    expect(sidePanelLayoutWidthNotifier.value, lessThan(wideZone!),
        reason: 'precondition: the layout really republished the zone');
    expect(find.byType(BackgroundQuickBar), findsNothing,
        reason: 'precondition: the narrow zone drops the column');

    // Dock closed again: the column re-attaches, so the hide has to grow back
    // to cover it. Measured against the stale narrow zone it stays at the
    // panel-only width and strands the column on screen.
    final double left = await setZone(_dockClosedWidth);
    expect(find.byType(BackgroundQuickBar), findsOneWidget,
        reason: 'precondition: the column is attached again');
    expect(left, greaterThanOrEqualTo(_dockClosedWidth),
        reason: 'the re-attached 副音 column must leave with the panel');
  });

  test('a horizontal hide clears the column; a vertical one needs no extra room',
      () {
    final double quickAvail = sidewayQuickAvailWidth(
      layoutWidth: _window.width,
      panelW: _panelW,
    );
    expect(showsSidewayQuickColumn(
      isPhone: false,
      gateEnabled: true,
      quickBarEnabled: true,
      showingBackgroundGroup: false,
      quickAvail: quickAvail,
    ), isTrue);
    final double columnW =
        sidewayQuickColumnWidth(quickAvail: quickAvail, panelH: 420);
    expect(columnW, greaterThan(0));
    final double footprintW = _panelW + kSidewayQuickGap + columnW;

    // Horizontal: the bar is right-docked, so it starts at `window - panelW`
    // and must travel the WHOLE footprint to put its left edge past the right
    // window edge — a panel-width-only shift strands the column, which is
    // rendered to the panel's left.
    // Vertical: the column shares the panel's height, so panelH already clears
    // it and widening would over-shoot for nothing.
    const double margin = 24;
    final Offset horizontal = hideTranslateForAnchor(
      anchor: Alignment.bottomRight,
      isLeftHanded: false,
      panelW: footprintW,
      panelH: 420,
      cornerMode: SidePanelCornerHideMode.horizontal,
    );
    expect(
      (_window.width - _panelW) + horizontal.dx,
      greaterThanOrEqualTo(_window.width),
      reason: 'the column sits on the near side of the panel, so the shift '
          'must cover the whole footprint',
    );
    expect(
      hideTranslateForAnchor(
        anchor: Alignment.bottomRight,
        isLeftHanded: false,
        panelW: _panelW,
        panelH: 420,
        cornerMode: SidePanelCornerHideMode.vertical,
      ),
      const Offset(0, 420 + margin),
    );
  });
}
