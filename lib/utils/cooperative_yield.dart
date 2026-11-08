/// Time-budgeted cooperative yielding.
///
/// The recursive scan used to `await Future.delayed(Duration.zero)` between
/// every step — once per directory and again per child — plus once per 100
/// listed entries. Each call is a real timer event on the UI isolate, and a
/// 34k-directory scan issues ~100k of them: measured on a 2019 phone, the
/// "unaccounted" time in the profile was 25.8 s of 125 s, almost all of it
/// timer round-trips.
///
/// The point of those yields is only to let the raster thread composite a
/// frame, so the correct budget is the frame interval, not the step count.
/// Yielding once per 16 ms keeps the UI at ~60 fps while removing the other
/// ~99.9% of the timer events. Awaits on real IO still yield on their own;
/// this gate only controls the deliberate ones.
class CooperativeYield {
  CooperativeYield({
    this.budget = const Duration(milliseconds: 16),
    int Function()? elapsedMs,
  })  : _elapsedMs = elapsedMs ?? _defaultElapsedMs,
        _lastYieldMs = (elapsedMs ?? _defaultElapsedMs)();

  static final Stopwatch _clock = Stopwatch()..start();
  static int _defaultElapsedMs() => _clock.elapsedMilliseconds;

  /// Minimum wall-clock gap between two deliberate yields.
  final Duration budget;

  final int Function() _elapsedMs;
  int _lastYieldMs;

  /// True when this call should be the one that yields.
  ///
  /// Records the timestamp, so a burst of calls in the same tick yields once.
  bool takeYieldSlot() {
    final now = _elapsedMs();
    if (now - _lastYieldMs < budget.inMilliseconds) return false;
    _lastYieldMs = now;
    return true;
  }

  /// Yields to the event loop when the budget has elapsed, otherwise returns
  /// without touching the scheduler.
  Future<void> maybeYield() async {
    if (takeYieldSlot()) await Future<void>.delayed(Duration.zero);
  }

  /// Treats the current instant as "just yielded" (e.g. after a long operation
  /// that already gave the engine a chance to paint).
  void reset() {
    _lastYieldMs = _elapsedMs();
  }
}
