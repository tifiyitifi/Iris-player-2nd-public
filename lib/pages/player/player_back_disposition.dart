/// Back-arrow disposition of the player route (requirement #4).
///
/// The gesture guide is a Stack OVERLAY, not a route: without this branch a
/// bare system back press fell straight through the player's `PopScope`
/// (canPop:false) into saveProgress + app exit — the guide (and its editor
/// round-trip) had no working back path at all. The back arrow now owns the
/// guide first: close the overlay, stay in the player.
///
/// The screen lock sits ABOVE the guide in priority: while the touch guard is
/// armed, back must not leave the player (that is the whole point of the lock —
/// a stray press in a pocket cannot dismiss playback). It releases the guard
/// instead, exactly like the on-screen unlock buttons.
enum PlayerBackDisposition {
  /// Screen lock is armed — back releases it, staying in the player.
  unlockScreen,

  /// Guide (or its settings/editor round-trip) is on stage — back closes it.
  closeGestureGuide,

  /// Nothing overlays the player — back keeps its original exit semantics.
  leavePlayer,
}

PlayerBackDisposition resolvePlayerBackDisposition({
  required bool isShowGestureTips,
  bool isScreenLocked = false,
}) {
  if (isScreenLocked) return PlayerBackDisposition.unlockScreen;
  return isShowGestureTips
      ? PlayerBackDisposition.closeGestureGuide
      : PlayerBackDisposition.leavePlayer;
}
