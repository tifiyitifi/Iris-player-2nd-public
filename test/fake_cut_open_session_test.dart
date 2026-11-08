import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/playback/fake_cut_session.dart';
import 'package:iris/models/file.dart';
import 'package:path/path.dart' as p;

/// Resolving the 简播 session for an OPEN is total: a project that cannot be
/// read, a source that moved, an unwritable cache — every one of them means
/// "play the untouched source", never an exception out of `init`.
///
/// Before this contract the plan lookup (`FakeCutStore.ensureActivePlan`) could
/// throw (a hand-edited timecode, a pathological project file): the open then
/// aborted halfway, `player.open` never ran, and the PREVIOUS file's session
/// stayed attached — so that file's progress was written through the old plan's
/// timeline.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('iris_fake_cut_open');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  FileItem fileAt(String path) => FileItem(
        name: p.basename(path),
        uri: path,
        path: <String>[p.basename(path)],
        durationMs: 60000,
      );

  FakeCutPlan planAt(String planPath) => FakeCutPlan(
        planPath: planPath,
        displayName: 'ep01',
        version: 2,
        segments: <FakeCutSegment>[
          const FakeCutSegment(index: 0, startMs: 1000, endMs: 2000),
        ],
      );

  test('a plan lookup that throws plays the source (never aborts the open)',
      () async {
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);

    final FakeCutSession? session = await resolveFakeCutSessionFor(
      file: fileAt(video),
      resolvePlan: (FileItem _) async =>
          throw const FormatException('bad timecode'),
    );

    expect(session, isNull);
  });

  test('no remembered plan is no session', () async {
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);

    expect(
      await resolveFakeCutSessionFor(
        file: fileAt(video),
        resolvePlan: (FileItem _) async => null,
      ),
      isNull,
    );
  });

  test('a source that is no longer a readable file plays nothing cut',
      () async {
    final String video = p.join(root.path, 'moved.mp4');

    expect(
      await resolveFakeCutSessionFor(
        file: fileAt(video),
        resolvePlan: (FileItem _) async => planAt(p.join(root.path, 'ep01.llc')),
      ),
      isNull,
    );
  });

  test('an empty plan is no session', () async {
    final String video = p.join(root.path, 'ep01.mp4');
    await File(video).writeAsBytes(const <int>[0]);
    final FakeCutPlan empty = FakeCutPlan(
      planPath: p.join(root.path, 'ep01.llc'),
      displayName: 'ep01',
      version: 2,
      segments: const <FakeCutSegment>[],
    );

    expect(
      await resolveFakeCutSessionFor(
        file: fileAt(video),
        resolvePlan: (FileItem _) async => empty,
      ),
      isNull,
    );
  });
}
