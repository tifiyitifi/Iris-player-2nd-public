import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/store/kv/file_json_kv.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/routed_kv.dart';
import 'package:path/path.dart' as p;

/// In-memory KV double standing in for secure storage in routing tests.
class MemoryKv implements KvStore {
  final Map<String, String> values = {};

  @override
  Future<String?> read({required String key}) async => values[key];

  @override
  Future<void> write({required String key, required String value}) async =>
      values[key] = value;

  @override
  Future<void> delete({required String key}) async => values.remove(key);

  @override
  Future<bool> containsKey({required String key}) async =>
      values.containsKey(key);

  @override
  Future<Map<String, String>> readAll() async => Map.of(values);
}

/// [FileJsonKv] whose backing read always fails, simulating a transient IO
/// error on an existing file.
class _FailingReadKv extends FileJsonKv {
  _FailingReadKv({required super.filePath});

  @override
  Future<String> readRaw(File file) async {
    throw const FileSystemException('simulated read failure');
  }
}

/// [FileJsonKv] that loads fine once and then serves a TORN payload to the
/// write-time reload, simulating a parse failure on an otherwise readable file.
class _FlakyParseKv extends FileJsonKv {
  _FlakyParseKv({required super.filePath, required this.validContent});

  final String validContent;
  int reads = 0;

  @override
  Future<String> readRaw(File file) async {
    reads++;
    return reads == 1 ? validContent : '{"keep":"me", torn';
  }
}

