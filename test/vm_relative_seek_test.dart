import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/interaction/controller/virtual_seek_handler.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';

VirtualSegment _seg(String name, int? durMs) => VirtualSegment(
      mediaKey: 's:$name',
      storageId: 's',
      path: ['d', name],
      name: name,
      parentPath: 'd',
      durationMs: durMs,
    );

VirtualMediaItem _threeBy100() => VirtualMediaItem(
      ruleId: 'r',
      scopeKey: 'r|d|#1',
      rootPath: 'd',
      displayIndex: 1,
      displayName: 'd',
      segments: [_seg('a.mp4', 100000), _seg('b.mp4', 100000), _seg('c.mp4', 100000)],
    );

void main() {
  const handler = VirtualSeekHandler();

  group('virtual base (local -> virtual, the backward/forward regression)', () {
    test('seg1 local 10s maps to virtual 110s', () {
      final item = _threeBy100();
      expect(handler.virtualBaseMs(item, segmentIndex: 1, localMs: 10000), 110000);
    });

    test('forward 10s from seg1 local 10s lands seg1 local 20s (not seg0)', () {
      final item = _threeBy100();
      final r = handler.resolveRelativeSeek(
        item,
        segmentIndex: 1,
        localMs: 10000,
        deltaMs: 10000,
      )!;
      expect(r.virtualMs, 120000);
      expect(r.segIdx, 1);
      expect(r.localMs, 20000);
    });

    test('backward 15s from seg1 local 10s lands seg0 local 95s', () {
      final item = _threeBy100();
      final r = handler.resolveRelativeSeek(
        item,
        segmentIndex: 1,
        localMs: 10000,
        deltaMs: -15000,
      )!;
      expect(r.virtualMs, 95000);
      expect(r.segIdx, 0);
      expect(r.localMs, 95000);
    });

    test('forward across boundary lands next segment with offset carried', () {
      final item = _threeBy100();
      final r = handler.resolveRelativeSeek(
        item,
        segmentIndex: 0,
        localMs: 95000,
        deltaMs: 10000,
      )!;
      expect(r.virtualMs, 105000);
      expect(r.segIdx, 1);
      expect(r.localMs, 5000);
    });

    test('exact boundary prefers later segment', () {
      final item = _threeBy100();
      final r = handler.resolveRelativeSeek(
        item,
        segmentIndex: 0,
        localMs: 95000,
        deltaMs: 5000,
      )!;
      expect(r.virtualMs, 100000);
      expect(r.segIdx, 1);
      expect(r.localMs, 0);
    });

    test('clamps past tail and head', () {
      final item = _threeBy100();
      final tail = handler.resolveRelativeSeek(item, segmentIndex: 2, localMs: 99000, deltaMs: 60000)!;
      expect(tail.virtualMs, 299999);
      expect(tail.segIdx, 2);
      final head = handler.resolveRelativeSeek(item, segmentIndex: 0, localMs: 1000, deltaMs: -60000)!;
      expect(head.virtualMs, 0);
      expect(head.segIdx, 0);
      expect(head.localMs, 0);
    });

    test('sub-second precision survives (no inSeconds truncation)', () {
      final item = _threeBy100();
      final r = handler.resolveRelativeSeek(
        item,
        segmentIndex: 1,
        localMs: 10500,
        deltaMs: 5000,
      )!;
      expect(r.virtualMs, 115500);
      expect(r.localMs, 15500);
    });

    test('empty/zero-total item cannot resolve a relative move (null)', () {
      final item = VirtualMediaItem(
        ruleId: 'r',
        scopeKey: 'k',
        rootPath: 'd',
        displayIndex: 1,
        displayName: 'd',
        segments: [_seg('u.mp4', null)],
      );
      // NOT (0,0,0): the old degenerate target was persisted as position 0 and
      // wiped the file's saved progress. Null forces the caller to hold.
      expect(
        handler.resolveRelativeSeek(
            item, segmentIndex: 0, localMs: 5000, deltaMs: 5000),
        isNull,
      );
      expect(handler.segmentDurationKnown(item, 0), isFalse);
    });

    test('an unknown-duration target segment cannot resolve either', () {
      final item = VirtualMediaItem(
        ruleId: 'r',
        scopeKey: 'k',
        rootPath: 'd',
        displayIndex: 1,
        displayName: 'd',
        // Segment 1 was never probed: its prefix contributes 0, so everything
        // at/after it on the virtual axis is unresolvable.
        segments: [_seg('a.mp4', 100000), _seg('b.mp4', null)],
      );
      expect(handler.segmentDurationKnown(item, 0), isTrue);
      expect(handler.segmentDurationKnown(item, 1), isFalse);
      expect(
        handler.resolveRelativeSeek(
            item, segmentIndex: 1, localMs: 5000, deltaMs: 5000),
        isNull,
      );
    });
  });

  group('virtual buffer (local -> virtual)', () {
    test('seg1 buffered 50s shows at 150s on the virtual bar', () {
      final item = _threeBy100();
      expect(handler.virtualBufferMs(item, segmentIndex: 1, rawBufferMs: 50000), 150000);
    });

    test('buffer clamps to total', () {
      final item = _threeBy100();
      expect(handler.virtualBufferMs(item, segmentIndex: 2, rawBufferMs: 999999), 300000);
    });
  });
}
