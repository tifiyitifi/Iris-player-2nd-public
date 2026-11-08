import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/fake_cut_pairing.dart';
import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:path/path.dart' as p;

/// The VM skip decision is a FILESYSTEM fact: does this video have a sibling
/// LosslessCut project? Pairing must be per-video (a folder with one project
/// must not exclude every episode) and must survive an unreadable project.
void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('iris_fake_cut_index');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  Future<String> writeProject(
    String dir,
    String name,
    String mediaFileName,
  ) async {
    final File file = File(p.join(dir, name));
    await file.writeAsString('''
{
  version: 2,
  mediaFileName: '$mediaFileName',
  cutSegments: [{ start: 1, end: 2, name: '', selected: true }],
}
''');
    return file.path;
  }

  FakeCutProjectQuery query(String path) => (
        mediaKey: 'storage:$path',
        name: p.basename(path),
        uri: path,
      );

  test('pairs a project by its recorded mediaFileName', () async {
    final String video = p.join(root.path, 'ep02.mp4');
    await writeProject(root.path, 'ep02-proj.llc', 'ep02.mp4');
    final index = FakeCutProjectIndex();

    expect(await index.mediaKeysWithProject(<FakeCutProjectQuery>[
      query(video),
    ]), <String>{'storage:$video'});
  });

  test('a project for one episode does not exclude its neighbours', () async {
    final String withProject = p.join(root.path, 'ep02.mp4');
    final String without = p.join(root.path, 'ep03.mp4');
    await writeProject(root.path, 'ep02-proj.llc', 'ep02.mp4');
    final index = FakeCutProjectIndex();

    expect(
      await index.mediaKeysWithProject(<FakeCutProjectQuery>[
        query(withProject),
        query(without),
      ]),
      <String>{'storage:$withProject'},
    );
  });

  test('each video resolves ONLY its own project paths', () async {
    final String a = p.join(root.path, 'a.mp4');
    final String b = p.join(root.path, 'b.mp4');
    // Both videos exist: a project for `b` is matched, not an orphan.
    await File(a).writeAsBytes(const <int>[0]);
    await File(b).writeAsBytes(const <int>[0]);
    await writeProject(root.path, 'a-proj.llc', 'a.mp4');
    await writeProject(root.path, 'b-proj.llc', 'b.mp4');
    await writeProject(root.path, 'orphan.llc', 'gone.mp4');
    final index = FakeCutProjectIndex();

    expect(
      (await index.projectsForVideo(a)).map((LlcSibling s) => s.fileName),
      <String>['a-proj.llc'],
    );
    expect(
      (await index.projectsForVideo(b)).map((LlcSibling s) => s.fileName),
      <String>['b-proj.llc'],
    );
    expect(
      (await index.unmatchedProjectsFor(a)).map((LlcSibling s) => s.fileName),
      <String>['orphan.llc'],
    );
  });

  test('falls back to the -proj stem when mediaFileName cannot be read',
      () async {
    final String video = p.join(root.path, 'movie.mp4');
    // Deliberately broken JSON5: the name is unusable, the stem is not.
    await File(p.join(root.path, 'movie-proj.llc')).writeAsString('{ nope');
    final index = FakeCutProjectIndex();

    expect(
      await index.mediaKeysWithProject(
          <FakeCutProjectQuery>[query(video)]),
      <String>{'storage:$video'},
    );
  });

  test('a plain <name>.llc pairs by stem too', () async {
    final String video = p.join(root.path, 'show.mkv');
    await File(p.join(root.path, 'show.llc')).writeAsString('{ nope');
    final index = FakeCutProjectIndex();

    expect(await index.hasProjectFor(query(video)), isTrue);
  });

  test('non-project siblings and non-local uris never match', () async {
    final String video = p.join(root.path, 'movie.mp4');
    await File(p.join(root.path, 'notes.txt')).writeAsString('hello');
    final index = FakeCutProjectIndex();

    expect(await index.hasProjectFor(query(video)), isFalse);
    expect(
      await index.hasProjectFor(
          (mediaKey: 's:x', name: 'x.mp4', uri: 'content://tree/x.mp4')),
      isFalse,
    );
    expect(
      await index.hasProjectFor(
          (mediaKey: 's:r', name: 'r.mp4', uri: 'https://dav/r.mp4')),
      isFalse,
    );
  });

  test('listings are cached until invalidated', () async {
    final String video = p.join(root.path, 'movie.mp4');
    final index = FakeCutProjectIndex();
    expect(await index.hasProjectFor(query(video)), isFalse);

    await writeProject(root.path, 'movie-proj.llc', 'movie.mp4');
    // Cached: the new project is invisible until an explicit refresh.
    expect(await index.hasProjectFor(query(video)), isFalse);

    index.invalidate();
    expect(await index.hasProjectFor(query(video)), isTrue);
  });

  test('a missing directory is an empty answer, never a throw', () async {
    final index = FakeCutProjectIndex();
    expect(
      await index.hasProjectFor((
        mediaKey: 's:gone',
        name: 'gone.mp4',
        uri: p.join(root.path, 'nope', 'gone.mp4'),
      )),
      isFalse,
    );
  });

  test('a FAILED listing is not cached as "no projects"', () async {
    final String video = p.join(root.path, 'ep01.mp4');
    final index = FakeCutProjectIndex();
    int calls = 0;
    FakeCutProjectIndex.debugReadDirectory = (String dirPath) async {
      calls++;
      if (calls == 1) {
        throw const FileSystemException('drive not ready');
      }
      return FakeCutDirProjects(
        projects: <LlcSibling>[
          LlcSibling(
            path: p.join(root.path, 'ep01-proj.llc'),
            mediaFileName: 'ep01.mp4',
          ),
        ],
      );
    };
    addTearDown(() => FakeCutProjectIndex.debugReadDirectory = null);

    // The failing pass answers "none" (grouping must keep working)...
    expect(await index.hasProjectFor(query(video)), isFalse);
    expect(calls, 1);
    // ...but leaves no cached verdict, so the NEXT resolve retries — one
    // transient IO error used to disable 简播 for that folder all session.
    expect(await index.hasProjectFor(query(video)), isTrue);
    expect(calls, 2);
  });
}
