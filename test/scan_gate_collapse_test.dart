import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/scan_play_gate.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';

/// Regression: a drop of many unscanned folders must gate through ONE dialog.
/// [collapseGateDirs] collapses ancestor-covered scopes per storage so a single
/// recursive scan covers them all; the resume is offered once, after the whole
/// chained scan batch finishes (see `_offerPendingWhenDone`).
void main() {
  group('collapseGateDirs', () {
    test('an ancestor scope covers its descendants', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'a/b', recursive: true),
        (storageId: 's', path: 'a', recursive: true),
        (storageId: 's', path: 'a/b/c', recursive: true),
      ]);
      expect(out, const <ScenarioSourceSpec>[
        (storageId: 's', path: 'a', recursive: true),
      ]);
    });

    test('the storage root covers everything on that storage', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'a', recursive: true),
        (storageId: 's', path: '', recursive: true),
      ]);
      expect(out, const <ScenarioSourceSpec>[
        (storageId: 's', path: '', recursive: true),
      ]);
    });

    test('sibling scopes are all kept', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'a', recursive: true),
        (storageId: 's', path: 'b', recursive: true),
        (storageId: 's', path: 'c', recursive: true),
      ]);
      expect(out.length, 3);
    });

    test('different storages never collapse into each other', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's1', path: 'a', recursive: true),
        (storageId: 's2', path: 'a', recursive: true),
      ]);
      expect(out.length, 2);
    });

    test('non-recursive scopes are dropped (they never gate)', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'a', recursive: false),
        (storageId: 's', path: 'b', recursive: true),
      ]);
      expect(out, const <ScenarioSourceSpec>[
        (storageId: 's', path: 'b', recursive: true),
      ]);
    });

    test('Windows drive paths fold case (case-insensitive filesystem)', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'D:/Movies/A', recursive: true),
        (storageId: 's', path: 'd:/movies/a/b', recursive: true),
      ]);
      expect(out, const <ScenarioSourceSpec>[
        (storageId: 's', path: 'D:/Movies/A', recursive: true),
      ]);
    });

    test('UNC share paths fold case', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: '//server/share/A', recursive: true),
        (storageId: 's', path: '//server/share/a/b', recursive: true),
      ]);
      expect(out.length, 1);
    });

    test('case-sensitive (POSIX / SAF / remote) paths are NOT collapsed', () {
      // Distinct folders differing only by case must both survive: folding them
      // would drop one from the batch and it would never be scanned.
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'Movies/A', recursive: true),
        (storageId: 's', path: 'movies/a/b', recursive: true),
      ]);
      expect(out.length, 2);
    });

    test('case-sensitive descendant comparison stays segment-aligned', () {
      final out = collapseGateDirs(const <ScenarioSourceSpec>[
        (storageId: 's', path: 'home/movies', recursive: true),
        (storageId: 's', path: 'home/movies2', recursive: true),
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
