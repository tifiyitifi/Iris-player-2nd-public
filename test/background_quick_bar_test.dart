import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_quick_bar.dart';
import 'package:iris/features/background_playback/view/background_quick_bar_grid.dart';
import 'package:iris/features/background_playback/view/control_target_indicator.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

FileItem _media(String name) =>
    FileItem(name: name, uri: 'file:///$name', path: [name]);

/// 第 3/4 轮: the 副音 quick bar carries ONLY 副音-specific actions — transport,
/// shuffle and repeat already live on the bottom bar and the queue page.
Widget _providerScope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );

Widget _harness({Axis axis = Axis.horizontal, double? width}) => _providerScope(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            child: BackgroundQuickBar(axis: axis, width: width),
          ),
        ),
      ),
    );

/// Vertical strip in a fixed slot — the phone side panel's real shape.
Widget _verticalHarness({
  required double height,
  required double width,
  bool mirror = false,
}) =>
    _providerScope(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            // Only the height is tight (like the real side panel slot); the
            // width stays loose so the grid can shrink-wrap to its columns.
            child: SizedBox(
              height: height,
              child: BackgroundQuickBar(
                axis: Axis.vertical,
                width: width,
                mirrorColumns: mirror,
              ),
            ),
          ),
        ),
      ),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const ch = MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(ch, (call) async => null);

  setUp(() {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
    ));
  });

  // Drop the app-wide singletons so every test builds its stores inside its own
  // fake-async zone — the play queue the per-media state resolves against would
  // otherwise be created in an earlier test's zone and never complete `load`
  // here.
  tearDown(() {
    StoreLocator().delete(BackgroundPlaybackStore);
    StoreLocator().delete(UnifiedPlayQueueStore);
    StoreLocator().delete(AppStore);
  });

  /// Puts [name] on screen in the play queue — the 作用范围 identity the quick
  /// bar resolves its per-media state against.
  Future<void> playForeground(String name) async {
    final pq = usePlayQueueStore();
    await pq.initialized;
    await pq.update(
      playQueue: [PlayQueueItem(file: _media(name), index: 0)],
      index: 0,
    );
  }

  Future<String> foregroundKey(String name) async =>
      backgroundMediaKey(_media(name));

  Future<void> enable() async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: true, quickBarEnabled: true));
  }

  testWidgets('stays visible while 副音 is off (switch reachable)',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: false, quickBarEnabled: true));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bg_quick_bar')), findsOneWidget);
    // The gate is the ONE play/stop permission: it stays live while 副音 is off
    // so a tap can arm and start 副音 for the current media.
    expect(find.byIcon(Icons.play_circle_rounded), findsOneWidget,
        reason: 'the gate (stopped) must stay reachable — no power glyph');
    expect(find.byIcon(Icons.music_off_rounded), findsNothing,
        reason: 'the redundant separate power switch was removed');
    final applyBtn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.play_circle_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(applyBtn.onPressed, isNotNull);
    // The routing rows are inert until 副音 is on…
    final controlBtn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.settings_input_component_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(controlBtn.onPressed, isNull);
    // …but the saved preferences stay pre-configurable even while off.
    final alignBtn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.align_vertical_center_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(alignBtn.onPressed, isNotNull);
  });

  testWidgets('an open gate keeps the stop glyph while bg is user-paused',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    await playForeground('fg.mp4');
    // Activation (gateOpen) survives the transport pause (bgAutoPlay off) —
    // and the run is anchored to the media on screen (仅当前).
    bg.set(bg.state.copyWith(
      enabled: true,
      quickBarEnabled: true,
      gateOpen: true,
      bgAutoPlay: false,
      scopeAnchorKey: await foregroundKey('fg.mp4'),
    ));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.stop_circle_rounded), findsOneWidget,
        reason: 'pausing bg must not cancel the activation glyph');
    expect(find.byIcon(Icons.play_circle_rounded), findsNothing);
  });

  testWidgets('仅当前: another media reads as NOT activated', (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    await playForeground('B.mp4');
    // The run is anchored to A while B plays: 副音 is paused for B, so the
    // gate must offer "play 副音 for the current video" — not "stop", which
    // would latch the whole run closed over a media switch.
    bg.set(bg.state.copyWith(
      enabled: true,
      quickBarEnabled: true,
      gateOpen: true,
      bgAutoPlay: false,
      scopeAnchorKey: await foregroundKey('A.mp4'),
    ));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_circle_rounded), findsOneWidget);
    expect(find.byIcon(Icons.stop_circle_rounded), findsNothing);
    // The runtime rows are inert for a media 副音 does not play.
    final controlBtn = tester.widget<IconButton>(
      find.ancestor(
        of: find.byIcon(Icons.settings_input_component_rounded),
        matching: find.byType(IconButton),
      ),
    );
    expect(controlBtn.onPressed, isNull);
  });

  testWidgets('a closed gate greys the live-pair rows and the mapping editor',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(
      enabled: true,
      quickBarEnabled: true,
      gateOpen: false,
    ));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byIcon(Icons.play_circle_rounded), findsOneWidget,
        reason: 'the gate itself stays reachable to re-activate');
    // Rows that address the bg runtime right now (control/picture routing, and
    // the timeline editor, which must see bg on the air) stay inert.
    for (final icon in [
      Icons.settings_input_component_rounded,
      Icons.smart_display_outlined,
      Icons.timeline_rounded,
    ]) {
      final btn = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        ),
      );
      expect(btn.onPressed, isNull,
          reason: '$icon must be greyed while bg is not active');
    }
  });

  testWidgets('a closed gate keeps the settings rows reachable',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(
      enabled: true,
      quickBarEnabled: true,
      gateOpen: false,
    ));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    // These are saved preferences: they persist and are applied on the next
    // activation, so a closed gate must not lock them out (作用范围/对齐方式/
    // 同步方式/联动等级/换集行为).
    for (final icon in [
      Icons.sync_rounded,
      Icons.tune_rounded,
      Icons.align_vertical_center_rounded,
      Icons.swap_horiz_rounded,
      Icons.rule_rounded,
    ]) {
      final btn = tester.widget<IconButton>(
        find.ancestor(
          of: find.byIcon(icon),
          matching: find.byType(IconButton),
        ),
      );
      expect(btn.onPressed, isNotNull,
          reason: '$icon is a saved preference and must stay reachable');
    }
  });

  testWidgets('hidden when the user turned it off from the menu',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: true, quickBarEnabled: false));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('bg_quick_bar')), findsNothing);
  });

  testWidgets('carries the 副音-specific actions and no transport',
      (tester) async {
    await enable();
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bg_quick_bar')), findsOneWidget);
    expect(find.byIcon(Icons.play_circle_rounded), findsOneWidget,
        reason: 'gate button (stopped → press to play)');
    expect(find.byIcon(Icons.sync_rounded), findsOneWidget,
        reason: '联动 (A) button, full-link icon active by default');
    expect(find.byIcon(Icons.link_off_rounded), findsNothing,
        reason: '解锁完全独立 (B) button');
    expect(find.byIcon(Icons.rule_rounded), findsOneWidget,
        reason: '作用范围 picker');
    expect(find.byIcon(Icons.settings_input_component_rounded), findsOneWidget,
        reason: 'control-target switch (core action)');
    expect(find.byIcon(Icons.smart_display_outlined), findsOneWidget,
        reason: 'which picture is shown');
    expect(find.byIcon(Icons.tune_rounded), findsOneWidget,
        reason: 'volume ratio');
    expect(find.byIcon(Icons.timeline_rounded), findsOneWidget,
        reason: 'timeline mapping');

    // Duplicated-with-the-bottom-bar actions must NOT be here.
    for (final icon in [
      Icons.play_arrow_rounded,
      Icons.skip_previous_rounded,
      Icons.skip_next_rounded,
      Icons.shuffle_rounded,
      Icons.repeat_rounded,
    ]) {
      expect(find.byIcon(icon), findsNothing,
          reason: '$icon already exists on the bottom bar / queue page');
    }
  });

  testWidgets('联动 (A) cycles high/low; 完全独立 (B) is NOT on the bar',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await enable();
    // Linkage tuning needs an active gate — the button is greyed otherwise.
    bg.set(bg.state.copyWith(gateOpen: true));
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    expect(bg.state.seekLink, BgSeekLink.linked);
    expect(bg.state.lockLevel, BgLockLevel.high);

    // A is already active → pressing it cycles to play/pause-only.
    await tester.tap(find.byIcon(Icons.sync_rounded));
    await tester.pumpAndSettle();
    expect(bg.state.seekLink, BgSeekLink.linked);
    expect(bg.state.lockLevel, BgLockLevel.low);
    expect(find.byIcon(Icons.pause_circle_outline_rounded), findsOneWidget);

    // A cycles back to high.
    await tester.tap(find.byIcon(Icons.pause_circle_outline_rounded));
    await tester.pumpAndSettle();
    expect(bg.state.lockLevel, BgLockLevel.high);

    // 完全独立 lives in the 副音 menu now — never on the quick bar.
    expect(find.byIcon(Icons.link_off_rounded), findsNothing,
        reason: '完全独立 moved to the 副音 menu');
  });

  testWidgets('the vertical column survives a very short panel (no overflow)',
      (tester) async {
    await enable();
    await tester.pumpWidget(_providerScope(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            // The phone side panel can be as short as 160px.
            child: SizedBox(
              height: 160,
              child: BackgroundQuickBar(axis: Axis.vertical, width: 52),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull,
        reason: 'a short panel must scroll, never overflow');
  });

  testWidgets('the vertical column is bottom-aligned in its slot',
      (tester) async {
    await enable();
    await tester.pumpWidget(_providerScope(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Center(
            // Tall enough for the whole column (it gained the lock-split
            // pair); bottom-alignment is only observable when the column is
            // NOT clipped by a shorter slot.
            child: SizedBox(
              height: 700,
              child: BackgroundQuickBar(axis: Axis.vertical, width: 52),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    final slot = tester.getRect(find.byKey(const ValueKey('bg_quick_bar')));
    // Measured on the icon glyphs (IconButton adds its own padding), so compare
    // the two gaps rather than expecting pixel-exact edges. First button in the
    // column is the gate play/stop button, last is 忽略已保存 (mapping is on by
    // default, so its icon is the crossed-out visibility glyph).
    final top = tester.getRect(
      find.byIcon(Icons.play_circle_rounded),
    );
    final bottom = tester.getRect(find.byIcon(Icons.visibility_off_outlined));
    final topGap = top.top - slot.top;
    final bottomGap = slot.bottom - bottom.bottom;
    expect(bottomGap, lessThan(topGap),
        reason: '底部对齐: the column must hug the panel bottom edge');
  });

  testWidgets('a 360px slot flows the strip into two columns',
      (tester) async {
    await enable();
    await tester.pumpWidget(_verticalHarness(height: 360, width: 200));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull,
        reason: 'a two-column grid must never overflow its slot');
    final slot = tester.getRect(find.byKey(const ValueKey('bg_quick_bar')));
    expect(slot.width, kQuickColExtent * 2 + kQuickSpacing,
        reason: 'two columns + one gap');

    // Two columns: the primary frequency group (master … 作用范围) then the
    // rarer group (对齐方式 … 忽略已保存) one column to the right. Columns are
    // bottom-aligned, so compare the horizontal axis only.
    final master = tester.getTopLeft(find.byIcon(Icons.play_circle_rounded));
    final mapping = tester.getTopLeft(find.byIcon(Icons.timeline_rounded));
    expect(mapping.dx, greaterThan(master.dx),
        reason: 'rarer actions flow into the second column');
  });

  testWidgets('mirrorColumns flips the primary column toward the panel',
      (tester) async {
    await enable();
    double dx(IconData icon) => tester.getTopLeft(find.byIcon(icon)).dx;

    await tester.pumpWidget(_verticalHarness(height: 250, width: 200));
    await tester.pumpAndSettle();
    expect(
        dx(Icons.play_circle_rounded),
        lessThan(dx(Icons.align_vertical_center_rounded)),
        reason: 'default: primary column on the left');

    await tester.pumpWidget(
        _verticalHarness(height: 250, width: 200, mirror: true));
    await tester.pumpAndSettle();
    expect(
        dx(Icons.play_circle_rounded),
        greaterThan(dx(Icons.align_vertical_center_rounded)),
        reason: 'mirrored: primary column faces the panel on the right');
  });

  testWidgets('a narrow short slot stays a single scrolling column',
      (tester) async {
    await enable();
    await tester.pumpWidget(_verticalHarness(height: 160, width: 52));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    final slot = tester.getRect(find.byKey(const ValueKey('bg_quick_bar')));
    expect(slot.width, kQuickColExtent,
        reason: 'no room for a second column → single-column scroll fallback');
  });

  testWidgets('the accent colour marks the active control target',
      (tester) async {
    await enable();
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    // Target defaults to foreground → the switch button is not accented.
    final icon = tester.widget<Icon>(
      find.byIcon(Icons.settings_input_component_rounded),
    );
    expect(icon.color, isNot(kBackgroundTargetColor));
  });

  testWidgets('every quick button carries the playback bar footprint',
      (tester) async {
    await enable();
    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();

    final Finder buttons = find.descendant(
      of: find.byKey(const ValueKey('bg_quick_bar')),
      matching: find.byType(IconButton),
    );
    final int count = buttons.evaluate().length;
    expect(count, greaterThan(0));

    for (int i = 0; i < count; i++) {
      final Size size = tester.getSize(buttons.at(i));
      // The 副音 group must sit on the same grid as the bottom bar's own
      // buttons; the retired `VisualDensity.compact` capsule was 40px and read
      // as a smaller, tighter group (and shrank the tap target).
      expect(size.width, greaterThanOrEqualTo(48.0));
      expect(size.height, greaterThanOrEqualTo(48.0));
    }
  });
}
