import 'package:drift/native.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';

import 'helpers/sqlite3_loader.dart';

/// The side-panel settings dialog must (a) never cover the side-type control
/// slider it edits, and (b) never persist while a slider / panel drag is in
/// flight — one commit at drag end is the whole budget.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  late AppDatabase db;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close);

  group('sidePanelRectForWindow', () {
    test('bottom-right phone anchor sits flush to the corner', () {
      final rect = sidePanelRectForWindow(
        windowSize: const Size(800, 360),
        anchor: Alignment.bottomRight,
        isPhone: true,
        widthPct: 40,
        heightPct: 90,
        widthPx: 380,
        heightPx: 420,
      );
      expect(rect.left, 800 - 320);
      expect(rect.top, 360 - 324);
      expect(rect.width, 320);
      expect(rect.height, 324);
    });
  });

  group('regionAvoidingPanel', () {
    test('drops the panel band entirely (no overlap possible)', () {
      const Rect panel = Rect.fromLTWH(480, 0, 320, 360);
      final Rect region = regionAvoidingPanel(
        screen: const Size(800, 360),
        safe: EdgeInsets.zero,
        panel: panel,
      );
      // Panel is on the right → the free strip is on the left.
      expect(region.right, lessThanOrEqualTo(panel.left));
      expect(region.overlaps(panel), isFalse);
    });

    test('picks the larger strip when the panel hugs the left edge', () {
      const Rect panel = Rect.fromLTWH(0, 0, 320, 360);
      final Rect region = regionAvoidingPanel(
        screen: const Size(800, 360),
        safe: EdgeInsets.zero,
        panel: panel,
      );
      expect(region.left, greaterThanOrEqualTo(panel.right));
      expect(region.overlaps(panel), isFalse);
    });

    test('falls back to the full safe screen without a panel', () {
      final Rect region = regionAvoidingPanel(
        screen: const Size(800, 360),
        safe: EdgeInsets.zero,
        panel: null,
      );
      expect(region, const Rect.fromLTRB(8, 8, 792, 352));
    });

    test('honours system-bar padding', () {
      final Rect region = regionAvoidingPanel(
        screen: const Size(800, 360),
        safe: const EdgeInsets.fromLTRB(40, 4, 4, 24),
        panel: null,
      );
      expect(region, const Rect.fromLTRB(48, 12, 788, 328));
    });

    // A strip too narrow for the card is worse than covering a sliver of the
    // panel: the card's body is a column of 380-max form rows, so a 12px strip
    // renders an unreadable sliver that still hides what it edits. The floor
    // makes the function answer "no usable strip" and the caller lay out in the
    // full safe screen instead.
    test('a strip too narrow to host the card falls back to the full screen',
        () {
      // Centred 90%-wide panel on a 400px screen: 12px on each side.
      final Rect region = regionAvoidingPanel(
        screen: const Size(400, 800),
        safe: EdgeInsets.zero,
        panel: const Rect.fromLTWH(20, 0, 360, 800),
      );
      expect(region, const Rect.fromLTRB(8, 8, 392, 792),
          reason: 'no strip can host the card — take the whole safe screen');
    });

    test('the narrowness floor is exact, not a rounding band', () {
      // Left strip 8..288 = 280 exactly: usable, keep it.
      final Rect atFloor = regionAvoidingPanel(
        screen: const Size(800, 360),
        safe: EdgeInsets.zero,
        panel: const Rect.fromLTWH(288, 0, 504, 360),
      );
      expect(atFloor, const Rect.fromLTRB(8, 8, 288, 352));

      // One pixel narrower: 8..287 = 279, already unusable.
      final Rect belowFloor = regionAvoidingPanel(
        screen: const Size(800, 360),
        safe: EdgeInsets.zero,
        panel: const Rect.fromLTWH(287, 0, 505, 360),
      );
      expect(belowFloor, const Rect.fromLTRB(8, 8, 792, 352));
    });
  });

  // The 副音 quick column hangs off the panel's centre-facing side, so a
  // "panel rect" that ignores it is not the control panel's real footprint —
  // the settings card would still park on top of half the buttons it edits.
  group('showsSidewayQuickColumn', () {
    bool attached({
      bool isPhone = false,
      bool gateEnabled = true,
      bool quickBarEnabled = true,
      bool showingBackgroundGroup = false,
      double quickAvail = 400,
    }) =>
        showsSidewayQuickColumn(
          isPhone: isPhone,
          gateEnabled: gateEnabled,
          quickBarEnabled: quickBarEnabled,
          showingBackgroundGroup: showingBackgroundGroup,
          quickAvail: quickAvail,
        );

    test('desktop + switch ON + playback group attaches it', () {
      expect(attached(), isTrue);
    });

    test('a phone never attaches it (the bottom group switch owns 副音)', () {
      expect(attached(isPhone: true), isFalse);
    });

    test('the 副音 feature gate being off means no column at all', () {
      expect(attached(gateEnabled: false), isFalse);
    });

    test('the quick-bar switch alone is not enough', () {
      expect(attached(quickBarEnabled: false), isFalse);
    });

    test('group 2 REPLACES the button rows, so nothing is attached', () {
      expect(attached(showingBackgroundGroup: true), isFalse);
    });

    test('a starved budget drops the column instead of squashing it', () {
      expect(attached(quickAvail: kSidewayQuickMinWidth - 1), isFalse);
      expect(attached(quickAvail: kSidewayQuickMinWidth), isTrue);
    });
  });

  group('sidewayQuickAvailWidth', () {
    test('mirrors the layout budget: padding margin, panel, gap', () {
      expect(sidewayQuickAvailWidth(layoutWidth: 1600, panelW: 380), 1208);
    });
  });

  group('sidewayQuickColumnWidth', () {
    test('a tall panel keeps the strip in ONE column', () {
      // 10 actions at 52px per row: 600px of height fits 11 rows.
      expect(sidewayQuickColumnWidth(quickAvail: 400, panelH: 600), 52);
    });

    test('a short panel widens to the two-column cap', () {
      // 420px fits 8 rows, so the 10 actions need the second column.
      expect(sidewayQuickColumnWidth(quickAvail: 400, panelH: 420), 108);
    });

    test('a budget too narrow for two columns stays at one', () {
      // maxCols collapses to 1 below 56px (one column + the inter-column gap).
      expect(sidewayQuickColumnWidth(quickAvail: 50, panelH: 600), 52);
    });
  });

  group('sidePanelRectForWindow — 副音 column included', () {
    Rect rectFor(Alignment anchor, {double quickColumnWidth = 0}) =>
        sidePanelRectForWindow(
          windowSize: const Size(1600, 900),
          anchor: anchor,
          isPhone: false,
          widthPct: 40,
          heightPct: 90,
          widthPx: 380,
          heightPx: 420,
          quickColumnWidth: quickColumnWidth,
        );

    test('a right-docked panel grows the rect to cover the column LEFT of it', () {
      final Rect rect = rectFor(Alignment.bottomRight, quickColumnWidth: 108);
      expect(rect.right, 1600);
      expect(rect.width, 380 + kSidewayQuickGap + 108);
      expect(rect.left, 1600 - 492);
      expect(rect.height, 420, reason: 'the column shares the panel height');
    });

    test('a left-docked panel grows the rect to the right', () {
      final Rect rect = rectFor(Alignment.bottomLeft, quickColumnWidth: 108);
      expect(rect.left, 0);
      expect(rect.width, 492);
      expect(rect.right, 492);
    });

    test('a centre dock has no centre-facing side, so the column goes right', () {
      // Mirrors CircleSliderLayout (`quickOnLeft = anchor.x > 0`).
      final Rect rect = rectFor(Alignment.bottomCenter, quickColumnWidth: 108);
      expect(rect.left, 610);
      expect(rect.right, 1102);
    });

    test('no column (default) keeps the plain panel box', () {
      expect(rectFor(Alignment.bottomRight),
          const Rect.fromLTRB(1220, 480, 1600, 900));
    });

    test('a dial wider than the drag width grows the rect (phone classic)',
        () {
      // The panel is dragged to its 200px phone floor, but the classic circle
      // is at its 260px maximum, so the layout FILLS 260 — a card sized by the
      // 200 drag width would sit on the extra 60.
      final Rect rect = sidePanelRectForWindow(
        windowSize: const Size(800, 400),
        anchor: Alignment.bottomRight,
        isPhone: true,
        widthPct: 25,
        heightPct: 90,
        widthPx: 380,
        heightPx: 420,
        dialDiameter: 260,
      );
      expect(rect.width, 260);
      expect(rect.right, 800);
    });

    test('the dial floor and the column compose', () {
      final Rect rect = sidePanelRectForWindow(
        windowSize: const Size(800, 400),
        anchor: Alignment.bottomRight,
        isPhone: false,
        widthPct: 40,
        heightPct: 90,
        widthPx: 300,
        heightPx: 420,
        dialDiameter: 420,
        quickColumnWidth: 108,
      );
      // 420 (floor) + gap + 108 column, right-docked so the column is inside.
      expect(rect.right, 800);
      expect(rect.width, 420 + kSidewayQuickGap + 108);
    });
  });

  group('phonePanelMinPct', () {
    test('matches the rendered floor so the slider has no dead zone', () {
      expect(phonePanelMinPct(windowExtent: 800, minPx: kPanelMinPxW), 25);
      expect(phonePanelMinPct(windowExtent: 360, minPx: kPanelMinPxH),
          closeTo(44.44, 0.01));
    });

    test('never drops below the 10% slider floor', () {
      expect(phonePanelMinPct(windowExtent: 4000, minPx: kPanelMinPxW), 10);
    });

    test('degenerate window pins to 100 (empty draggable range)', () {
      expect(phonePanelMinPct(windowExtent: 100, minPx: kPanelMinPxW), 100);
      expect(phonePanelMinPct(windowExtent: 0, minPx: kPanelMinPxW), 100);
    });
  });

  group('persist-on-end', () {
    setUp(() async {
      await MetaSettingsModule.repo.clearValues();
    });

    test('slider drag frames stay memory-only; the commit writes once',
        () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      for (int i = 0; i < 20; i++) {
        await store.updateSidewayPanelWidthPct(40 + i.toDouble(), persist: false);
      }
      var raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw.containsKey('slider.widthPct'), isFalse,
          reason: 'nothing may land mid-drag');
      expect(store.state.sidewayPanelWidthPct, 59,
          reason: 'memory still reflects the live drag');

      await store.updateSidewayPanelWidthPct(60);
      raw = await MetaSettingsModule.repo.loadRawValues();
      expect(double.parse(raw['slider.widthPct']!), 60);
    });

    test('dial + circle tuning persist only on commit', () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      await store.updateRingDialHeightPct(0.55, persist: false);
      await store.updateCircleSliderScale(0.42, persist: false);
      var raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw.containsKey('dialring.ringDialHeightPct'), isFalse);
      expect(raw.containsKey('app.circleSliderScale'), isFalse);

      await store.updateRingDialHeightPct(0.8);
      await store.updateCircleSliderScale(0.6);
      raw = await MetaSettingsModule.repo.loadRawValues();
      expect(double.parse(raw['dialring.ringDialHeightPct']!), 0.8);
      expect(raw.containsKey('app.circleSliderScale'), isTrue);
    });

    test('persistSidewayPanelGeometry commits the current values once',
        () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      debugIsMobilePlatformOverride = true;
      addTearDown(() => debugIsMobilePlatformOverride = null);

      await store.updateSidewayPanelWidthPct(55, persist: false);
      await store.updateSidewayPanelHeightPct(70, persist: false);
      var raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw.containsKey('slider.widthPct'), isFalse);

      await store.persistSidewayPanelGeometry();
      raw = await MetaSettingsModule.repo.loadRawValues();
      expect(double.parse(raw['slider.widthPct']!), 55);
      expect(double.parse(raw['slider.heightPct']!), 70);
      expect(raw.containsKey('slider.handleInsetH'), isTrue);
      expect(raw.containsKey('slider.handleInsetV'), isTrue);
    });

    test('bottom button-bar position is memory-only mid-drag, commits once',
        () async {
      final store = AppStore();
      await store.setMetadataGate(true);

      for (int i = 0; i < 10; i++) {
        await store.updateSidewayBarPos(i / 10, persist: false);
      }
      var raw = await MetaSettingsModule.repo.loadRawValues();
      expect(raw.containsKey('slider.barPos'), isFalse,
          reason: 'nothing may land mid-drag');
      expect(store.state.sidewayBarPos, closeTo(0.9, 1e-9),
          reason: 'memory still reflects the live drag');

      await store.updateSidewayBarPos(0.35);
      raw = await MetaSettingsModule.repo.loadRawValues();
      expect(double.parse(raw['slider.barPos']!), closeTo(0.35, 1e-9));
    });

    test('bottom button-bar position clamps to 0..1', () async {
      final store = AppStore();
      await store.setMetadataGate(true);
      await store.updateSidewayBarPos(2.5, persist: false);
      expect(store.state.sidewayBarPos, 1.0);
      await store.updateSidewayBarPos(-1, persist: false);
      expect(store.state.sidewayBarPos, 0.0);
    });
  });
}
