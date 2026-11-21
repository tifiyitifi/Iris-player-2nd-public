import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/view/segment_abp_slider.dart';

/// The A/P/B editor's timeline is `fg row → gap → bg row` and NOTHING else
/// (`segment_align_edit_panel.dart`, `_Timeline._build`). The track centres and
/// the section height are what the link painter and the enclosing `SizedBox`
/// use, so they must describe that column exactly: an extra row's worth of
/// height put the fg↔bg connector and the A/B edge rules 22px BELOW the bg
/// track and left a blank strip under the section.
void main() {
  test('the timeline column is exactly two track rows and the gap', () {
    expect(
      kSegmentTimelineHeight,
      kSegmentTrackRowHeight * 2 + kSegmentGapAfterFg,
      reason: 'the timeline budgets no row beyond fg + gap + bg',
    );
    expect(
      kSegmentBgTrackCenter,
      kSegmentTrackRowHeight + kSegmentGapAfterFg + kSegmentTrackRowHeight / 2,
      reason: 'the bg track centre is one row + the gap below the fg centre',
    );
    expect(
      kSegmentFgTrackCenter,
      kSegmentTrackRowHeight / 2,
      reason: 'the fg track starts the column',
    );
  });
}
