import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/domain/segment_edit_draft.dart';
import 'package:iris/features/background_playback/model/enum/mapping_action.dart';
import 'package:iris/features/background_playback/resolver/segment_span_math.dart';
import 'package:iris/features/background_playback/view/segment_edit_save.dart';

/// A saved row must record the duration of the 副音 file the DRAFT names.
///
/// `SegmentEditContext.bgDurMs` is the LIVE engine duration, while an existing
/// segment keeps its own `bgStorageId`/`bgPath` from the row. Entering the
/// editor from a playhead that is not inside a segment (the engine still plays
/// another bg file, or the natural queue) measured and normalized A/B against a
/// foreign duration, so the persisted norms covered the wrong region and the
/// manager overview drew the segment wrong.
SegmentEditDraft _draft({
  MappingAction action = MappingAction.playMedia,
  String? storageId = 's1',
  String? path = 'b.mp4',
}) =>
    SegmentEditDraft(
      action: action,
      span: const SegmentSpan(
        fgStartMs: 10000,
        fgEndMs: 40000,
        bgOffsetMs: 0,
      ),
      bgStorageId: storageId,
      bgPath: path,
    );

void main() {
  test('the draft naming the loaded file uses the live engine duration',
      () async {
    var lookups = 0;
    final total = await resolveDraftBgTotalMs(
      draft: _draft(),
      engineBgDurMs: 600000,
      engineBgKey: 's1:b.mp4',
      lookup: (_, __) async {
        lookups++;
        return 1;
      },
    );

    expect(total, 600000);
    expect(lookups, 0, reason: 'the engine already holds the file');
  });

  test('a foreign bg file is measured by its OWN duration', () async {
    final total = await resolveDraftBgTotalMs(
      draft: _draft(path: 'other.mp4'),
      engineBgDurMs: 600000,
      engineBgKey: 's1:b.mp4',
      lookup: (storageId, path) async {
        expect(storageId, 's1');
        expect(path, 'other.mp4');
        return 120000;
      },
    );

    expect(total, 120000,
        reason: 'the segment’s own file owns the axis, not the engine’s file');
  });

  test('an unresolvable foreign bg records NO total instead of a foreign one',
      () async {
    final total = await resolveDraftBgTotalMs(
      draft: _draft(path: 'gone.mp4'),
      engineBgDurMs: 600000,
      engineBgKey: 's1:b.mp4',
      lookup: (_, __) async => null,
    );

    expect(total, isNull,
        reason: 'a fabricated axis is worse than an unknown one');
  });

  test('a silence draft has no bg axis at all', () async {
    var lookups = 0;
    final total = await resolveDraftBgTotalMs(
      draft: _draft(action: MappingAction.silence, storageId: null, path: null),
      engineBgDurMs: 600000,
      engineBgKey: 's1:b.mp4',
      lookup: (_, __) async {
        lookups++;
        return 600000;
      },
    );

    expect(total, isNull);
    expect(lookups, 0);
  });

  test('the engine duration is not trusted when the file is not loaded',
      () async {
    // Same key, but the engine reports nothing (still opening): fall back to
    // the DB instead of recording a zero-length axis.
    final total = await resolveDraftBgTotalMs(
      draft: _draft(),
      engineBgDurMs: 0,
      engineBgKey: 's1:b.mp4',
      lookup: (_, __) async => 300000,
    );

    expect(total, 300000);
  });
}
