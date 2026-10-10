import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';

VirtualSegment _seg(String name, int durMs) => VirtualSegment(
      mediaKey: 's:$name',
      storageId: 's',
      path: ['d', name],
      name: name,
      parentPath: 'd',
      durationMs: durMs,
    );

/// Duration-capped rule: 5 x 30min chunks into `{1,2,3,4}` then `{5}` at a
/// 120min cap. `skipSingleSegment: false` keeps both chunks visible.
VirtualMediaRule _rule(String id) => VirtualMediaRule(
      id: id,
      name: 'rule $id',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['d'],
      maxDurationMinutes: 120,
      maxItemCount: 32,
      useDurationCap: true,
      useCountCap: true,
      useExcludeOverlong: false,
      skipSingleSegment: false,
    );

VirtualSegment _f(int n) => _seg('f$n.mp4', 30 * 60 * 1000);

/// The delete-time boundary freeze ("只影响被删文件所属的 VM").
void main() {
  final pin = VmMembershipPin.instance;

  setUp(pin.clear);
  tearDown(pin.clear);

  test('baseline: removing middle members WITHOUT a pin re-chunks and merges '
      'across the old boundary (the hazard this feature fixes)', () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];

    final before = resolveVirtualMedia(rules: [rule], library: full);
    expect(before.map((g) => g.segments.map((s) => s.name).toList()).toList(),
        [
          ['f1.mp4', 'f2.mp4', 'f3.mp4', 'f4.mp4'],
          ['f5.mp4'],
        ]);

    // Delete f2,f3,f4 from the library (DB rows gone), no pin.
    final after = resolveVirtualMedia(
      rules: [rule],
      library: [_f(1), _f(5)],
    );
    // Re-chunked: f1 and f5 collapse into ONE chunk across the old boundary.
    expect(after.length, 1);
    expect(after.single.segments.map((s) => s.name), ['f1.mp4', 'f5.mp4']);
  });

  test('pin freezes boundaries: chunk1 shrinks to {f1}, chunk2 stays {f5}',
      () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];

    // Seed the pin from the pre-delete resolve.
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    for (final n in [2, 3, 4]) {
      pin.removeMember(rule.id, 's:f$n.mp4');
    }

    final after = resolveVirtualMedia(
      rules: [rule],
      library: [_f(1), _f(5)],
    );

    // Two chunks, boundary preserved — f1 NOT pulled into f5's chunk.
    expect(after.length, 2);
    expect(after[0].segments.map((s) => s.name), ['f1.mp4']);
    expect(after[1].segments.map((s) => s.name), ['f5.mp4']);
    // Identity fields (scopeKey / displayIndex) survive the shrink.
    expect(after[0].scopeKey, before[0].scopeKey);
    expect(after[1].scopeKey, before[1].scopeKey);
    expect(after[0].displayIndex, before[0].displayIndex);
  });

  test('pinned members carry fresh library metadata (not the snapshot)', () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    for (final n in [2, 3, 4]) {
      pin.removeMember(rule.id, 's:f$n.mp4');
    }

    // The stored node for f1 was re-probed: the pinned item must show the new
    // duration (a fresh library entry), not the 30min snapshot.
    final after = resolveVirtualMedia(
      rules: [rule],
      library: [_seg('f1.mp4', 42 * 60 * 1000), _f(5)],
    );
    final f1 = after[0].segments.single;
    expect(f1.name, 'f1.mp4');
    expect(f1.durationMs, 42 * 60 * 1000);
  });

  test('pin also applies through resolveRuleGroups (membership variant)', () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    pin.removeMember(rule.id, 's:f2.mp4');

    final after = resolveRuleGroups(
      rules: [rule],
      library: [_f(1), _f(2), _f(5)], // f2 still visible in a stale library
    );
    // f2 filtered by removedKeys even though the library still carries it.
    expect(after.length, 2);
    expect(after[0].segments.map((s) => s.name), ['f1.mp4']);
    expect(after[1].segments.map((s) => s.name), ['f5.mp4']);
  });

  test('deleting an entire chunk drops it; other chunks are untouched', () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    for (final n in [1, 2, 3, 4]) {
      pin.removeMember(rule.id, 's:f$n.mp4');
    }
    final after =
        resolveVirtualMedia(rules: [rule], library: [_f(5)]);
    expect(after.length, 1);
    expect(after.single.segments.map((s) => s.name), ['f5.mp4']);
  });

  test('clear() lifts the freeze and restores normal re-chunking', () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    pin.removeMember(rule.id, 's:f2.mp4');
    expect(pin.isActive, isTrue);

    pin.clear();
    expect(pin.isActive, isFalse);

    final after = resolveVirtualMedia(rules: [rule], library: [_f(1), _f(5)]);
    expect(after.length, 1); // re-chunked again
    expect(after.single.segments.map((s) => s.name), ['f1.mp4', 'f5.mp4']);
  });

  test('seedRule is idempotent (first freeze wins)', () {
    final rule = _rule('r');
    pin.seedRule(rule.id, const []);
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    expect(pin.chunksFor(rule.id), isNotNull);
    // A second seed is ignored.
    pin.seedRule(rule.id, const []);
    expect(pin.chunksFor(rule.id)!.length, 2);
  });

  test('untouched rules keep deriving normally while another rule is pinned',
      () {
    final pinnedRule = _rule('r1');
    final otherRule = VirtualMediaRule(
      id: 'r2',
      name: 'r2',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['d'],
      maxDurationMinutes: 120,
      useExcludeOverlong: false,
      skipSingleSegment: false,
    );
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [pinnedRule], library: full);
    pin.seedRule(
      pinnedRule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: pinnedRule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );

    final both = resolveVirtualMedia(
      rules: [pinnedRule, otherRule],
      library: [_f(1), _f(2), _f(3)],
    );
    final r1 = both.where((g) => g.ruleId == 'r1').toList();
    final r2 = both.where((g) => g.ruleId == 'r2').toList();
    // Pinned r1 keeps its frozen chunk (now {f1,f2,f3}).
    expect(r1.single.segments.map((s) => s.name), ['f1.mp4', 'f2.mp4', 'f3.mp4']);
    // r2 is not pinned -> normal pipeline (one chunk of 3 at 120min cap).
    expect(r2.single.segments.length, 3);
    expect(r2.single.scopeKey, isNot(r1.single.scopeKey));
  });

  test('rule change (VirtualMediaService.invalidate) lifts the freeze', () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    pin.removeMember(rule.id, 's:f2.mp4');
    expect(pin.isActive, isTrue);

    // Rule edit → notifyRulesChanged → invalidate(); the freeze must drop.
    VirtualMediaService.instance.invalidate();
    expect(pin.isActive, isFalse);
  });

  test('applyPin:false ignores the freeze (full-library management preview)',
      () {
    final rule = _rule('r');
    final full = [for (var i = 1; i <= 5; i++) _f(i)];
    final before = resolveVirtualMedia(rules: [rule], library: full);
    pin.seedRule(
      rule.id,
      [
        for (final g in before)
          PinnedVmChunk(
            ruleId: rule.id,
            scopeKey: g.scopeKey,
            rootPath: g.rootPath,
            displayIndex: g.displayIndex,
            originalSegments: g.segments,
          ),
      ],
    );
    for (final n in [2, 3, 4]) {
      pin.removeMember(rule.id, 's:f$n.mp4');
    }

    // With the pin applied the frozen chunk shrinks to {f1} (f2..f4 filtered).
    final pinned = resolveVirtualMedia(rules: [rule], library: full);
    expect(pinned.first.segments.map((s) => s.name), ['f1.mp4']);

    // The preview reads the whole library and opts out: it re-derives the full
    // pre-delete chunks instead of projecting one scenario's frozen boundaries.
    final preview =
        resolveVirtualMedia(rules: [rule], library: full, applyPin: false);
    expect(preview.length, 2);
    expect(preview.first.segments.map((s) => s.name),
        ['f1.mp4', 'f2.mp4', 'f3.mp4', 'f4.mp4']);
    expect(preview.last.segments.map((s) => s.name), ['f5.mp4']);
  });
}
