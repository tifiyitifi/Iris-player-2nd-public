import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/player/step_seek_mode.dart';
import 'package:iris/models/enums/step_seek_mode.dart';
import 'package:iris/models/store/app_state.dart';

void main() {
  group('resolveStepSeekMode', () {
    test('returns the stored mode while the metadata gate is ON', () {
      const AppState s = AppState(stepSeekMode: StepSeekMode.precise);
      expect(resolveStepSeekMode(s, metadataEnabled: true), StepSeekMode.precise);
      const AppState a = AppState(stepSeekMode: StepSeekMode.adaptive);
      expect(
          resolveStepSeekMode(a, metadataEnabled: true), StepSeekMode.adaptive);
    });

    test('degrades to precise while the metadata gate is OFF', () {
      const AppState s = AppState(stepSeekMode: StepSeekMode.adaptive);
      expect(
          resolveStepSeekMode(s, metadataEnabled: false), StepSeekMode.precise);
    });

    test('default is adaptive', () {
      expect(const AppState().stepSeekMode, StepSeekMode.adaptive);
    });
  });
}
