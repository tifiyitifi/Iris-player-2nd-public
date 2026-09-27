import 'dart:async';

import 'package:flutter/material.dart';

/// A progress surface that only materialises when the work behind it is slow.
///
/// Three responsibilities, all load-bearing:
///
///  * **Delay gate.** [arm] merely starts a timer. Work that settles inside
///    [delay] never mounts a widget at all — that, and not a show-then-hide
///    trick, is what keeps the fast path free of a flashing window.
///  * **Content slot.** [update] rebuilds the visible content, so the caller
///    owns the progress state and simply reads it from the builder it passed
///    to [arm] on every rebuild.
///  * **In-place failure.** [fail] swaps the content on the SAME route instead
///    of popping and pushing a second dialog, so a failure can never appear as
///    a close/open flicker.
///
/// The surface is dismissible (barrier tap / the caller's own cancel action)
/// unless [barrierDismissible] is false. Dismissing it only closes the surface
/// — [cancelled] reports it so the caller can also suppress the navigation it
/// was going to perform. It does NOT abort the work: pair it with a
/// cancellation check in the work loop (see
/// `WebDavConnectCoordinator.resolveDetailed`'s `stillWanted`).
///
/// Exactly one of [succeed] / [fail] / [cancel] is terminal, and [dispose]
/// must follow it.
class DelayedProgressGate {
  DelayedProgressGate({
    this.delay = const Duration(milliseconds: 400),
    this.barrierDismissible = true,
  });

  /// How long the work may take before the surface appears.
  final Duration delay;

  /// Whether a barrier tap closes the surface.
  ///
  /// Work a user would be annoyed to lose to a mis-tap — a package transfer
  /// worth ~186 MB — turns this off and offers an explicit cancel action
  /// instead, so backing out is always something they chose.
  final bool barrierDismissible;

  Timer? _timer;
  NavigatorState? _navigator;
  WidgetBuilder? _progressBuilder;
  WidgetBuilder? _failureBuilder;

  /// Bumped by [update]; the dialog listens so the caller's builder re-reads
  /// whatever progress state it captured.
  final ValueNotifier<int> _revision = ValueNotifier<int>(0);

  Future<dynamic>? _route;
  bool _armed = false;
  bool _visible = false;
  bool _failed = false;
  bool _finished = false;
  bool _cancelled = false;
  bool _disposed = false;

  /// Set the moment the user dismisses the surface. A route's `popped` future
  /// completes at pop time, so [_visible] is only cleared a microtask later —
  /// far too late for a terminal call made in the same turn, which would read
  /// the surface as still up and pop a second time, taking the caller's own
  /// route with it.
  bool _dismissed = false;

  /// True while the surface is on screen.
  bool get isVisible => _visible;

  /// True once the user dismissed the progress surface. A cancelled run must
  /// not navigate and must not report a failure.
  bool get cancelled => _cancelled;

  /// Starts the delay. [navigator] must be the ROOT navigator, captured before
  /// the caller's first await: the surface has to sit above the popup route
  /// that hosts the caller.
  ///
  /// [builder] renders the progress content and is re-invoked on every
  /// [update]; keep the progress state it reads in the caller's scope.
  void arm({
    required NavigatorState navigator,
    required WidgetBuilder builder,
  }) {
    assert(!_armed, 'DelayedProgressGate.arm() called twice');
    _armed = true;
    _navigator = navigator;
    _progressBuilder = builder;
    _timer = Timer(delay, _materialise);
  }

  /// Re-runs the progress builder. No-op while the surface is not up, so the
  /// caller never has to know whether the delay has elapsed yet.
  void update() {
    if (!_visible) return;
    _revision.value++;
  }

  /// The work succeeded. Cancels the pending show, so a run faster than [delay]
  /// never mounts anything; dismisses the surface otherwise and waits for the
  /// pop so the caller can navigate into a settled UI.
  Future<void> succeed() async {
    if (_finished) return;
    _finished = true;
    await _closeSurface();
  }

