/// One playable range of the fake-cut plan, on the SOURCE timeline.
///
/// Plain immutable class on purpose (same choice as
/// `virtual_media/model/domain/vm_item.dart`): this is a pure computation value
/// with no JSON and no `copyWith` use, so Freezed's generated surface would be
/// noise. The persisted form is the `.llc`; nothing else stores a plan.
class FakeCutSegment {
  const FakeCutSegment({
    required this.index,
    required this.startMs,
    required this.endMs,
    this.name = '',
  });

  /// Position in the exported (LosslessCut array) order. NOT a sort key:
  /// repeated / out-of-order / overlapping source ranges are legal, and [index]
  /// is what distinguishes them.
  final int index;

  final int startMs;
  final int endMs;
  final String name;

  int get durationMs => endMs - startMs;

  @override
  String toString() =>
      'FakeCutSegment(#$index $startMs..$endMs${name.isEmpty ? '' : ' "$name"'})';
}
