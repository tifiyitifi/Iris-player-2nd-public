import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/store/use_playback_progress_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

import 'helpers/sqlite3_loader.dart';

VirtualMediaItem _item() => VirtualMediaItem(
      ruleId: 'r1',
      scopeKey: 'r1|d|#1',
      rootPath: 'd',
      displayIndex: 1,
      displayName: 'd',
      segments: const [
        VirtualSegment(
          mediaKey: 'st1:d/a.mp4',
          storageId: 'st1',
          path: ['d', 'a.mp4'],
          name: 'a.mp4',
          parentPath: 'd',
          durationMs: 60000,
        ),
        VirtualSegment(
          mediaKey: 'st1:d/b.mp4',
          storageId: 'st1',
          path: ['d', 'b.mp4'],
          name: 'b.mp4',
          parentPath: 'd',
          durationMs: 60000,
        ),
        VirtualSegment(
          mediaKey: 'st1:d/c.mp4',
          storageId: 'st1',
          path: ['d', 'c.mp4'],
          name: 'c.mp4',
          parentPath: 'd',
          durationMs: 60000,
        ),
      ],
    );

FileItem _file(String name) => FileItem(
      storageId: 'st1',
      name: name,
      uri: 'file:///d/$name',
      path: ['d', name],
    );

/// The More-menu folder toggle makes the LIVE single mergeable. Adoption must
/// attach the VM timeline to the file the player already has open — never
/// reopen it (that would restart the position/audio) and never touch the queue.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    useAppStore();
    await useAppStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
  });

  setUp(() async {
    useVmPlaybackStore().replace(const VmPlaybackState());
    usePlaybackProgressStore().set(<String, (int, int)>{});
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
  });

  tearDown(() async {
    await VirtualMediaController.instance.deactivateForNavigation();
    useVmPlaybackStore().replace(const VmPlaybackState());
    usePlaybackProgressStore().set(<String, (int, int)>{});
  });

  Future<void> playSingle(String name) async {
    await usePlayQueueStore().update(
      playQueue: [PlayQueueItem(file: _file(name), index: 0)],
      index: 0,
    );
  }

  test('adopts the live feed without touching queue, autoplay or position',
      () async {
    await playSingle('b.mp4');
    await useAppStore().updateAutoPlay(true);

    final ok = await VirtualMediaController.instance.adoptLiveSession(
      queue: [_item()],
      queueIndex: 0,
      segmentIndex: 1,
      localMs: 12000,
    );
    final ctrl = VirtualMediaController.instance;
    expect(ok, isTrue);
    expect(ctrl.isActive, isTrue, reason: 'the adoption is live immediately');
    expect(ctrl.state.item?.scopeKey, 'r1|d|#1');
    expect(ctrl.state.segmentIndex, 1);
    expect(ctrl.state.transitioning, isFalse);
    expect(ctrl.state.pendingSeekMs, isNull);
    // Playback is untouched: same queue entry, autoplay still on.
    final q = usePlayQueueStore().state;
    expect(q.playQueue, hasLength(1));
    expect(q.playQueue.single.file.uri, 'file:///d/b.mp4');
    expect(q.currentIndex, 0);
    expect(useAppStore().state.autoPlay, isTrue);
    // The virtual axis is the group's prefix sum, not the segment's local one.
    expect(
      ctrl.translatePosition(const Duration(seconds: 3)),
      const Duration(seconds: 63),
    );
  });

  test('seeds from the live progress store when no localMs is given', () async {
    await playSingle('b.mp4');
    usePlaybackProgressStore().update('st1:d/b.mp4', 4567, 60000);

    final ok = await VirtualMediaController.instance.adoptLiveSession(
      queue: [_item()],
      queueIndex: 0,
      segmentIndex: 1,
    );

    expect(ok, isTrue);
    // The live progress store's position must become the session's intra-segment
    // position (not 0), so dual time / segment marks start where playback is.
    expect(VirtualMediaController.instance.debugLocalPositionMs, 4567,
        reason: 'omitting localMs must seed from the progress store');
  });

  test('refuses when the queue has moved to another file', () async {
    await playSingle('c.mp4');

    final ok = await VirtualMediaController.instance.adoptLiveSession(
      queue: [_item()],
      queueIndex: 0,
      segmentIndex: 1,
      localMs: 12000,
    );

    expect(ok, isFalse);
    expect(VirtualMediaController.instance.state.item, isNull);
  });

  test('refuses when a session already owns the timeline', () async {
    await playSingle('b.mp4');
    useVmPlaybackStore().replace(VmPlaybackState(item: _item()));

    final ok = await VirtualMediaController.instance.adoptLiveSession(
      queue: [_item()],
      queueIndex: 0,
      segmentIndex: 1,
      localMs: 12000,
    );

    expect(ok, isFalse);
  });

  test('refuses on an empty play queue', () async {
    final ok = await VirtualMediaController.instance.adoptLiveSession(
      queue: [_item()],
      queueIndex: 0,
      segmentIndex: 1,
      localMs: 12000,
    );

    expect(ok, isFalse);
  });
}
