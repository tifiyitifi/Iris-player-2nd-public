import 'package:iris/models/enums/step_tail_finish_mode.dart';
import 'package:iris/models/store/app_state.dart';

// Pure resolver for the tail-step policy (`playback.stepTailFinish`).
// Follows the same contract as `resolveVideoCachePreset`: when the metadata
// gate is OFF the row is unavailable (DefVisibility hides it), so the run
// degrades to `strict` — the value the def declares as its default.

StepTailFinishMode resolveStepTailFinishMode(
  AppState state, {
  required bool metadataEnabled,
}) =>
    metadataEnabled ? state.stepTailFinishMode : StepTailFinishMode.strict;
