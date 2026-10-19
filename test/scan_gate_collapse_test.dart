import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';

/// A folder directory spec — the only shape the scan gate ever sees.
ScenarioSourceSpec _dir(String storageId, String path, {bool recursive = true}) =>
    (
      storageId: storageId,
      path: path,
      recursive: recursive,
      kind: ScenarioSourceKind.folder,
    );

/// Regression: a drop of many unscanned folders must gate through ONE dialog.
/// [collapseGateDirs] collapses ancestor-covered scopes per storage so a single
/// recursive scan covers them all; the resume is offered once, after the whole
/// chained scan batch finishes (see `_offerPendingWhenDone`).
void main() {
  group('collapseGateDirs', () {
    test('an ancestor scope covers its descendants', () {
      final out = collapseGateDirs([
        _dir('s', 'a/b'),
        _dir('s', 'a'),
        _dir('s', 'a/b/c'),
      ]);
      expect(out, [_dir('s', 'a')]);
    });

    test('the storage root covers everything on that storage', () {
      final out = collapseGateDirs([
        _dir('s', 'a'),
        _dir('s', ''),
      ]);
      expect(out, [_dir('s', '')]);
    });

    test('sibling scopes are all kept', () {
      final out = collapseGateDirs([
        _dir('s', 'a'),
        _dir('s', 'b'),
        _dir('s', 'c'),
      ]);
      expect(out.length, 3);
    });

    test('different storages never collapse into each other', () {
      final out = collapseGateDirs([
        _dir('s1', 'a'),
        _dir('s2', 'a'),
      ]);
      expect(out.length, 2);
    });

    test('non-recursive scopes are dropped (they never gate)', () {
      final out = collapseGateDirs([
        _dir('s', 'a', recursive: false),
        _dir('s', 'b'),
      ]);
      expect(out, [_dir('s', 'b')]);
    });

    test('Windows drive paths fold case (case-insensitive filesystem)', () {
      final out = collapseGateDirs([
        _dir('s', 'D:/Movies/A'),
        _dir('s', 'd:/movies/a/b'),
      ]);
      expect(out, [_dir('s', 'D:/Movies/A')]);
    });

    test('UNC share paths fold case', () {
      final out = collapseGateDirs([
        _dir('s', '//server/share/A'),
        _dir('s', '//server/share/a/b'),
      ]);
      expect(out.length, 1);
    });

    test('case-sensitive (POSIX / SAF / remote) paths are NOT collapsed', () {
      // Distinct folders differing only by case must both survive: folding them
      // would drop one from the batch and it would never be scanned.
      final out = collapseGateDirs([
        _dir('s', 'Movies/A'),
        _dir('s', 'movies/a/b'),
      ]);
      expect(out.length, 2);
    });

    test('case-sensitive descendant comparison stays segment-aligned', () {
      final out = collapseGateDirs([
        _dir('s', 'home/movies'),
        _dir('s', 'home/movies2'),
      ]);
      expect(out.length, 2);
    });
  });

  group('shouldRunScanGate', () {
    test('runs for a fresh action with recursive dirs', () {
      expect(
        shouldRunScanGate(skipGate: false, hasRecursiveDirs: true),
        isTrue,
      );
    });

    test('never re-gates on the post-scan resume', () {
      expect(
        shouldRunScanGate(skipGate: true, hasRecursiveDirs: true),
        isFalse,
      );
    });

    test('no recursive dirs means no gate', () {
      expect(
        shouldRunScanGate(skipGate: false, hasRecursiveDirs: false),
        isFalse,
      );
    });
  });
}
