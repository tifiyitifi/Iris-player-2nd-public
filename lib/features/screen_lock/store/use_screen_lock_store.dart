import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:freezed_annotation/freezed_annotation.dart';

part 'use_screen_lock_store.freezed.dart';

/// Ephemeral player screen-lock state — NEVER persisted.
///
/// The lock is a per-session touch guard: it exists so a stray tap or swipe
/// during playback cannot seek, change volume/brightness or dismiss the
/// controls. Because it is a transient "I am watching, do not disturb me"
/// intent, it must not survive an app restart (or be resurrected from a stale
/// snapshot), so it lives outside `AppState` on its own [`ScreenLockStore`].
@freezed
abstract class ScreenLockState with _$ScreenLockState {
  const factory ScreenLockState({
    /// True while the touch guard is armed: the gesture layer and the control
    /// bar are inert and only the edge unlock buttons stay live.
    @Default(false) bool locked,

    /// True while the lock chrome (title + edge unlock buttons) is shown.
    /// Ephemeral like [locked]: armed on lock, toggled by taps on the guard,
    /// auto-hidden by the overlay timer.
    @Default(false) bool uiVisible,
  }) = _ScreenLockState;
}

/// Owns the player screen-lock flag (see [ScreenLockState]).
///
/// The state deliberately stays minimal: every consumer only needs "is it
/// locked" plus "is the lock chrome shown". Both are ephemeral session flags,
/// never persisted.
class ScreenLockStore extends Store<ScreenLockState> {
  ScreenLockStore() : super(const ScreenLockState());

  /// Arms the touch guard and shows the lock chrome (no-op when armed).
  void lock() {
    if (state.locked) return;
    set(state.copyWith(locked: true, uiVisible: true));
  }

  /// Releases the touch guard and drops the chrome (no-op when not armed).
  void unlock() {
    if (!state.locked) return;
    set(state.copyWith(locked: false, uiVisible: false));
  }

  /// Flips the guard (used by the on-bar entry button). Arming shows the
  /// chrome; releasing drops it.
  void toggle() {
    final bool locked = !state.locked;
    set(state.copyWith(locked: locked, uiVisible: locked));
  }

  /// Shows the lock chrome (no-op when the guard is not armed).
  void showLockUi() {
    if (!state.locked || state.uiVisible) return;
    set(state.copyWith(uiVisible: true));
  }

  /// Hides the lock chrome, keeping the guard armed (no-op when not armed).
  void hideLockUi() {
    if (!state.locked || !state.uiVisible) return;
    set(state.copyWith(uiVisible: false));
  }

  /// Flips only the chrome visibility, keeping the guard armed. Taps on the
  /// guard surface use this; the guard itself is untouched.
  void toggleLockUi() {
    if (!state.locked) return;
    set(state.copyWith(uiVisible: !state.uiVisible));
  }

  /// Defensive teardown used on player-route teardown: a lock must never
  /// outlive the session it was armed in, or the next video would open
  /// unusable with the guard silently still on.
  void reset() {
    if (!state.locked) return;
    set(const ScreenLockState());
  }
}

ScreenLockStore useScreenLockStore() => create(() => ScreenLockStore());
