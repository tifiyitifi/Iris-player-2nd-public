import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show PlayerBackend;
import 'package:video_player_platform_interface/video_player_platform_interface.dart';

import 'helpers/sqlite3_loader.dart';

/// Controllable [VideoPlayerPlatform]: `initialized` events are emitted only
/// when the test says so, so two interleaved `open()` calls can be staged
/// deterministically. All transport calls are recorded per player id.
class FakeVideoPlayerPlatform extends VideoPlayerPlatform {
  int _nextId = 0;
  final Map<int, StreamController<VideoEvent>> events = {};
  final Map<int, String?> createdUris = {};
  final List<int> playCalls = [];
  final List<int> pauseCalls = [];
  final List<int> disposed = [];

  @override
  Future<void> init() async {}

  @override
  Future<int?> createWithOptions(VideoCreationOptions options) async {
    final id = _nextId++;
    events[id] = StreamController<VideoEvent>.broadcast();
    createdUris[id] = options.dataSource.uri;
    return id;
  }

  @override
  Stream<VideoEvent> videoEventsFor(int playerId) =>
      events[playerId]!.stream;

  @override
  Future<void> setLooping(int playerId, bool looping) async {}

  @override
  Future<void> play(int playerId) async {
    playCalls.add(playerId);
  }

  @override
  Future<void> pause(int playerId) async {
    pauseCalls.add(playerId);
  }

  @override
  Future<void> setVolume(int playerId, double volume) async {}

  @override
  Future<void> seekTo(int playerId, Duration position) async {}

  @override
  Future<void> setPlaybackSpeed(int playerId, double speed) async {}

  @override
  Future<Duration> getPosition(int playerId) async => Duration.zero;

  @override
  Future<void> dispose(int playerId) async {
    disposed.add(playerId);
    await events[playerId]?.close();
  }

  void emitInitialized(int playerId) {
    events[playerId]!.add(VideoEvent(
      eventType: VideoEventType.initialized,
      duration: const Duration(seconds: 60),
      size: const Size(640, 480),
    ));
  }
}

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

void main() {
  ensureSqlite3Loaded();
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // `BackgroundPlaybackEngine.open` reads the storage store, which in turn
  // reads `DbModule.storageRepo` — initialize once on a module DB.
  late AppDatabase moduleDb;
  setUpAll(() async {
    moduleDb = AppDatabase(NativeDatabase.memory());
    await DbModule.init(moduleDb);
  });
  tearDownAll(() => moduleDb.close());

  late VideoPlayerPlatform savedPlatform;
  late FakeVideoPlayerPlatform fake;

  setUp(() {
    savedPlatform = VideoPlayerPlatform.instance;
    fake = FakeVideoPlayerPlatform();
    VideoPlayerPlatform.instance = fake;
  });

  tearDown(() {
    VideoPlayerPlatform.instance = savedPlatform;
  });

  group('BackgroundPlaybackEngine FVP open generation', () {
    test('a superseded open never plays its stale controller', () async {
      final engine = BackgroundPlaybackEngine(
        backend: PlayerBackend.fvp,
        attachNative: false,
      );
      addTearDown(engine.dispose);

      // Open A, then open B before A's initialize completes.
      final openA = engine.open(_f('a'), autoplay: true);
      await pumpEventQueue();
      final openB = engine.open(_f('b'), autoplay: true);
      await pumpEventQueue();

      expect(fake.createdUris, hasLength(2));
      const staleId = 0;
      const freshId = 1;

      // The stale open's initialize completes AFTER the fresh open took over
      // `_fvp` (but before the fresh open finishes and disposes it): it must
      // stay silent — configuring/playing it here was the double-sound path.
      fake.emitInitialized(staleId);
      await openA;
      await pumpEventQueue();
      expect(fake.playCalls, isEmpty);

      // The fresh open then initializes and plays normally.
      fake.emitInitialized(freshId);
      await openB;
      await pumpEventQueue();

      expect(fake.playCalls, <int>[freshId]);
      expect(engine.fvpVideoController?.dataSource, contains('b'));
      expect(engine.file?.uri, 'file:///b');
    });

    test('a lone open still initializes and plays', () async {
      final engine = BackgroundPlaybackEngine(
        backend: PlayerBackend.fvp,
        attachNative: false,
      );
      addTearDown(engine.dispose);

      final open = engine.open(_f('a'), autoplay: true);
      await pumpEventQueue();
      fake.emitInitialized(0);
      await open;
      await pumpEventQueue();

      expect(fake.playCalls, <int>[0]);
      expect(engine.isInitializing, isFalse);
      expect(engine.errorText, isNull);
    });

    test('an empty-uri refusal supersedes an open still in flight', () async {
      final engine = BackgroundPlaybackEngine(
        backend: PlayerBackend.fvp,
        attachNative: false,
      );
      addTearDown(engine.dispose);

      // Open A, then refuse B for its empty uri while A is still initializing.
      final int before = engine.debugOpenGeneration;
      final openA = engine.open(_f('a'), autoplay: true);
      await pumpEventQueue();
      expect(engine.errorText, isNull);

      await engine.open(
        FileItem(name: 'b', uri: '', path: <String>['b']),
        autoplay: true,
      );
      await pumpEventQueue();

      // The refusal unloads the current runtime AND must invalidate the open it
      // interrupted: a stale open that still believes it is current finishes by
      // configuring/playing its own media while `file`/`errorText` describe the
      // refused entry (a ghost track behind a failure record).
      expect(engine.debugOpenGeneration, greaterThan(before),
          reason: 'the refusal supersedes the in-flight open');
      expect(engine.errorText, isNotNull);
      expect(engine.file?.name, 'b',
          reason: 'the failure record describes the refused entry');
      expect(engine.isInitializing, isFalse);
      expect(fake.playCalls, isEmpty);

      // A's controller was disposed by the refusal, so its initialize never
      // completes; the superseded open must not resurrect it either.
      unawaited(openA);
      await pumpEventQueue();
      expect(fake.playCalls, isEmpty);
      expect(engine.errorText, isNotNull);
    });
  });
}
