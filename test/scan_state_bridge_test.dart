import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/meta_settings/bridge/scan_state_bridge.dart';

void main() {
  group('ScanStateBridge', () {
    test('encode → apply roundtrips both preferences', () {
      const state = RecursiveScanState(
        autoCloseDelay: 7.5,
        autoClosePrompt: false,
      );
      final restored = ScanStateBridge.apply(
        ScanStateBridge.encodeRows(state),
        const RecursiveScanState(), // defaults 2.5 / true
      );
      expect(restored.autoCloseDelay, 7.5);
      expect(restored.autoClosePrompt, isFalse);
    });

    test('missing rows keep base values', () {
      final restored = ScanStateBridge.apply({}, const RecursiveScanState());
      expect(restored.autoCloseDelay, 2.5);
      expect(restored.autoClosePrompt, isTrue);
    });

    test('malformed rows are contained, never throw', () {
      final restored = ScanStateBridge.apply(
        {
          ScanStateBridge.key: '{broken',
          ScanStateBridge.promptKey: 'not-a-bool',
        },
        const RecursiveScanState(),
      );
      expect(restored.autoCloseDelay, 2.5);
      expect(restored.autoClosePrompt, isTrue);
    });

    test('only preferences are representable — runtime fields never leak', () {
      final noisy = const RecursiveScanState(
        autoCloseDelay: 4.0,
        autoClosePrompt: false,
        phase: ScanPhase.scanning,
        storageId: 's1',
        depthPaths: {0: ['C:/x']},
        progress: 0.42,
        totalDirs: 9,
        scannedDirs: 3,
        currentScanningPath: 'C:/x/y',
        error: null,
        paused: true,
      );
      expect(
        ScanStateBridge.encodeRows(noisy).keys.toSet(),
        {ScanStateBridge.key, ScanStateBridge.promptKey},
      );
    });
  });
}
