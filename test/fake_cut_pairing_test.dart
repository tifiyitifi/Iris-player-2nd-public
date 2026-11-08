import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/fake_cut_pairing.dart';

/// 简播 binds a `.llc` to the ONE video it was made for, exactly the way a
/// subtitle binds to its sibling video (`get_subtitle_map.dart`): the LONGEST
/// name prefix wins, a tie reaches every tied video, and a project that names no
/// video in the folder is an ORPHAN — listed in the tab's collapsed section and
/// never applied to a video it does not describe.
///
/// The two fixtures below are the real names from a shared cut folder: a batch
/// folder holds many videos, so "list every project in the directory" bound both
/// projects to whichever video was playing.
void main() {
  // Real-world names from the reporting folder (CJK + an em dash + `-proj`).
  const String videoA = '汉服少女via VidBee.mp4';
  const String projectA = '汉服少女via VidBee-proj.llc';
  const String videoB =
      '與室友的真心話大冒險最終導致她的_ shinaryen — 愛沙尼亞 xHamster.mp4';
  const String projectB =
      '與室友的真心話大冒險最終導致她的_ shinaryen — 愛沙尼亞 xHamster-proj.llc';

  LlcSibling sibling(String fileName, {String? mediaFileName}) => LlcSibling(
        path: '/videos/$fileName',
        mediaFileName: mediaFileName,
      );

  test('each project binds to its own video in a shared folder', () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>[videoA, videoB, 'JUL-265.mp4', 'MIDV-472.mp4'],
      projects: <LlcSibling>[
        sibling(projectA, mediaFileName: videoA),
        sibling(projectB, mediaFileName: videoB),
      ],
    );

    expect(binding.forVideo(videoA).map((LlcSibling s) => s.fileName),
        <String>[projectA]);
    expect(binding.forVideo(videoB).map((LlcSibling s) => s.fileName),
        <String>[projectB]);
    expect(binding.forVideo('JUL-265.mp4'), isEmpty,
        reason: 'a video without a project gets an empty list');
    expect(binding.unmatched, isEmpty);
  });

  test('the recorded mediaFileName is authoritative over the project stem', () {
    // A project copied/renamed beside another video: what LosslessCut recorded
    // as the SOURCE is the truth, the file name is not.
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>[videoA, videoB],
      projects: <LlcSibling>[sibling(projectA, mediaFileName: videoB)],
    );

    expect(binding.forVideo(videoB).map((LlcSibling s) => s.fileName),
        <String>[projectA]);
    expect(binding.forVideo(videoA), isEmpty);
  });

  test('a project without mediaFileName pairs by stem (LosslessCut suffixes)',
      () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['movie.mp4'],
      projects: <LlcSibling>[
        sibling('movie.llc'),
        sibling('movie-proj.llc'),
        sibling('movie.proj.llc'),
        sibling('movieproj.llc'),
      ],
    );

    expect(
      binding.forVideo('movie.mp4').map((LlcSibling s) => s.fileName),
      <String>['movie.llc', 'movie-proj.llc', 'movie.proj.llc', 'movieproj.llc'],
      reason: 'one video may own several projects, like several subtitles',
    );
    expect(binding.unmatched, isEmpty);
  });

  test('a project extends only the episode it names, never a sibling', () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['Show.S01E01.mp4', 'Show.S02E01.mp4'],
      projects: <LlcSibling>[sibling('Show.S01E01.zh.llc')],
    );

    expect(binding.forVideo('Show.S01E01.mp4').map((LlcSibling s) => s.fileName),
        <String>['Show.S01E01.zh.llc']);
    expect(binding.forVideo('Show.S02E01.mp4'), isEmpty,
        reason: 'S02E01 only shares the `Show` prefix');
    expect(binding.unmatched, isEmpty);
  });

  test('an exact stem beats a longer sibling video name', () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['movie.extra.mp4', 'movie.mp4'],
      projects: <LlcSibling>[sibling('movie.llc')],
    );

    expect(binding.forVideo('movie.mp4'), hasLength(1));
    expect(binding.forVideo('movie.extra.mp4'), isEmpty);
  });

  test('a tied prefix attaches to every tied video (subtitle behaviour)', () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['Show.S01E01.1080p.mp4', 'Show.S01E01.720p.mp4'],
      projects: <LlcSibling>[sibling('Show.S01E01.zh.llc')],
    );

    expect(binding.forVideo('Show.S01E01.1080p.mp4'), hasLength(1));
    expect(binding.forVideo('Show.S01E01.720p.mp4'), hasLength(1));
  });

  test('an exact project stem outranks the LosslessCut suffix strip', () {
    // `movie-proj.llc` next to BOTH `movie.mp4` and `movie-proj.mp4`. The plain
    // `bases.contains(...)` rule attached the project to both, so activating it
    // on `movie.mp4` applied another file's cut points. The exact stem
    // (rule 2 — the video really is called `movie-proj`) wins.
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['movie.mp4', 'movie-proj.mp4'],
      projects: <LlcSibling>[sibling('movie-proj.llc')],
    );

    expect(binding.forVideo('movie-proj.mp4').map((LlcSibling s) => s.fileName),
        <String>['movie-proj.llc']);
    expect(binding.forVideo('movie.mp4'), isEmpty,
        reason: 'a cut plan may only ever be applied to the file it names');
  });

  test('the closest sibling wins over a longer one with the same prefix', () {
    // Both share two leading tokens; only the shorter name is the episode the
    // project names. Multi-binding here would offer another file's cut on the
    // `extra` featurette.
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['Show.S01E01.mp4', 'Show.S01E01.extra.mp4'],
      projects: <LlcSibling>[sibling('Show.S01E01.zh.llc')],
    );

    expect(binding.forVideo('Show.S01E01.mp4').map((LlcSibling s) => s.fileName),
        <String>['Show.S01E01.zh.llc']);
    expect(binding.forVideo('Show.S01E01.extra.mp4'), isEmpty);
  });

  test('equally close videos still share the project', () {
    // Identical stems (different container) are the same episode: there is no
    // way to tell them apart, so both offer the plan — the old tie behaviour,
    // now restricted to the CLOSEST candidates only.
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['Show.S01E01.mp4', 'Show.S01E01.mkv'],
      projects: <LlcSibling>[sibling('Show.S01E01.zh.llc')],
    );

    expect(binding.forVideo('Show.S01E01.mp4'), hasLength(1));
    expect(binding.forVideo('Show.S01E01.mkv'), hasLength(1));
  });

  test('a project naming no video in the folder is an orphan', () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['movie.mp4'],
      projects: <LlcSibling>[
        sibling('other.llc', mediaFileName: 'gone.mp4'),
        sibling('notes.llc'),
      ],
    );

    expect(binding.byVideo, isEmpty);
    expect(binding.unmatched.map((LlcSibling s) => s.fileName),
        <String>['other.llc', 'notes.llc']);
  });

  test('matching ignores case (Windows / NTFS and SMB)', () {
    final LlcBinding binding = bindLlcProjects(
      videoNames: <String>['EP01.MP4'],
      projects: <LlcSibling>[sibling('ep01-proj.llc', mediaFileName: 'ep01.mp4')],
    );

    expect(binding.forVideo('EP01.MP4'), hasLength(1));
    expect(binding.forVideo('ep01.mp4'), hasLength(1));
  });

  test('llcVideoStem drops LosslessCut default suffixes', () {
    expect(llcVideoStem('movie-proj'), 'movie');
    expect(llcVideoStem('movieproj'), 'movie');
    expect(llcVideoStem('movie.proj'), 'movie');
    expect(llcVideoStem('movie'), 'movie');
    expect(llcVideoStem('MOVIE-PROJ'), 'movie');
    expect(llcVideoStem('proj'), 'proj',
        reason: 'a video may legitimately be called `proj`');
  });
}
