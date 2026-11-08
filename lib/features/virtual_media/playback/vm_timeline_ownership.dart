/// Whether Virtual Media owns — or is about to own — the player timeline.
///
/// WHY all three inputs: `isActive` only means "the queue already sits on the
/// segment this session expects". A legitimate switch keeps it FALSE until its
/// own feed lands (see `VirtualMediaController.isActive`), and that window is
/// exactly when an ordinary single-file open is in flight for the new segment.
/// Anything that must not be stacked on a VM segment — notably the 简播
/// (fake-cut) resolver, which replaces the source with an EDL — has to stand
/// down for the whole window, not only after it.
bool vmOwnsTimeline({
  required bool isActive,
  required bool feedInFlight,
  required bool transitioning,
}) =>
    isActive || feedInFlight || transitioning;
