import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_explicit_item.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_source.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/resolver/explicit_redundancy.dart';

ScenarioSource _source({
  int id = 1,
  String scenarioId = 'scn',
  String storageId = 's',
  String path = '',
  bool recursive = false,
  ScenarioSourceKind kind = ScenarioSourceKind.folder,
}) =>
    ScenarioSource(
      id: id,
      scenarioId: scenarioId,
      storageId: storageId,
      path: path,
      recursive: recursive,
      sourceKind: kind,
    );

ScenarioExplicitItem _item({
  int id = 1,
  String storageId = 's',
  String path = 'a/b.mp4',
}) =>
    ScenarioExplicitItem(
      id: id,
      scenarioId: 'scn',
      storageId: storageId,
      path: path,
    );

void main() {
  group('scenarioSourceCoversFile (directory-source redundancy)', () {
    test('recursive directory covers self and any depth', () {
      final src = _source(path: 'a', recursive: true);
      expect(scenarioSourceCoversFile(src, 's', 'a/b.mp4'), isTrue);
      expect(scenarioSourceCoversFile(src, 's', 'a/b/c/d.mp4'), isTrue);
      expect(scenarioSourceCoversFile(src, 's', 'a'), isTrue);
    });

    test('recursive directory does not cover sibling prefix or other storage',
        () {
      final src = _source(path: 'a', recursive: true);
      expect(scenarioSourceCoversFile(src, 's', 'ab/x.mp4'), isFalse);
      expect(scenarioSourceCoversFile(src, 's', 'b/x.mp4'), isFalse);
      expect(scenarioSourceCoversFile(src, 'other', 'a/x.mp4'), isFalse);
    });

    test('non-recursive directory covers direct children only', () {
      final src = _source(path: 'a', recursive: false);
      expect(scenarioSourceCoversFile(src, 's', 'a/b.mp4'), isTrue);
      expect(scenarioSourceCoversFile(src, 's', 'a/b/c.mp4'), isFalse);
      // The directory itself is not a file.
      expect(scenarioSourceCoversFile(src, 's', 'a'), isFalse);
    });

    test('recursive whole-storage (empty path) covers every file', () {
      final src = _source(path: '', recursive: true);
      expect(scenarioSourceCoversFile(src, 's', 'b.mp4'), isTrue);
      expect(scenarioSourceCoversFile(src, 's', 'deep/nested/x.mp4'), isTrue);
      expect(scenarioSourceCoversFile(src, 'other', 'x.mp4'), isFalse);
    });

    test('non-recursive whole-storage (empty path) covers root files only', () {
      final src = _source(path: '');
      expect(scenarioSourceCoversFile(src, 's', 'b.mp4'), isTrue);
      // A non-recursive root source resolves to the root's direct children
      // only, so a deep file is NOT covered and must not be cleaned up.
      expect(scenarioSourceCoversFile(src, 's', 'deep/nested/x.mp4'), isFalse);
      expect(scenarioSourceCoversFile(src, 'other', 'x.mp4'), isFalse);
    });

    test('single-file source never counts as coverage', () {
      final src = _source(
        path: 'a/b.mp4',
        kind: ScenarioSourceKind.file,
      );
      expect(scenarioSourceCoversFile(src, 's', 'a/b.mp4'), isFalse);
    });

    test('slash variants canonicalize to the same file', () {
      final src = _source(path: 'a', recursive: true);
      expect(scenarioSourceCoversFile(src, 's', '/a/b.mp4'), isTrue);
      expect(scenarioSourceCoversFile(src, 's', 'a//b.mp4'), isTrue);
    });
  });

  group('isRedundantExplicitItem / redundantExplicitItems', () {
    test('an explicit item under a directory source is redundant', () {
      final sources = [_source(path: 'shows', recursive: true)];
      expect(
        isRedundantExplicitItem(_item(path: 'shows/e1.mp4'), sources),
        isTrue,
      );
      expect(
        isRedundantExplicitItem(_item(path: 'other/e1.mp4'), sources),
        isFalse,
      );
    });

    test('redundantExplicitItems preserves order and selects only covered', () {
      final sources = [_source(path: 'shows', recursive: true)];
      final items = [
        _item(id: 1, path: 'shows/a.mp4'), // covered
        _item(id: 2, path: 'movies/b.mp4'), // not covered
        _item(id: 3, path: 'shows/deep/c.mp4'), // covered
        _item(id: 4, storageId: 'other', path: 'shows/d.mp4'), // other storage
      ];
      final result =
          redundantExplicitItems(sources: sources, items: items);
      expect(result.map((e) => e.id), [1, 3]);
    });

    test('no sources proves nothing redundant', () {
      expect(
        redundantExplicitItems(
          sources: const [],
          items: [_item(path: 'a/b.mp4')],
        ),
        isEmpty,
      );
    });
  });
}
