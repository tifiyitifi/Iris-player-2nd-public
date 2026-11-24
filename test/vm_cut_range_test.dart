import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';

/// A mergeable cut replaces the segment's duration with the plan's CUT length,
/// so undoing it must restore the SOURCE duration from an explicit value: the
/// receiver's `durationMs` is the cut length by then.
VirtualSegment segment({int durationMs = 60000, VmCutRange? cut}) =>
    VirtualSegment(
      mediaKey: 'st1:a.mp4',
      storageId: 'st1',
      path: const <String>['a.mp4'],
      name: 'a.mp4',
      parentPath: '',
      durationMs: durationMs,
      cutRange: cut,
    );

VmCutRange range(int startMs, int durationMs) => VmCutRange.single(
      planPath: '/x/a.llc',
      sourceStartMs: startMs,
      durationMs: durationMs,
    );

void main() {
  test('withCutRange turns the source into the cut length', () {
    final VirtualSegment cut = segment().withCutRange(range(10000, 19000));
    expect(cut.durationMs, 19000);
    expect(cut.cutRange!.durationMs, 19000);
  });

  test('withCutRange(null) restores the source duration when told', () {
    final VirtualSegment cut = segment().withCutRange(range(10000, 19000));
    final VirtualSegment restored =
        cut.withCutRange(null, sourceDurationMs: 60000);
    expect(restored.durationMs, 60000);
    expect(restored.cutRange, isNull);
  });

  test(
      'withCutRange(null) cannot guess the source, so it keeps the current '
      'duration unless the caller supplies it', () {
    final VirtualSegment cut = segment().withCutRange(range(10000, 19000));
    final VirtualSegment restored = cut.withCutRange(null);
    expect(restored.durationMs, 19000,
        reason: 'a cut receiver no longer knows its source length');
  });
}
