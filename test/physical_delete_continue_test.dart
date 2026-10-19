import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/desktop_keyboard/executor/potplayer_key_executor.dart';

/// Regression: a desktop physical delete must keep the queue advancing.
///
/// Scenario mode has its own resume path; the non-scenario (legacy / paged)
/// queue only re-opens the advanced entry through the player's `[file]` effect
/// with `play: autoPlay`. When the user was watching (autoplay may be off) the
/// delete must re-arm autoplay so playback continues instead of parking on a
/// paused, swapped-out current item.
void main() {
  test('continues queue playback after a delete while playing (non-scenario)',
      () {
    expect(
      shouldContinueQueuePlaybackAfterDelete(
        scenarioMode: false,
        wasPlaying: true,
      ),
      isTrue,
    );
  });

  test('does not force playback when nothing was playing', () {
    expect(
      shouldContinueQueuePlaybackAfterDelete(
        scenarioMode: false,
        wasPlaying: false,
      ),
      isFalse,
    );
  });

  test('scenario mode drives its own resume path', () {
    expect(
      shouldContinueQueuePlaybackAfterDelete(
        scenarioMode: true,
        wasPlaying: true,
      ),
      isFalse,
    );
  });
}