void main() {
  late Directory tempDir;
  late String filePath;

  setUp(() async {
    tempDir = await Directory.systemTemp.createTemp('iris_kv_test');
    filePath = p.join(tempDir.path, 'kv.json');
  });

  tearDown(() async {
    await tempDir.delete(recursive: true);
  });

  group('FileJsonKv', () {
    test('round trip read/write/delete/containsKey/readAll', () async {
      final kv = FileJsonKv(filePath: filePath);

      expect(await kv.read(key: 'missing'), isNull);
      expect(await kv.containsKey(key: 'a'), isFalse);

      await kv.write(key: 'a', value: '1');
      await kv.write(key: 'b', value: '2');
      expect(await kv.read(key: 'a'), '1');
      expect(await kv.containsKey(key: 'b'), isTrue);
      expect(await kv.readAll(), {'a': '1', 'b': '2'});

      await kv.delete(key: 'a');
      expect(await kv.read(key: 'a'), isNull);
      expect((await kv.readAll()).keys, ['b']);
    });

    test('overwrites an existing key and persists the latest value',
        () async {
      final kv = FileJsonKv(filePath: filePath);
      await kv.write(key: 'k', value: 'old');
      await kv.write(key: 'k', value: 'new');

      // A fresh instance must observe the persisted (latest) state.
      expect(await FileJsonKv(filePath: filePath).read(key: 'k'), 'new');
    });

    test('state survives across instances (real persistence)', () async {
      final writer = FileJsonKv(filePath: filePath);
      await writer.write(key: 'app_state', value: '{"theme":"dark"}');
      await writer.write(key: 'history_state', value: '[]');

      final reader = FileJsonKv(filePath: filePath);
      expect(await reader.read(key: 'app_state'), '{"theme":"dark"}');
      expect(await reader.read(key: 'history_state'), '[]');
      expect(File(filePath).existsSync(), isTrue);
    });

    test('a second window write keeps the first window keys (merge on write)',
        () async {
      // Two windows (two backends on one file), each loaded the empty store.
      final window1 = FileJsonKv(filePath: filePath);
      final window2 = FileJsonKv(filePath: filePath);
      expect(await window1.read(key: 'seed'), isNull);
      expect(await window2.read(key: 'seed'), isNull);

      await window1.write(key: 'theme_config', value: 'dark');
      // Window 2 still holds its stale empty cache; the rewrite must not drop
      // window 1's key.
      await window2.write(key: 's2.playQueue_state', value: '[]');

      final stored = json.decode(await File(filePath).readAsString())
          as Map<String, dynamic>;
      expect(stored['theme_config'], 'dark');
      expect(stored['s2.playQueue_state'], '[]');
    });

    test('no leftover temp file after a write', () async {
      final kv = FileJsonKv(filePath: filePath);
      await kv.write(key: 'k', value: 'v');
      expect(File('$filePath.tmp').existsSync(), isFalse);
    });

    test('corrupt file is backed aside and store starts empty', () async {
      await File(filePath).writeAsString('{not valid json!!');

      final kv = FileJsonKv(filePath: filePath);
      expect(await kv.read(key: 'anything'), isNull);

      // The corrupt original was preserved next to the store file...
      final backups = tempDir
          .listSync()
          .whereType<File>()
          .where((f) => f.path.startsWith('$filePath.corrupt-'))
          .toList();
      expect(backups, hasLength(1));
      expect(backups.single.readAsStringSync(), '{not valid json!!');

      // ...and the store keeps working afterwards.
      await kv.write(key: 'k', value: 'v');
      expect(await FileJsonKv(filePath: filePath).read(key: 'k'), 'v');
    });

    test('a torn write-time reload aborts the write instead of rewriting',
        () async {
      // The initial load succeeded, so the store holds a snapshot; the reload
      // that guards the whole-file rewrite then cannot parse what is on disk
      // (a torn/unreadable payload another window left behind). Rewriting from
      // the stale snapshot would delete every key that window wrote — the write
      // must fail and the file must stay EXACTLY as it was.
      const original = '{"keep":"me","their":"bytes"}';
      await File(filePath).writeAsString(original);
      final kv = _FlakyParseKv(filePath: filePath, validContent: original);
      expect(await kv.read(key: 'keep'), 'me');

      await expectLater(
          kv.write(key: 'new', value: 'v'), throwsA(isA<FormatException>()));
      expect(File(filePath).readAsStringSync(), original,
          reason: 'a failed reload must never be followed by a stale rewrite');

      // The in-memory snapshot was not clobbered by the half-parsed payload.
      expect(await kv.read(key: 'their'), 'bytes');
    });

    test('a read failure keeps the store unloaded and never wipes the file',
        () async {
      // A real file exists (so the "no file yet" fast path is not taken), but
      // the raw read fails — standing in for a transient IO error (file lock,
      // AV scan, removable media). The failure must not be mistaken for an
      // empty store.
      await File(filePath).writeAsString('{"keep":"me"}');
      final kv = _FailingReadKv(filePath: filePath);

      await expectLater(
          kv.read(key: 'keep'), throwsA(isA<FileSystemException>()));

      // A follow-up write must also fail rather than rewrite the backing file
      // with an empty map: the original content stays intact on disk.
      await expectLater(kv.write(key: 'new', value: 'v'),
          throwsA(isA<FileSystemException>()));
      expect(File(filePath).readAsStringSync(), '{"keep":"me"}');
    });
  });

  group('RoutedKv', () {
    late MemoryKv secure;
    late FileJsonKv file;
    late RoutedKv routed;

    setUp(() {
      secure = MemoryKv();
      file = FileJsonKv(filePath: filePath);
      routed = RoutedKv(
        fileKv: file,
        secureKv: secure,
        secretKeys: KvKeys.secretKeys,
      );
    });

    test('secret keys are served by the secure backend only', () async {
      await routed.write(key: KvKeys.storageState, value: 'creds');

      expect(secure.values[KvKeys.storageState], 'creds');
      expect(await file.readAll(), isEmpty);
      expect(await routed.read(key: KvKeys.storageState), 'creds');
    });

    test('ordinary keys are served by the file backend only', () async {
      await routed.write(key: KvKeys.appState, value: '{}');

      expect(file, isNotNull);
      expect(await file.read(key: KvKeys.appState), '{}');
      expect(secure.values, isEmpty);
      expect(await routed.read(key: KvKeys.appState), '{}');
    });

    test('delete/containsKey/readAll route per key', () async {
      await routed.write(key: KvKeys.storageState, value: 'creds');
      await routed.write(key: KvKeys.historyState, value: '[]');

      expect(await routed.containsKey(key: KvKeys.storageState), isTrue);
      expect(await routed.containsKey(key: KvKeys.appState), isFalse);

      final all = await routed.readAll();
      expect(all[KvKeys.storageState], 'creds');
      expect(all[KvKeys.historyState], '[]');

      await routed.delete(key: KvKeys.historyState);
      expect(await routed.containsKey(key: KvKeys.historyState), isFalse);
      expect(await routed.containsKey(key: KvKeys.storageState), isTrue);
    });
  });

  group('KvKeys', () {
    test('credential-bearing keys stay in the secret set', () {
      expect(KvKeys.secretKeys, contains(KvKeys.storageState));
    });

    test('every known key list excludes secrets', () {
      for (final key in KvKeys.all) {
        expect(KvKeys.secretKeys, isNot(contains(key)),
            reason: '$key must not be listed as portable-migratable');
      }
    });
  });
}
