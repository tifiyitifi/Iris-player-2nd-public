import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/playback/fake_cut_session.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/playback/vm_cut_open.dart';

/// A cut plan can be edited on disk while its group is alive (LosslessCut keeps
/// writing the same `.llc`). The player re-reads the project on every open, so a
/// changed plan makes the played EDL and the merged duration disagree unless the
/// group is re-derived (ADR 0034).
void main() {
  VmCutRange range(String signature) => VmCutRange.single(
        planPath: 'ep01.llc',
        planSignature: signature,
        sourceStartMs: 10000,
        durationMs: 30000,
      );

  FakeCutPlan plan({required int endMs}) => FakeCutPlan(
        planPath: 'ep01.llc',
        displayName: 'ep01',
        version: 2,
        segments: <FakeCutSegment>[
          FakeCutSegment(index: 0, startMs: 10000, endMs: endMs),
        ],
      );

  FakeCutSession session({required String signature, required int endMs}) =>
      FakeCutSession(
        plan: plan(endMs: endMs),
        edlPath: 'ep01.edl',
        sourceDurationMs: 60000,
        signature: signature,
      );

  test('an edited plan no longer matches the range the group showed', () {
    final VmCutOpen open = vmCutOpenResult(
      range('10000:40000,'),
      session(signature: '10000:45000,', endMs: 45000),
    );
    expect(open.regroup, isTrue,
        reason: 'the displayed duration still describes the old range');
    expect(open.session, isNotNull,
        reason: 'the open itself still plays the fresh plan');
  });

  test('an identical plan opens without re-deriving', () {
    final VmCutOpen open = vmCutOpenResult(
      range('10000:40000,'),
      session(signature: '10000:40000,', endMs: 40000),
    );
    expect(open.regroup, isFalse,
        reason: 'a touched-but-unchanged project must not re-derive anything');
    expect(open.session, isNotNull);
  });

  test('a plan that could not be opened turns the segment back to its source',
      () {
    final VmCutOpen open = vmCutOpenResult(range('10000:40000,'), null);
    expect(open.session, isNull);
    expect(open.regroup, isTrue,
        reason: 'a deleted/unusable project must not keep the old cut length');
  });
}
