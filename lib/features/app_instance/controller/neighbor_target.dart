/// 0-based index of the neighbour of [index] inside a queue of [count] items,
/// or null when there is no neighbour.
///
/// [wrap] mirrors `PlaybackProviderRegistry.step`: only `Repeat.all` wraps
/// (Repeat.one repeats the SAME item on natural completion, it is not a
/// step-wrap policy). Keeping the arithmetic pure makes the boundary rules —
/// the one part of the multi-window feature that is easy to get subtly wrong —
/// unit-testable without stores or a database.
int? resolveNeighborIndex({
  required int index,
  required int count,
  required bool forward,
  required bool wrap,
}) {
  if (count <= 0 || index < 0 || index >= count) return null;
  final int target = index + (forward ? 1 : -1);
  if (target >= 0 && target < count) return target;
  if (!wrap) return null;
  return forward ? 0 : count - 1;
}
