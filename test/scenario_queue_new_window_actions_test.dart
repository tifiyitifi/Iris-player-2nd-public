import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/view/queue/paged_scenario_media_data_source.dart';

/// The Playing Queue row's "previous / next in new window" entries.
///
/// They are ROW-anchored (the user points at an episode, not at what is
/// playing), desktop-only, and greyed at the boundaries unless the scenario
/// repeats all — the same `resolveNeighborIndex` contract the Shift+PageUp/Down
/// keys use.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final row = EffectivePlaybackItem(
    media: MediaNode.file(
      id: 'f:st1:q1/a.mp4',
      storageId: 'st1',
      path: const ['q1', 'a.mp4'],
      name: 'a.mp4',
      mediaType: MediaType.video,
    ),
    scenarioId: 'scn',
    virtualIndex: 0,
    occurrenceId: const PlaybackOccurrenceId(
      storageId: 'st1',
      path: 'q1/a.mp4',
    ),
  );

  List<GenericItemAction<EffectivePlaybackItem>> build({
    required int anchorIndex,
    required int count,
    required bool wrap,
    bool supported = true,
    void Function(bool forward)? onPick,
  }) =>
      buildRowNewWindowActions(
        prevLabel: 'Open previous in new window',
        nextLabel: 'Open next in new window',
        anchorIndex: anchorIndex,
        count: count,
        wrap: wrap,
        supported: supported,
        onSelected: (ctx, item, forward) async => onPick?.call(forward),
      );

  test('unsupported builds (phones, Store/MSIX) offer no entries', () {
    expect(build(anchorIndex: 1, count: 3, wrap: true, supported: false),
        isEmpty);
  });

  test('an empty queue offers no entries', () {
    expect(build(anchorIndex: 0, count: 0, wrap: true), isEmpty);
  });

  test('head of a non-repeating queue greys "previous" only', () {
    final actions = build(anchorIndex: 0, count: 3, wrap: false);
    expect(actions, hasLength(2));
    expect(actions[0].label, 'Open previous in new window');
    expect(actions[0].enabled, isFalse);
    expect(actions[1].label, 'Open next in new window');
    expect(actions[1].enabled, isTrue);
  });

  test('tail of a non-repeating queue greys "next" only', () {
    final actions = build(anchorIndex: 2, count: 3, wrap: false);
    expect(actions[0].enabled, isTrue);
    expect(actions[1].enabled, isFalse);
  });

  test('Repeat.all wraps at both ends', () {
    final head = build(anchorIndex: 0, count: 3, wrap: true);
    final tail = build(anchorIndex: 2, count: 3, wrap: true);
    expect(head.map((a) => a.enabled), everyElement(isTrue));
    expect(tail.map((a) => a.enabled), everyElement(isTrue));
  });

  testWidgets('pressing an entry reports the direction and the row',
      (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold()));
    final picked = <bool>[];
    final actions = build(
      anchorIndex: 1,
      count: 3,
      wrap: false,
      onPick: picked.add,
    );
    final ctx = tester.element(find.byType(Scaffold));

    actions[0].onPressed(ctx, row);
    actions[1].onPressed(ctx, row);

    expect(picked, [false, true]);
  });
}
