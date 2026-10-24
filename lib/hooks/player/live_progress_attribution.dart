/// Whether a STEP press may act on the media bound to the hook.
///
/// mpv's seek commands are only meaningful for a loaded entry: `mp_seek()`
/// returns immediately without a demuxer (`player/playloop.c:311`), and the
/// switch itself clears whatever was queued (`player/loadfile.c:1825-1826`:
/// `last_seek_pts = 0.0; seek = {0}`, then `reset_playback_state()`). A relative
/// seek therefore always resolves against the CURRENT demuxer
/// (`playloop.c:337-340`), never against the previous file.
///
/// IRIS's advance is asynchronous, so between "queue advanced" and "the new
/// media's open/initialize returned" the hook holds a media whose engine state
/// still describes the PREVIOUS file. A step press in that window used to
/// combine the new `file` with the old `duration`/`position`, which armed a tail
/// finish for the old end and then collapsed the newly opened entry without ever
/// playing it:
///
/// ```text
/// completed fired src=step-eof … file=[Evelyn]        ← first finish (correct)
/// [step-tail] armed=false end=312106ms                ← re-arm with the OLD end
/// completed fired src=step-eof … file=<next entry> pos=311750ms dur=312106ms
/// ```
///
/// Requiring the open of THIS media to have completed ([openedUri]) is the Dart
/// equivalent of "there is a current demuxer". Presses arriving while a media is
/// switching are dropped — the same thing mpv does (the press is queued onto the
/// old entry's state and cleared by `play_current_file`).
bool shouldAcceptStepPress({
  required String? mediaUri,
  required String? openedUri,
}) {
  if (mediaUri == null || mediaUri.isEmpty) return false;
  return openedUri == mediaUri;
}

/// What a step press must do right now (see [shouldAcceptStepPress]).
enum StepPressGate {
  /// The media is loaded and owned by this hook: step normally.
  accept,

  /// A media switch is in flight (or this hook is advancing the queue): the
  /// press would be resolved against the previous file's state — drop it.
  dropMediaSwitching,
}

/// The single entry decision for a step press (`←` / `→`, double-tap, dial).
///
/// Both player hooks call this BEFORE touching position/duration so the guard
/// cannot drift between backends, and `test/step_switch_window_test.dart` drives
/// the same function: removing the guard from a hook (or from here) fails that
/// regression test instead of silently skipping episodes in the field.
StepPressGate gateStepPress({
  required String? mediaUri,
  required String? openedUri,
  required bool dispatchInFlight,
}) {
  if (dispatchInFlight) return StepPressGate.dropMediaSwitching;
  if (!shouldAcceptStepPress(mediaUri: mediaUri, openedUri: openedUri)) {
    return StepPressGate.dropMediaSwitching;
  }
  return StepPressGate.accept;
}

/// Whether a live-progress sample may be attributed to the media the hook is
/// currently bound to.
///
/// The 1 s live-progress timer outlives the media switch by at least one tick:
/// `player.state` still carries the PREVIOUS file's position/duration while the
/// hook has already been rebuilt for the NEXT queue entry. Both hook writers
/// (the periodic tick and the effect's dispose write) used the new file's key
/// with that stale sample, which is exactly the "next episode resumes at the
/// previous episode's tail" defect:
///
/// ```text
/// [log.player] persist skipped ... file=[sodeno19] ... pos=381141ms
/// [log.scenario.queue] liveProgress key=…[ZMSFM]… hit pos=381141
/// [log.player] progress-write [timer] 44152->6958 ... BLOCKED
/// ```
///
/// mpv is a single-media context: `loadfile` resets the playback state, so a
/// `time-pos` sample can never be attributed to the next entry. IRIS emulates
/// that by requiring the sample to belong to the media whose OPEN has already
/// completed ([openUri]) AND to still be the hook's current media
/// ([latestUri]).
///
/// Pure so the attribution contract is unit-testable without a player.
bool shouldAttributeLiveProgress({
  required String? sampleUri,
  required String? openUri,
  required String? latestUri,
}) {
  if (sampleUri == null || sampleUri.isEmpty) return false;
  // Open not finished yet: `player.state` still describes the previous media.
  if (openUri != sampleUri) return false;
  // A newer media is already bound to the hook: this closure is stale.
  if (latestUri != sampleUri) return false;
  return true;
}
