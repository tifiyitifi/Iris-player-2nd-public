import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/globals.dart' show sidePanelKeyNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/circle_slider_layout.dart';
import 'package:iris/pages/player/control_bar/control_bar_layout/control_bar_controls.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/dialogs/show_slider_type_dialog.dart';
import 'package:provider/provider.dart';

/// The 副音 quick strip's cross-axis budget comes from the zone the control
/// bar is REALLY laid out in, not the raw window width — a docked playlist
/// shrinks that zone (see `CircleSliderLayout`'s own comment on `layoutW`).
///
/// The side-panel settings dialog re-derives the panel's footprint, so it has
/// to budget the strip off the same zone or it reserves a strip the layout
/// never attached. These tests mount a REAL `CircleSliderLayout` inside a
/// narrow zone under a wide window and read the panel's on-screen rect off the
/// published key, so the expectation is measured rather than restated.
///
/// One `testWidgets` on purpose: `StoreScope.dispose()` disposes every store
/// the locator manages, so a second test here could only mutate a closed store.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Wide window, narrow bar zone: the two are independent, which is the whole
  // point — the docked playlist is what makes the zone smaller than the window.
  const Size screen = Size(1600, 720);
  const Key cardKey = Key('side-slider-panel-card');
  const double panelW = 380;
  const double panelH = 420;
  final ValueNotifier<double> zoneWidth = ValueNotifier<double>(1600);

  MediaPlayer player() => MediaPlayer(
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

  ControlBarControls controls() => ControlBarControls(
        showControl: () {},
        showControlForHover: (_) async {},
        color: Colors.white,
        overlayColor: null,
        file: const FileItem(name: 'a.mp4', uri: 'file:///a.mp4'),
        circleScale: 0.5,
      );

  Widget harness() => StoreScope(
        child: Provider<MediaPlayer>.value(
          value: player(),
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: Scaffold(
              // Stands in for the docked playlist: it constrains the control
              // bar's zone without touching the window size the dialog reads.
              body: ValueListenableBuilder<double>(
                valueListenable: zoneWidth,
                builder: (BuildContext context, double w, Widget? _) => Stack(
                  children: <Widget>[
                    Align(
                      alignment: Alignment.bottomRight,
                      child: SizedBox(
                        width: w,
                        child: CircleSliderLayout(
                          width: 1280,
                          panelPercent: 30,
                          controls: controls(),
                          scrubberBuilder: (double? _, double? __) =>
                              const SizedBox.shrink(),
                        ),
                      ),
                    ),
                    Center(
                      child: Builder(
                        builder: (BuildContext context) => TextButton(
                          onPressed: () => showSliderTypeDialog(context),
                          child: const Text('open'),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      );

  /// Left edge of the footprint the dialog would reserve if it budgeted the
  /// strip off the RAW WINDOW width instead of the bar's real zone.
  double phantomFootprintLeft() {
    final double quickAvail =
        sidewayQuickAvailWidth(layoutWidth: screen.width, panelW: panelW);
    return screen.width -
        panelW -
        kSidewayQuickGap -
        sidewayQuickColumnWidth(quickAvail: quickAvail, panelH: panelH);
  }

  Future<void> openDialog(WidgetTester tester) async {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  setUpAll(() async {
    const secureStorageChannel =
        MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(secureStorageChannel, (call) async => null);
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  testWidgets('the free region budgets the 副音 strip off the bar\'s real zone',
      (tester) async {
    debugIsMobilePlatformOverride = false;
    addTearDown(() => debugIsMobilePlatformOverride = null);
    // 1:1 so `screen` IS the logical size the panel geometry is derived from.
    tester.view.devicePixelRatio = 1.0;
    tester.view.physicalSize = screen;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    // Parked at the region's RIGHT edge (frac 1,0) so the card's own width cap
    // (380) cannot hide the region's width behind it.
    useAppStore().set(const AppState(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
      phoneSidePositionH: PhoneSidePositionH.right,
      phoneSidePositionV: PhoneSidePositionV.bottom,
      sidewayPanelWidthPx: panelW,
      sidewayPanelHeightPx: panelH,
      sidePanelDialogOffset: Offset(1, 0),
    ));
    useBackgroundPlaybackStore().set(
        useBackgroundPlaybackStore().state.copyWith(quickBarEnabled: true));

    // ── Zone 1: wide enough for the strip, but only ONE column fits ────────
    // 460px zone → budget 68px, which the 2-column grid (needs 108) misses, so
    // the layout renders a 52px single column. The raw 900px window would
    // instead admit 2 columns (108px) and the dialog would over-reserve 56px.
    zoneWidth.value = 460;
    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final Rect oneColumn =
        tester.getRect(find.byKey(const ValueKey('bg_quick_bar')));
    expect(oneColumn.width, closeTo(52, 0.01),
        reason: 'premise: the real zone affords exactly one quick column');

    await openDialog(tester);
    Rect card = tester.getRect(find.byKey(cardKey));
    Rect panelBox = tester.getRect(find.byKey(sidePanelKeyNotifier.value!));
    expect(card.right, lessThanOrEqualTo(panelBox.left + 0.01),
        reason: 'the card must clear the REAL panel box');
    expect(card.right, greaterThan(phantomFootprintLeft()),
        reason: 'the 副音 strip was budgeted off the raw window width, so a '
            'phantom second column is reserved and the card is squeezed');

    // ── Zone 2: starved below the strip's minimum → the layout drops it ─────
    // 420px zone → budget 28px < kSidewayQuickMinWidth, so nothing is
    // attached at all. Budgeting off the window would still reserve 112px.
    await tester.tap(find.byIcon(Icons.close_rounded));
    await tester.pumpAndSettle();
    zoneWidth.value = 420;
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_bar')), findsNothing,
        reason: 'premise: the real zone starves the strip entirely');

    await openDialog(tester);
    card = tester.getRect(find.byKey(cardKey));
    panelBox = tester.getRect(find.byKey(sidePanelKeyNotifier.value!));
    expect(card.right, lessThanOrEqualTo(panelBox.left + 0.01),
        reason: 'the card must still clear the real panel box');
    expect(card.right, greaterThan(phantomFootprintLeft()),
        reason: 'a strip the layout DROPPED must hand its whole width back to '
            'the card');
  });
}
