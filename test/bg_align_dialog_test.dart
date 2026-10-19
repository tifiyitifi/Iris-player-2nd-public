import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/bg_align_auto_rule_dialog.dart';
import 'package:iris/features/background_playback/view/bg_align_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// The shared 副音 alignment editor: a two-tab switch — 「更新对齐」 with three
/// LIVE anchor modes, and a read-only 「默认对齐」 tab explaining the AUTOMATIC
/// anchoring — over a decoupled percent slider that never seeks by itself.
MediaPlayer _fakePlayer() => MediaPlayer(
      isInitializing: false,
      isPlaying: true,
      externalSubtitles: const [],
      position: const Duration(seconds: 40),
      duration: const Duration(minutes: 10),
      buffer: Duration.zero,
      width: 1280,
      height: 720,
      saveProgress: () async {},
      play: () async {},
      pause: () async {},
      backward: (_) async {},
      forward: (_) async {},
      stepBackward: () async {},
      stepForward: () async {},
      seek: (_) async {},
    );

Widget _harness({
  required MediaPlayer player,
  required BackgroundPlaybackEngine engine,
  TextScaler textScaler = TextScaler.noScaling,
}) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: Provider<MediaPlayer>.value(
      value: player,
      child: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
        value: engine,
        child: MaterialApp(
          locale: const Locale('en'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Builder(
            builder: (context) => MediaQuery(
              data: MediaQuery.of(context).copyWith(textScaler: textScaler),
              child: const Scaffold(
                body: SingleChildScrollView(child: BgAlignContent()),
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late BackgroundPlaybackEngine engine;

  setUp(() async {
    engine = BackgroundPlaybackEngine(
      backend: PlayerBackend.mediaKit,
      attachNative: false,
    );
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    // Normal active state: 副音 enabled AND the user gate open (the update
    // scope only exists while 副音 is actually mixing).
    bg.set(bg.state.copyWith(enabled: true, gateOpen: true));
  });

  tearDown(() async {
    engine.dispose();
    // Drop the app-wide singletons so every test builds its stores inside its
    // own fake-async zone. A shared AppStore created in an earlier test's zone
    // can never complete `initialized` here and loses change propagation.
    await StoreLocator().delete(BackgroundPlaybackStore);
    await StoreLocator().delete(AppStore);
  });

  testWidgets('renders without overflow on a 360x640 phone at large font',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_harness(
      player: _fakePlayer(),
      engine: engine,
      textScaler: const TextScaler.linear(1.3),
    ));
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(find.byType(BgAlignContent), findsOneWidget);
  });

  testWidgets('shows which anchor the automatic rule applied', (tester) async {
    // 尾部锚定 has no manual radio, so this read-only line is the only place the
    // user can see why the 副音 started mid-file.
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(alignMode: BgAlignMode.tailAtFg));
    engine.duration = const Duration(minutes: 30);
    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    expect(find.textContaining('Auto anchoring:'), findsOneWidget);
    expect(
      find.textContaining("aligned with the video's end"),
      findsOneWidget,
    );
  });

  testWidgets('the default tab explains the automatic anchoring, not options',
      (tester) async {
    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    // 「更新对齐」 (the default tab) shows the three manual modes and no rule
    // note: a tap there re-aligns the running pair right now.
    expect(find.byWidgetPredicate((w) => w is SegmentedButton), findsOneWidget);
    expect(find.text('Update alignment'), findsOneWidget);
    expect(find.text('Default alignment'), findsOneWidget);
    expect(
      find.text(
          'Sub Audio from 00:00: its start aligns with the video\'s current position'),
      findsOneWidget,
    );
    expect(find.text('Default anchoring'), findsNothing);

    // 「默认对齐」 is read-only: it only explains the automatic rule, with no
    // option to pick.
    await tester.tap(find.text('Default alignment'));
    await tester.pumpAndSettle();

    expect(find.text('Default anchoring'), findsOneWidget);
    expect(find.textContaining('Decided automatically'), findsOneWidget);
    expect(
      find.text(
          'Sub Audio from 00:00: its start aligns with the video\'s current position'),
      findsNothing,
    );
  });

  testWidgets('gate shut keeps the tabs; the manual modes are disabled',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(gateOpen: false));
    final modeBefore = bg.state.alignMode;

    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    // The card is still reachable while 副音 is inactive: the two-tab switch and
    // the three manual anchors stay, with a caption saying they are inert.
    expect(find.byWidgetPredicate((w) => w is SegmentedButton), findsOneWidget);
    expect(find.text('Update alignment'), findsOneWidget);
    final headMode = find.text(
        'Sub Audio from 00:00: its start aligns with the video\'s current position');
    expect(headMode, findsOneWidget);
    expect(
      find.text("Sub Audio isn't active yet, so alignment can't be applied."),
      findsOneWidget,
    );

    // Tapping a listed-but-disabled mode must not re-align anything.
    await tester.ensureVisible(headMode);
    await tester.tap(headMode, warnIfMissed: false);
    await tester.pumpAndSettle();
    expect(bg.state.alignMode, modeBefore);

    // The read-only explanation is one tab away.
    final defaultTab = find.text('Default alignment');
    await tester.ensureVisible(defaultTab);
    await tester.tap(defaultTab);
    await tester.pumpAndSettle();
    expect(find.text('Default anchoring'), findsOneWidget);
  });

  testWidgets('tapping a mode updates the running pair live', (tester) async {
    final bg = useBackgroundPlaybackStore();
    expect(bg.state.alignMode, BgAlignMode.sameClock);
    final defBefore = bg.state.alignDefault;

    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    final finder = find.text(
        'Sub Audio from 00:00: its start aligns with the video\'s current position');
    await tester.ensureVisible(finder);
    await tester.tap(finder);
    await tester.pumpAndSettle();

    expect(bg.state.alignMode, BgAlignMode.bgHeadAtFg);
    // There is no persisted default anymore: it is never touched by a tap.
    expect(bg.state.alignDefault, defBefore);
  });

  testWidgets('the percent slider edits the share without seeking',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    final before = bg.state.alignPercent;

    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    final slider = find.byKey(const ValueKey('bg_align_percent_slider'));
    expect(slider, findsOneWidget);
    await tester.drag(slider, const Offset(60, 0));
    await tester.pumpAndSettle();

    expect(bg.state.alignPercent, isNot(equals(before)));
    expect(bg.state.alignMode, BgAlignMode.sameClock);
  });

  testWidgets('alignment section sits above other settings', (tester) async {
    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    final alignTitle = find.text('Alignment');
    final otherTitle = find.text('Other');
    expect(alignTitle, findsOneWidget);
    expect(otherTitle, findsOneWidget);
    // The slider (alignment) renders above the 其他设置 boundary.
    final slider = find.byKey(const ValueKey('bg_align_percent_slider'));
    expect(slider, findsOneWidget);
    expect(
      tester.getTopLeft(alignTitle).dy,
      lessThan(tester.getTopLeft(slider).dy),
    );
    expect(
      tester.getTopLeft(slider).dy,
      lessThan(tester.getTopLeft(otherTitle).dy),
    );
  });

  testWidgets('the anchoring note is read-only (no dismiss control)',
      (tester) async {
    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();
    // The note lives on the read-only tab.
    await tester.tap(find.text('Default alignment'));
    await tester.pumpAndSettle();

    expect(find.text('Default anchoring'), findsOneWidget);
    // Never dismissible: it is the tab's whole content, and the tab itself is
    // optional to open.
    expect(
      find.byKey(const ValueKey('bg_align_default_hint_hide')),
      findsNothing,
    );
  });

  testWidgets('the anchoring explanation dialog renders the automatic rule',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: ElevatedButton(
              onPressed: () => showBgAlignAutoRuleDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));

    await tester.pumpAndSettle();

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.text('Default anchoring'), findsOneWidget);
    expect(find.textContaining('Decided automatically'), findsOneWidget);
  });

  testWidgets('the percent caption hides forever and comes back on reset',
      (tester) async {
    final app = useAppStore();

    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    expect(find.textContaining('Tune the share'), findsOneWidget);
    final hide =
        find.byKey(const ValueKey('bg_align_percent_hint_hide'));
    await tester.ensureVisible(hide);
    await tester.tap(hide);
    await tester.pumpAndSettle();

    expect(find.textContaining('Tune the share'), findsNothing);
    expect(app.state.suppressedWarnings, contains(kWarningBgAlignPercentHint));

    await app.resetWarning(kWarningBgAlignPercentHint);
    await tester.pumpAndSettle();
    expect(find.textContaining('Tune the share'), findsOneWidget);
  });

  testWidgets('picking stopRestoreFg records the exhausted action',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await tester.pumpWidget(_harness(player: _fakePlayer(), engine: engine));
    await tester.pumpAndSettle();

    final finder =
        find.text('Pause Sub Audio and restore the video\'s own audio');
    await tester.scrollUntilVisible(finder, 120,
        scrollable: find.byType(Scrollable).first);
    await tester.tap(finder);
    await tester.pumpAndSettle();

    expect(bg.state.bgExhaustedAction, BgExhaustedAction.stopRestoreFg);
  });
}
