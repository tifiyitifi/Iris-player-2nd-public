import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_duration_probe.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';

import 'helpers/sqlite3_loader.dart';

/// A SAF single-picked file has an EMPTY segment path: its identity lives in the
/// document `uri` (see [MediaNode.occurrencePath]). `media_nodes` therefore
/// stores it as `path == ''` + `uri == content://…`, which a path-keyed lookup
/// can never see. These tests pin that the duration read (and the probe's
/// write-then-re-read fold) matches such a row by its uri — the asymmetry that
/// left every SAF single-pick flagged "unknown" forever.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // Tree-shaped so it round-trips through `canonicalOccurrencePath` unchanged.
  const safUri = 'content://com.android.externalstorage.documents/tree/'
      'primary%3ADownload/document/primary%3ADownload%2Fsaf.mp4';
  const safUri2 = 'content://com.android.providers.media.documents/'
      'document/video%3A202';

  FileItem safFile() => const FileItem(
        storageId: 's1',
        path: <String>[],
        name: 'saf.mp4',
        uri: safUri,
      );

  FileItem safFile2() => const FileItem(
        storageId: 's1',
        path: <String>[],
        name: 'saf2.mp4',
        uri: safUri2,
      );

  late AppDatabase db;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close());

  // Each test owns the (empty-path) row shape; start from a clean table so the
  // shared in-memory DB's unique (data_scope_id, path) index never collides.
  setUp(() async {
    await DbModule.mediaNodesDao.deleteByStorage('s1');
  });

  group('resolvedBgDurationKeys (SAF single-pick)', () {
    test('matches an empty-path row through its document uri', () async {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:',
        storageId: 's1',
        path: const <String>[],
        name: 'saf.mp4',
        mediaType: MediaType.video,
        uri: safUri,
        durationMs: 60000,
      ));

      final resolved = await resolvedBgDurationKeys([safFile()]);
      expect(resolved, contains(backgroundMediaKey(safFile())));
    });

    test('a probed SAF row is seen again by the post-probe re-read', () async {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:',
        storageId: 's1',
        path: const <String>[],
        name: 'saf.mp4',
        mediaType: MediaType.video,
        uri: safUri,
        // No duration yet: the probe below must resolve it and write it back.
      ));

      final outcome = await probeMissingBgDurations(
        [safFile()],
        probeService: _FakeProbe({safUri: 12345}),
        isNetwork: (_) => false,
      );
      expect(outcome.resolvedKeys, contains(backgroundMediaKey(safFile())));

      // The observer's closing re-read must agree with the write-back, or the
      // row stays flagged "unknown" / red.
      final resolved = await resolvedBgDurationKeys([safFile()]);
      expect(resolved, contains(backgroundMediaKey(safFile())));
    });

    test('two single picks keep SEPARATE rows and each writes its OWN duration',
        () async {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:',
        storageId: 's1',
        path: const <String>[],
        name: 'saf.mp4',
        mediaType: MediaType.video,
        uri: safUri,
      ));
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:',
        storageId: 's1',
        path: const <String>[],
        name: 'saf2.mp4',
        mediaType: MediaType.video,
        uri: safUri2,
      ));

      final outcome = await probeMissingBgDurations(
        [safFile(), safFile2()],
        probeService: _FakeProbe({safUri: 11111, safUri2: 22222}),
        isNetwork: (_) => false,
      );
      expect(outcome.resolvedKeys, contains(backgroundMediaKey(safFile())));
      expect(outcome.resolvedKeys, contains(backgroundMediaKey(safFile2())));

      // Each write-back must land on ITS OWN row (a path-keyed write with the
      // empty path could only ever hit one of them).
      final resolved = await resolvedBgDurationsByKey([safFile(), safFile2()]);
      expect(resolved[backgroundMediaKey(safFile())], 11111);
      expect(resolved[backgroundMediaKey(safFile2())], 22222);
    });
  });
}

class _FakeProbe implements MediaProbeService {
  _FakeProbe(this.durations);

  final Map<String, int?> durations;

  @override
  Future<ProbeResult> probeFile(String target) async =>
      ProbeResult(durationMs: durations[target]);

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async =>
      [for (final t in targets) ProbeResult(durationMs: durations[t])];
}
