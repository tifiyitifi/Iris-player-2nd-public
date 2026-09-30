import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_queue_panel.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

Widget _providerScope(Widget child) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: child,
  );
}

Widget _harness(Widget child) {
  return _providerScope(
    MaterialApp(
      locale: const Locale('en'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: SizedBox(
          width: 360,
          height: 640,
          child: child,
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

  // Each testWidgets runs in its own FakeAsync zone; a background store first
  // created in an earlier test zone must not leak into the next one.
  tearDown(() => StoreLocator().delete(BackgroundPlaybackStore));

  group('BackgroundQueuePanel', () {
    testWidgets('empty state shows the explanatory text when disabled',
        (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      bg.set(bg.state.copyWith(enabled: false, queue: const []));

      await tester.pumpWidget(_harness(const BackgroundQueuePanel()));
      await tester.pumpAndSettle();
      // Empty state shows the explanatory message plus the source-manage entry.
      expect(find.descendant(
        of: find.byKey(const ValueKey('background_queue_panel_material')),
        matching: find.byType(Text),
      ), findsWidgets);
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('renders rows and highlights the current index',
        (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      bg.set(bg.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [_f('a'), _f('b'), _f('c')],
        currentIndex: 1,
      ));

      await tester.pumpWidget(_harness(const BackgroundQueuePanel()));
      await tester.pumpAndSettle();

      expect(
        find.byKey(const ValueKey('background_queue_panel_material')),
        findsOneWidget,
      );
      expect(find.text('a'), findsOneWidget);
      // 'b' is current: appears both in the header row and in the list row.
      expect(find.text('b'), findsNWidgets(2));
      expect(find.text('c'), findsOneWidget);
      // The self-owned source-manage button lives in the header.
      expect(find.byIcon(Icons.tune_rounded), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('tapping a row jumps to that index and autoplays',
        (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      bg.set(bg.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [_f('a'), _f('b'), _f('c')],
        currentIndex: 0,
        bgAutoPlay: false,
      ));

      await tester.pumpWidget(_harness(const BackgroundQueuePanel()));
      await tester.pumpAndSettle();

      await tester.tap(find.text('c'));
      await tester.pump();
      expect(useBackgroundPlaybackStore().state.currentIndex, 2);
      expect(useBackgroundPlaybackStore().state.bgAutoPlay, isTrue);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('360px wide renders without overflow', (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      bg.set(bg.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [for (var i = 0; i < 20; i++) _f('f$i')],
        currentIndex: 0,
      ));

      await tester.pumpWidget(_harness(const BackgroundQueuePanel()));
      await tester.pump();
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
    });

    testWidgets('a long queue stays lazy (only visible rows build)',
        (tester) async {
      final bg = useBackgroundPlaybackStore();
      await bg.initialized;
      bg.set(bg.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [for (var i = 0; i < 500; i++) _f('f$i')],
        currentIndex: 0,
      ));

      await tester.pumpWidget(_harness(const BackgroundQueuePanel()));
      await tester.pumpAndSettle();

      // A shrinkWrap list would lay out all 500 rows; the lazy bounded list
      // builds only the visible window.
      expect(find.text('f0'), findsWidgets);
      expect(find.text('f499'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pump(const Duration(milliseconds: 100));
    });
  });

  group('BackgroundPlaybackStore.jumpTo', () {
    late BackgroundPlaybackStore store;
    late UnifiedPlayQueueStore playQueueStore;

    setUp(() async {
      store = BackgroundPlaybackStore();
      await store.initialized;
      playQueueStore = usePlayQueueStore();
    });

    tearDown(() => store.dispose());

    test('jumps to a valid row and autoplays', () async {
      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 0,
        bgAutoPlay: false,
      ));
      await store.jumpTo(1);
      expect(store.state.currentIndex, 1);
      expect(store.state.bgAutoPlay, isTrue);
    });

    test('ignores out-of-range and disabled state', () async {
      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 0,
      ));
      expect(await store.jumpTo(-1), BgJumpOutcome.ignored);
      expect(store.state.currentIndex, 0);
      expect(await store.jumpTo(99), BgJumpOutcome.ignored);
      expect(store.state.currentIndex, 0);

      store.set(store.state.copyWith(enabled: false));
      expect(await store.jumpTo(0), BgJumpOutcome.ignored);
      expect(store.state.currentIndex, 0);
    });

    test('refuses the foreground file but keeps it listed', () async {
      // The row is the video the foreground holds right now. It must not open
      // on a second engine, and it must NOT be pruned from the queue — it is
      // the 音库 source for the next foreground.
      await playQueueStore.update(
        playQueue: [PlayQueueItem(file: _f('a'), index: 0)],
        index: 0,
      );
      addTearDown(playQueueStore.clear);

      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 1,
      ));

      expect(await store.jumpTo(0), BgJumpOutcome.refusedForegroundFile);
      expect(store.state.currentIndex, 1, reason: 'no move on refusal');
      expect(store.state.queue, hasLength(2),
          reason: 'the row stays in the list');
    });

    test('allowSameFgBgFile lifts the jump refusal', () async {
      await playQueueStore.update(
        playQueue: [PlayQueueItem(file: _f('a'), index: 0)],
        index: 0,
      );
      addTearDown(playQueueStore.clear);

      // The guard is read from the LIVE store (`excludedForegroundKey`), so the
      // preference has to be lifted there — not only on this test's instance.
      final live = useBackgroundPlaybackStore();
      await live.initialized;
      live.set(live.state.copyWith(allowSameFgBgFile: true));
      addTearDown(() => live.set(live.state.copyWith(allowSameFgBgFile: false)));

      store.set(store.state.copyWith(
        enabled: true,
        queue: [_f('a'), _f('b')],
        currentIndex: 1,
      ));

      expect(await store.jumpTo(0), BgJumpOutcome.jumped);
      expect(store.state.currentIndex, 0);
    });

    test('step is a hard no-op while the A-B editor is open', () async {
      store.set(store.state.copyWith(
        enabled: true,
        shuffle: false,
        queue: [_f('a'), _f('b'), _f('c')],
        currentIndex: 0,
        segmentEditMode: true,
      ));

      // The align editor only edits/saves the current pair — it must never swap
      // the file out from under the span, from either direction or source.
      expect(await store.step(forward: true), isFalse);
      expect(await store.step(forward: false), isFalse);
      expect(await store.step(forward: true, userInitiated: true), isFalse);
      expect(store.state.currentIndex, 0);
    });
  });
}