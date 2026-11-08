import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:path/path.dart' as p;

/// Which plan a window plays, and whether the cached parse may be reused.
///
/// Both edges used to be "the answer once computed": a project scanned before
/// the container duration was probed stayed unclamped in the tab, and an edited
/// `.llc` kept replaying the timeline it had the first time.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late FakeCutStore store;

  String project({
    required int endSeconds,
    String name = '',
    String mediaFileName = 'ep01.mp4',
  }) =>
      '''
{
  version: 2,
  mediaFileName: '$mediaFileName',
  cutSegments: [{ start: 1, end: $endSeconds, name: '$name', selected: true }],
}
''';

  setUp(() async {
    setKvStoreForTest(MemoryKvStore());
    root = await Directory.systemTemp.createTemp('iris_fake_cut_store');
    store = FakeCutStore();
    await store.initialized;
  });

  tearDown(() async {
    await store.dispose();
    resetKvStoreForTest();
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('the plan list is re-scanned once the source duration is known',
      () async {
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    await File(p.join(root.path, 'ep01.llc')).writeAsString(project(endSeconds: 120));

    final FileItem unprobed = FileItem(
      name: 'ep01.mp4',
      uri: video,
      path: const <String>['ep01.mp4'],
      durationMs: null,
    );
    await store.discover(unprobed);
    expect(
      store.state.plansByFile[fakeCutFileKey(unprobed)]!.single.plan!.segments
          .single.endMs,
      120000,
      reason: 'unknown duration leaves the range unclamped',
    );

    // The container probe lands: the tab's effect re-runs discover() with the
    // same file. The cached scan must NOT answer for it any more.
    final FileItem probed = unprobed.copyWith(durationMs: 60000);
    await store.discover(probed);
    expect(
      store.state.plansByFile[fakeCutFileKey(probed)]!.single.plan!.segments
          .single.endMs,
      60000,
      reason: 'the scan is rebuilt against the real duration',
    );

    // A repeat with the same duration stays cached (no folder listing storm).
    await store.discover(probed);
    expect(store.state.scannedDurationMs[fakeCutFileKey(probed)], 60000);
  });

  test('a duration that lands while the scan is in flight is not lost',
      () async {
    // The tab's effect runs on bind and again when the container probe lands.
    // With a slow folder listing the second call arrives while the first scan
    // is still running; the in-flight guard used to drop it, leaving the plan
    // built against "duration unknown" until the user switched files.
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    await File(p.join(root.path, 'ep01.llc'))
        .writeAsString(project(endSeconds: 120));

    final FileItem unprobed = FileItem(
      name: 'ep01.mp4',
      uri: video,
      path: const <String>['ep01.mp4'],
      durationMs: null,
    );
    final Future<void> first = store.discover(unprobed);
    final FileItem probed = unprobed.copyWith(durationMs: 60000);
    await store.discover(probed); // lands behind the in-flight scan
    await first; // the queued request is drained before this completes

    expect(store.state.scannedDurationMs[fakeCutFileKey(probed)], 60000,
        reason: 'the request that knew the duration must still be answered');
    expect(
      store.state.plansByFile[fakeCutFileKey(probed)]!.single.plan!.segments
          .single.endMs,
      60000,
      reason: 'the rebuilt scan clamps the range to the real duration',
    );
  });

  test('a remembered plan is not a playing cut', () async {
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    await File(p.join(root.path, 'ep01.llc'))
        .writeAsString(project(endSeconds: 20));
    final FileItem file = FileItem(
      name: 'ep01.mp4',
      uri: video,
      path: const <String>['ep01.mp4'],
      durationMs: 60000,
    );
    final FakeCutPlanSource source = (await FakeCutDiscovery.scan(
      videoPath: video,
      sourceDurationMs: 60000,
    ))
        .single;
    expect(await store.activate(file, source), isTrue);
    final String key = fakeCutFileKey(file);

    // Activation only REMEMBERS the plan. Whether the EDL really owns the
    // picture is decided by the media's open (temp dir, source, backend).
    expect(store.isCutPlaying(key), isFalse);

    store.noteCutPlaying(key);
    expect(store.isCutPlaying(key), isTrue);
    expect(store.isCutPlaying('someone-else'), isFalse);

    final String raw =
        (await getSessionKvStore().read(key: KvKeys.fakeCutActivePlans))!;
    expect((jsonDecode(raw) as Map<Object?, Object?>).keys, <Object?>[key],
        reason: 'the playing flag is runtime state, never persisted');

    store.noteCutPlaying(null);
    expect(store.isCutPlaying(key), isFalse);
    expect(store.activePathFor(key), isNotNull,
        reason: 'leaving the cut must not forget the plan');
  });

  test('an edited project is re-read on the next open', () async {
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    final File llc = File(p.join(root.path, 'ep01.llc'));
    await llc.writeAsString(project(endSeconds: 20));
    final FileItem file = FileItem(
      name: 'ep01.mp4',
      uri: video,
      path: const <String>['ep01.mp4'],
      durationMs: 60000,
    );

    final FakeCutPlanSource source = (await FakeCutDiscovery.scan(
      videoPath: video,
      sourceDurationMs: 60000,
    ))
        .single;
    expect(await store.activate(file, source), isTrue);
    expect((await store.ensureActivePlan(file))!.segments.single.endMs, 20000);

    // Edit the project (new range AND new size, so mtime granularity on any
    // filesystem still yields a different signature).
    await Future<void>.delayed(const Duration(milliseconds: 20));
    await llc.writeAsString(project(endSeconds: 30, name: 'edited'));
    expect(
      (await store.ensureActivePlan(file))!.segments.single.endMs,
      30000,
      reason: 'a matching path alone must not replay the last-parsed plan',
    );
  });

  test('a remembered project that became unreadable is dropped, not thrown',
      () async {
    // The open path (`ensureActivePlan`) had no try: a project edited into
    // something the parser cannot read threw out of `init`, so the media never
    // opened AND the previous file's session stayed attached.
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    final File llc = File(p.join(root.path, 'ep01.llc'));
    await llc.writeAsString(project(endSeconds: 20));
    final FileItem file = FileItem(
      name: 'ep01.mp4',
      uri: video,
      path: const <String>['ep01.mp4'],
      durationMs: 60000,
    );
    final FakeCutPlanSource source = (await FakeCutDiscovery.scan(
      videoPath: video,
      sourceDurationMs: 60000,
    ))
        .single;
    expect(await store.activate(file, source), isTrue);

    final String huge = '9' * 20;
    await llc.writeAsString('''
{
  version: 3,
  mediaFileName: 'ep01.mp4',
  cutSegments: [{ start: '$huge:00:00', end: '00:00:01.000000000' }],
}
''');
    expect(await store.ensureActivePlan(file), isNull,
        reason: 'an unreadable plan means "play the source"');
    expect(store.activePathFor(fakeCutFileKey(file)), isNull,
        reason: 'the unusable plan is forgotten, not retried on every open');
  });

  test('a plan for another video is invisible for this one', () async {
    // The reported folder: several videos in ONE directory, each with its own
    // project. ep01 must never see ep02's plan (the EDL is built over the
    // PLAYING file, which is how both projects ended up playing ep01).
    final String videoA = p.join(root.path, 'ep01.mp4');
    final String videoB = p.join(root.path, 'ep02.mp4');
    await File(videoA).writeAsBytes(const <int>[0]);
    await File(videoB).writeAsBytes(const <int>[0]);
    await File(p.join(root.path, 'ep02-proj.llc'))
        .writeAsString(project(endSeconds: 30, mediaFileName: 'ep02.mp4'));

    final FileItem fileA = FileItem(
      name: 'ep01.mp4',
      uri: videoA,
      path: const <String>['ep01.mp4'],
      durationMs: 60000,
    );
    await store.discover(fileA);

    expect(store.plansFor(fakeCutFileKey(fileA)), isEmpty,
        reason: 'ep02\'s plan is not ep01\'s plan');
  });

  test('an unmatched project is listed but cannot be activated', () async {
    // A project whose recorded source is gone (video renamed/moved) is the one
    // case that belongs to NO video: it is offered for information only.
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    await File(p.join(root.path, 'gone-proj.llc'))
        .writeAsString(project(endSeconds: 30, mediaFileName: 'gone.mp4'));

    final FileItem file = FileItem(
      name: 'ep01.mp4',
      uri: video,
      path: const <String>['ep01.mp4'],
      durationMs: 60000,
    );
    await store.discover(file);

    final List<FakeCutPlanSource> listed = store.plansFor(fakeCutFileKey(file));
    expect(listed, hasLength(1));
    expect(listed.single.bound, isFalse);
    expect(await store.activate(file, listed.single), isFalse);
    expect(store.activePathFor(fakeCutFileKey(file)), isNull);
  });
}
