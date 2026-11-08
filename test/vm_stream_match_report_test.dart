import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_stream_merge.dart';

VirtualMediaRule recursiveRule(String id, List<String> paths) {
  return VirtualMediaRule(
    id: id,
    name: id,
    matchMode: VmMatchMode.specifiedDirRecursive,
    paths: paths,
  );
}

VirtualSegment vseg(String storage, List<String> path, String parent) {
  return VirtualSegment(
    mediaKey: '$storage:${path.join('/')}',
    storageId: storage,
    path: path,
    name: path.last,
    parentPath: parent,
  );
}

void main() {
  test('no-match report carries per-rule counts and first-item hint', () {
    final rules = [recursiveRule('r1', ['vault/003/ani'])];
    final stream = [
      vseg('st1', ['E:', 'other', 'dir', 'a.mp4'], 'E:/other/dir'),
    ];
    final report = vmNoMatchReport(rules: rules, streamOrdered: stream);
    expect(report, contains('rules=1'));
    expect(report, contains('r1'));
    expect(report, contains('0'));
    expect(report, contains('firstParent=E:/other/dir'));
  });

  test('no-match report counts hits when a rule covers the stream', () {
    final rules = [recursiveRule('r1', ['vault/003/ani'])];
    final stream = [
      vseg('st1', ['E:', 'vault', '003', 'ani', 'a.mp4'],
          'E:/vault/003/ani'),
    ];
    final report = vmNoMatchReport(rules: rules, streamOrdered: stream);
    expect(report, contains('r1'));
    expect(report, contains('1'));
  });

  test('no-match report handles empty stream', () {
    final rules = [recursiveRule('r1', ['vault/003/ani'])];
    final report = vmNoMatchReport(rules: rules, streamOrdered: const []);
    expect(report, contains('empty stream'));
  });
}
