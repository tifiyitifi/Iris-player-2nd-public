import 'package:iris/models/enums/step_seek_mode.dart';
import 'package:iris/models/store/app_state.dart';

// Pure resolver for the step-seek (← / →) scheduling strategy.
// Follows the same contract as `resolveVideoCachePreset` / `resolveResumeOnStartup`:
// when the metadata gate is OFF the row is unavailable (DefVisibility hides it),
// so the run degrades to `precise` — the serialized behaviour every legacy build
// already had. Both modes land each press precisely; only burst scheduling
// differs (see StepSeekMode).
StepSeekMode resolveStepSeekMode(
  AppState state, {
  required bool metadataEnabled,
}) =>
    metadataEnabled ? state.stepSeekMode : StepSeekMode.precise;
