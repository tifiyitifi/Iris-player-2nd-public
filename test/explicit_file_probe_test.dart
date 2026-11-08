import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/scenario_playback/actions/explicit_file_probe.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

/// The desktop drop path indexes dropped files bare, then probes their
/// duration/dimensions silently. These cover the write-back contract and the
/// network/sanitize guards.
class _FakeProbe implements MediaProbeService {
  _FakeProbe(this.results);

  final Map<String, ProbeResult> results;
  final List<String> probed = [];

  @override
  Future<ProbeResult> probeFile(String target) async {
    probed.add(target);
    return results[target] ?? ProbeResult.empty;
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async =>
      [for (final t in targets) await probeFile(t)];
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
  });

  tearDownAll(() => db.close());

  setUp(() async {
    await DbModule.mediaNodesDao.deleteNode('s', 'movies/x.mkv');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 's:movies/x.mkv',
      storageId: 's',
      path: const ['movies', 'x.mkv'],
      name: 'x.mkv',
      mediaType: MediaType.video,
    ));
  });

  Future<int?> durationOf() async {
    final node = await DbModule.mediaNodeRepo
        .getNodeByPath(storageId: 's', path: const ['movies', 'x.mkv']);
    return node?.maybeMap(file: (f) => f.durationMs, orElse: () => null);
  }

  Future<int?> widthOf() async {
    final node = await DbModule.mediaNodeRepo
        .getNodeByPath(storageId: 's', path: const ['movies', 'x.mkv']);
    return node?.maybeMap(file: (f) => f.width, orElse: () => null);
  }

  Future<int?> sizeOf() async {
    final node = await DbModule.mediaNodeRepo
        .getNodeByPath(storageId: 's', path: const ['movies', 'x.mkv']);
    return node?.maybeMap(file: (f) => f.sizeInBytes, orElse: () => null);
  }

  ExplicitFileProbeTarget target() => const ExplicitFileProbeTarget(
        storageId: 's',
        path: 'movies/x.mkv',
        uri: '/abs/movies/x.mkv',
      );

  test('writes the probed duration back and reports the touched storage',
      () async {
    final fake = _FakeProbe({
      '/abs/movies/x.mkv': const ProbeResult(
        durationMs: 1234,
        width: 1920,
        height: 1080,
      ),
    });

    final touched = await probeExplicitFiles(
      [target()],
      probeService: fake,
      isNetwork: (_) => false,
    );

    expect(touched, {'s'});
    expect(await durationOf(), 1234);
    expect(await widthOf(), 1920);
  });

  test('network storages are never probed', () async {
    final fake = _FakeProbe({
      '/abs/movies/x.mkv': const ProbeResult(durationMs: 1234),
    });

    final touched = await probeExplicitFiles(
      [target()],
      probeService: fake,
      isNetwork: (_) => true,
    );

    expect(touched, isEmpty);
    expect(fake.probed, isEmpty);
    expect(await durationOf(), isNull);
  });

  test('an empty probe result writes nothing', () async {
    final fake = _FakeProbe(const {});

    final touched = await probeExplicitFiles(
      [target()],
      probeService: fake,
      isNetwork: (_) => false,
    );

    expect(touched, isEmpty);
    expect(await durationOf(), isNull);
  });

  test('absurd dimensions are sanitized but the duration still lands',
      () async {
    final fake = _FakeProbe({
      '/abs/movies/x.mkv': const ProbeResult(
        durationMs: 999,
        width: 667040,
        height: 451896,
      ),
    });

    await probeExplicitFiles(
      [target()],
      probeService: fake,
      isNetwork: (_) => false,
    );

    expect(await durationOf(), 999);
    expect(await widthOf(), isNull);
  });

  test('an empty target list short-circuits', () async {
    final fake = _FakeProbe(const {});
    expect(
      await probeExplicitFiles(
        const [],
        probeService: fake,
        isNetwork: (_) => false,
      ),
      isEmpty,
    );
  });

  test('listing size/mtime land even when the probe yields no duration',
      () async {
    // This is the "rescan never fixed the size" regression: the write-back used
    // to be gated on a probed duration, so a container the probe cannot open
    // (or a probe-less run) left size 0 / mtime NULL forever.
    final fake = _FakeProbe(const {});
    final mtime = DateTime.fromMillisecondsSinceEpoch(1700000000000);

    final touched = await probeExplicitFiles(
      [
        ExplicitFileProbeTarget(
          storageId: 's',
          path: 'movies/x.mkv',
          uri: '/abs/movies/x.mkv',
          sizeInBytes: 4096,
          modifiedAt: mtime,
        ),
      ],
      probeService: fake,
      isNetwork: (_) => false,
    );

    expect(touched, {'s'});
    final node = await DbModule.mediaNodeRepo
        .getNodeByPath(storageId: 's', path: const ['movies', 'x.mkv']);
    final file = node!.maybeMap(file: (f) => f, orElse: () => null)!;
    expect(file.sizeInBytes, 4096);
    expect(file.modifiedAt!.millisecondsSinceEpoch, mtime.millisecondsSinceEpoch);
    expect(file.durationMs, isNull);
  });

  test('an unknown (0) listing size never erases a stored one', () async {
    final fake = _FakeProbe(const {});

    await probeExplicitFiles(
      const [
        ExplicitFileProbeTarget(
          storageId: 's',
          path: 'movies/x.mkv',
          uri: '/abs/movies/x.mkv',
          sizeInBytes: 0,
        ),
      ],
      probeService: fake,
      isNetwork: (_) => false,
    );

    final node = await DbModule.mediaNodeRepo
        .getNodeByPath(storageId: 's', path: const ['movies', 'x.mkv']);
    final file = node!.maybeMap(file: (f) => f, orElse: () => null)!;
    // Nothing known → nothing written; the row keeps its (null) size.
    expect(file.sizeInBytes, isNull);
  });

  group('probing disabled', () {
    test('still heals size/mtime from the listing, without probing', () async {
      // The preference turns off the deep probe, NOT the write-back: "rescan
      // file/source" must still fix a 0/NULL size row, which is why the old
      // early return contradicted this file's own contract.
      final fake = _FakeProbe({
        '/abs/movies/x.mkv': const ProbeResult(durationMs: 1234),
      });
      final mtime = DateTime.fromMillisecondsSinceEpoch(1700000000000);

      final outcome = await probeExplicitFilesDetailed(
        [
          ExplicitFileProbeTarget(
            storageId: 's',
            path: 'movies/x.mkv',
            uri: '/abs/movies/x.mkv',
            sizeInBytes: 4096,
            modifiedAt: mtime,
          ),
        ],
        probeService: fake,
        isNetwork: (_) => false,
        probeEnabled: false,
      );

      expect(fake.probed, isEmpty,
          reason: 'a disabled probe must not touch the probe service at all');
      expect(outcome.written, 1);
      expect(outcome.touchedStorages, {'s'});
      expect(await sizeOf(), 4096);
      expect(await durationOf(), isNull,
          reason: 'no probe ran, so no duration can appear');
    });

    test('writes nothing when the listing knows no physical facts', () async {
      final fake = _FakeProbe(const {});

      final outcome = await probeExplicitFilesDetailed(
        [target()],
        probeService: fake,
        isNetwork: (_) => false,
        probeEnabled: false,
      );

      expect(fake.probed, isEmpty);
      expect(outcome.written, 0);
      expect(outcome.touchedStorages, isEmpty);
    });
  });
}
