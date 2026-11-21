import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/view/segment_abp_slider.dart';

/// With no 副音 file loaded the editor's bg row still paints a live [Slider]
/// over a `0..1` track. Dragging it projected `value - bgOffsetMs` onto the
/// FOREGROUND axis, so touching the visibly empty row yanked the video. The
/// row must read as "not a gesture" instead.
void main() {
  test('an empty bg row has no seek target', () {
    expect(
      bgRowDragTargetMs(
          value: 0.5, bgDurMs: 0, bgOffsetMs: 0, fgDurMs: 600000),
      isNull,
    );
    expect(
      bgRowDragTargetMs(
          value: 0.5, bgDurMs: 120000, bgOffsetMs: 0, fgDurMs: 0),
      isNull,
      reason: 'an unknown foreground length cannot be a target either',
    );
  });

  test('a real bg row still projects onto the foreground axis', () {
    expect(
      bgRowDragTargetMs(
          value: 60000, bgDurMs: 120000, bgOffsetMs: 0, fgDurMs: 600000),
      60000,
    );
    expect(
      bgRowDragTargetMs(
          value: 0, bgDurMs: 120000, bgOffsetMs: 5000, fgDurMs: 600000),
      0,
      reason: 'the projection is clamped into the foreground file',
    );
    expect(
      bgRowDragTargetMs(
          value: 119000, bgDurMs: 120000, bgOffsetMs: 5000, fgDurMs: 600000),
      114000,
    );
  });
}
