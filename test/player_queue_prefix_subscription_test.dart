import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/play_queue/models/play_queue_source.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/pages/player/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// The bar title's `[cur/total]` prefix read the queue's REAL size BARE
/// (`store.totalCount` — a getter, not a subscription). In query mode the state
/// published to subscribers is a SYNTHETIC single item, so the total lives only
/// on the store's `totalCountNotifier`: a search/filter that moved the total
/// 1↔N never re-built the title, while the control bar — which subscribes —
/// already showed the new number.
///
/// Both seeds below resolve to the SAME current file, so the synthetic
/// `PlayQueueState` is byte-for-byte equal and the store emits nothing: the
/// title can only move if it listens to the notifier.
MediaPlayer _player() => MediaPlayer(
      isInitializing: false,
      isPlaying: false,
      externalSubtitles: const [],
      position: const Duration(seconds: 12),
      duration: const Duration(hours: 1),
      buffer: Duration.zero,
      width: 640,
      height: 360,
      saveProgress: () async {},
      play: () async {},
      pause: () async {},
      backward: (_) async {},
      forward: (_) async {},
      stepBackward: () async {},
      stepForward: () async {},
      seek: (_) async {},
    );

PlayQueueItem _item(String n) => PlayQueueItem(
      file: FileItem(name: '$n.mp4', uri: 'file:///$n.mp4'),
      index: n.codeUnitAt(0),
    );

/// Same head item, [count] total — the shape a search/filter moves the queue
/// into, with the current file unchanged.
PlayQueueSource _source(int count) => PlayQueueSource.explicit(
      items: <PlayQueueItem>[
        _item('a'),
        for (int i = 1; i < count; i++) _item('item$i'),
      ],
    );

/// Store writes are async hops FakeAsync never flushes, so they must run
/// outside the test's zone (see `app_state_select_narrowing_test`).
Future<void> _seed(WidgetTester tester, int count) => tester.runAsync(() async {
      await usePlayQueueStore().setSource(_source(count));
    });

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    debugIsDesktopOverride = false;
    debugIsMobilePlatformOverride = false;
    // The title reads the tag-view / scenario position signals off this
    // registry, so it has to exist before the first build.
    PlaybackProviderRegistry.init();
    final AppStore app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
      useClassicTitleBar: true,
      useScenarioDrivenPlayback: false,
    ));
    await useAppStore().initialized;
    await usePlayQueueStore().initialized;
    await usePlayQueueStore().switchBackend(false);
  });
  tearDownAll(() {
    debugIsDesktopOverride = null;
    debugIsMobilePlatformOverride = null;
  });

  Widget harness() => InheritedProvider<StoreLocator>.value(
        value: StoreLocator(),
        startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
          final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
          return sub.cancel;
        },
        lazy: false,
        child: Provider<MediaPlayer>.value(
          value: _player(),
          child: MaterialApp(
            locale: const Locale('en'),
            localizationsDelegates: AppLocalizations.localizationsDelegates,
            supportedLocales: AppLocalizations.supportedLocales,
            home: const Scaffold(body: Player()),
          ),
        ),
      );

  testWidgets('the title prefix follows the published queue total',
      (tester) async {
    tester.view.physicalSize = const Size(1280, 720);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    usePlayerUiStore().updateIsShowControl(true);
    await _seed(tester, 3);
    expect(usePlayQueueStore().isQueryMode, isTrue,
        reason: 'precondition: the paged/query backend is active');
    expect(usePlayQueueStore().state.playQueue, hasLength(1),
        reason: 'precondition: query mode publishes a synthetic single item');

    await tester.pumpWidget(harness());
    await tester.pumpAndSettle();
    expect(find.text('[1/3]'), findsOneWidget,
        reason: 'precondition: the title shows the queue total');

    // The filter widens the queue. The synthetic state is unchanged, so nothing
    // but the notifier can move the title.
    await _seed(tester, 5);
    await tester.pumpAndSettle();

    expect(usePlayQueueStore().totalCount, 5,
        reason: 'precondition: the backend really grew');
    expect(find.text('[1/5]'), findsOneWidget,
        reason: 'the title must not freeze on the total the control bar moved '
            'past');
  });
}