  /// The caller gave up: nobody is waiting for an answer any more, so nothing is
  /// reported — no success, no failure, no new window.
  ///
  /// The only terminal that makes [dispose] legal on a surface that is still
  /// up. [dispose] merely releases, so a caller that walked away through it
  /// leaves a spinner standing on the root navigator that nothing else pops.
  ///
  /// A surface the user already dismissed is left alone, exactly like
  /// [succeed]: it is on its way out already, and popping again would take the
  /// caller's own route with it.
  ///
  /// Deliberately does not set [cancelled] — that stays reserved for the user
  /// dismissing the surface, which is what a stillWanted check reports on.
  Future<void> cancel() async {
    if (_finished) return;
    _finished = true;
    await _closeSurface();
  }

  /// Takes the surface down, cancelling the pending show if it never made it.
  ///
  /// Shared by the two "no result to report" terminals: the window goes first
  /// and the pop is awaited, so the caller acts on a settled UI. A surface the
  /// user dismissed is skipped — [_dismissed] is the only thing distinguishing
  /// that from this gate's own pop. A navigator that is gone took the surface
  /// with it, so there is nothing left to close.
  Future<void> _closeSurface() async {
    _timer?.cancel();
    _timer = null;
    final route = _route;
    if (!_visible || _dismissed || route == null) return;
    final navigator = _navigator;
    if (navigator == null || !navigator.mounted) return;
    navigator.pop();
    await route;
  }

  /// The work failed. Reuses the visible surface when there is one (no second
  /// window, no flicker) and opens [failureBuilder] standalone otherwise.
  ///
  /// Completes with the route's result, or null when the user dismissed the
  /// failure surface without choosing — the caller applies its own default,
  /// exactly like the standalone dialog does.
  Future<T?> fail<T>({required WidgetBuilder failureBuilder}) async {
    if (_finished) return null;
    _finished = true;
    _timer?.cancel();
    _timer = null;

    final navigator = _navigator;
    if (navigator == null || !navigator.mounted) return null;

    _failureBuilder = failureBuilder;
    _failed = true;
    // A dismissed surface is not resurrected: the failure gets its own window
    // rather than a content swap into a route that is already animating away.
    if (_visible && !_dismissed) {
      _revision.value++;
      return (await _route) as T?;
    }

    _visible = true;
    return (await _push()) as T?;
  }

  void _materialise() {
    _timer = null;
    if (_finished) return;
    final navigator = _navigator;
    if (navigator == null || !navigator.mounted) return;
    _visible = true;
    _route = _push();
  }

  Future<dynamic> _push() {
    assert(_navigator != null && _navigator!.mounted);
    final navigator = _navigator!;
    return showDialog<dynamic>(
      context: navigator.context,
      barrierDismissible: barrierDismissible,
      builder: (ctx) => PopScope(
        // Fires at pop time, synchronously — the only moment a user dismissal
        // can be told apart from this gate's own pop, since a terminal call
        // marks itself with [_finished] before it pops. Inferring it from the
        // route's future instead left [_visible] true for the rest of the turn.
        onPopInvokedWithResult: (didPop, _) {
          if (didPop && !_finished) {
            _cancelled = true;
            _dismissed = true;
          }
        },
        child: ValueListenableBuilder<int>(
          valueListenable: _revision,
          builder: (_, __, ___) {
            final builder = _failed ? _failureBuilder : _progressBuilder;
            return builder?.call(ctx) ?? const SizedBox.shrink();
          },
        ),
      ),
    ).then((value) {
      _visible = false;
      return value;
    });
  }

  /// Releases the gate. Idempotent, so a cleanup path may run after the normal
  /// terminal call. A live surface at this point means the caller forgot its
  /// terminal call — the assert names that, and the body still cleans up without
  /// closing anything, which is why [cancel] exists.
  void dispose() {
    assert(_finished || _disposed,
        'DelayedProgressGate.dispose() before a terminal call');
    if (_disposed) return;
    _disposed = true;
    _timer?.cancel();
    _timer = null;
    _progressBuilder = null;
    _failureBuilder = null;
    _revision.dispose();
  }
}
