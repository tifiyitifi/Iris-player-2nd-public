import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/app_instance.dart';

/// 副音 SOURCES and preferences are app-wide, but "which file of MY queue am I
/// on" is per window. A single shared blob used to let a second window inherit
/// (and overwrite) the first one's queue.
void main() {
  FileItem file(String name) => FileItem(
        storageId: 's',
        storageType: StorageType.internal,
        name: name,
        uri: '/media/$name',
        path: [name],
      );

  late MemoryKvStore kv;

  setUp(() {
    kv = MemoryKvStore();
    setKvStoreForTest(kv);
    AppInstance.debugReset();
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  test('the queue lives per window while preferences stay shared', () async {
    AppInstance.debugSetSlot(1);
    final primary = BackgroundPlaybackStore();
    await primary.initialized;
    await primary.save(primary.state.copyWith(
      bgVolumePercent: 42,
      queue: [file('a.mp4')],
      queueTotal: 1,
      shuffleSeed: 7,
    ));

    final shared =
        jsonDecode(kv.values['bg_playback_state']!) as Map<String, dynamic>;
    expect(shared['bgVolumePercent'], 42, reason: 'prefs are app-wide');
    expect(shared.containsKey('queue'), isFalse,
        reason: 'the shared blob must not carry one window\'s queue');
    expect(shared.containsKey('shuffleSeed'), isFalse);

    final position =
        jsonDecode(kv.values['bg_playback_position']!) as Map<String, dynamic>;
    expect(position['queue'], hasLength(1));
    expect(position['shuffleSeed'], 7);

    // A second window starts with no queue of its own, but reads the prefs.
    AppInstance.debugSetSlot(2);
    final second = BackgroundPlaybackStore();
    await second.initialized;
    expect(second.state.queue, isEmpty,
        reason: 'a second window must not inherit the primary 副音 queue');
    expect(second.state.bgVolumePercent, 42, reason: 'prefs are shared');

    // ...and its own cursor goes to its own session key.
    await second.save(
      second.state.copyWith(queue: [file('b.mp4')], queueTotal: 1),
    );
    expect(kv.values['s2.bg_playback_position'], contains('b.mp4'));
    final sharedAfter =
        jsonDecode(kv.values['bg_playback_state']!) as Map<String, dynamic>;
    expect(sharedAfter.containsKey('queue'), isFalse,
        reason: 'an extra window never writes the shared queue');
  });

  test('a legacy queue in the shared blob seeds the window once', () async {
    // Pre-split install: the queue still sits in the shared blob, there is no
    // position key yet.
    await kv.write(
      key: 'bg_playback_state',
      value: jsonEncode({
        'queue': [file('legacy.mp4').toJson()],
        'queueTotal': 1,
        'queueWindowStart': 0,
        'shuffleSeed': 0,
      }),
    );
    AppInstance.debugSetSlot(1);

    final store = BackgroundPlaybackStore();
    await store.initialized;

    expect(store.state.queue.single.name, 'legacy.mp4',
        reason: 'an upgrade must not lose the remembered 副音 queue');
  });
}
