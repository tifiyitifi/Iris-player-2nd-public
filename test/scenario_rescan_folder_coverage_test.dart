import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/scenario_media_rescan_actions.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/models/db/storage_path_codec.dart';

// Whether a queue already sources a folder decides if "Rescan containing
// folder" needs to ask about adding a source at all.
void main() {
  ScenarioSource folder(
    String path, {
    bool recursive = false,
    String storageId = 'st1',
  }) =>
      ScenarioSource(
        id: 1,
        scenarioId: 's',
        storageId: storageId,
        path: path,
        recursive: recursive,
        sourceKind: ScenarioSourceKind.folder,
      );

  group('ScenarioRescanTargets.folderCovered', () {
    test('exact path matches whether recursive or not', () {
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('a/b')], storageId: 'st1', folderRel: 'a/b'),
        isTrue,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('a/b', recursive: true)],
            storageId: 'st1',
            folderRel: 'a/b'),
        isTrue,
      );
    });

    test('a recursive ancestor covers descendants; a non-recursive one does not',
        () {
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('a', recursive: true)],
            storageId: 'st1',
            folderRel: 'a/b/c'),
        isTrue,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('a')], storageId: 'st1', folderRel: 'a/b'),
        isFalse,
      );
    });

    test('whole-storage source semantics', () {
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('', recursive: true)],
            storageId: 'st1',
            folderRel: 'x/y'),
        isTrue,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('')], storageId: 'st1', folderRel: ''),
        isTrue,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('')], storageId: 'st1', folderRel: 'x'),
        isFalse,
      );
    });

    test('siblings and other storages do not cover', () {
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('a/b', recursive: true)],
            storageId: 'st1',
            folderRel: 'a/bc'),
        isFalse,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('a', recursive: true, storageId: 'st2')],
            storageId: 'st1',
            folderRel: 'a/b'),
        isFalse,
      );
    });

    test('file sources never cover a folder', () {
      final fileSource = ScenarioSource(
        id: 1,
        scenarioId: 's',
        storageId: 'st1',
        path: 'a/b.mp4',
        sourceKind: ScenarioSourceKind.file,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [fileSource], storageId: 'st1', folderRel: 'a'),
        isFalse,
      );
    });

    test('foldCase matches a case-only variant (Windows drive/UNC)', () {
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('Movies', recursive: true)],
            storageId: 'st1',
            folderRel: 'movies/Sub',
            foldCase: true),
        isTrue,
      );
      // Default (POSIX/SAF/remote) stays byte-exact.
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('Movies', recursive: true)],
            storageId: 'st1',
            folderRel: 'movies/Sub'),
        isFalse,
      );
    });
  });

  group('ScenarioRescanTargets.folderCovered with base-inclusive rows', () {
    setUp(() {
      StoragePathCodec.baseResolver =
          (id) => id == 'st1' ? const ['D:'] : null;
    });
    tearDown(() => StoragePathCodec.baseResolver = (_) => null);

    test('a base-inclusive source still covers its storage-relative folder',
        () {
      // Drag-drop / override selections store the base-inclusive form; the
      // rescan scope computes a storage-relative folderRel — the two must
      // still match, or an already-sourced folder is re-prompted as new.
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('D:/a/b', recursive: true)],
            storageId: 'st1',
            folderRel: 'a/b'),
        isTrue,
      );
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('D:/a/b')],
            storageId: 'st1',
            folderRel: 'a/b'),
        isTrue,
      );
      // A sibling is still not covered.
      expect(
        ScenarioRescanTargets.folderCovered(
            sources: [folder('D:/a/b', recursive: true)],
            storageId: 'st1',
            folderRel: 'a/c'),
        isFalse,
      );
    });
  });
}
