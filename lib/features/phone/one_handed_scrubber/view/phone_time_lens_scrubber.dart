import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_one_handed_scrubber_math.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_scrubber_time.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/seek_tail_guard.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:provider/provider.dart';

/// Edge "time lens" one-handed scrubber with dv4 session continuity plus
/// musespark hysteresis and isSeeking guard, and isHoldingDown tracking.
class PhoneTimeLensScrubber extends HookWidget {
  const PhoneTimeLensScrubber({
    super.key,
    required this.showControl,
    required this.color,
    required this.isLeftHanded,
  });

  final VoidCallback showControl;
  final Color? color;
  final bool isLeftHanded;

  @override
  Widget build(BuildContext context) {
    // AXTree stability (flutter/flutter#182444): see PhoneSnakeScrubber —
    // per-tick rebuilds with zero assistive value stay out of semantics.
    return ExcludeSemantics(child: _buildTree(context));
  }

  Widget _buildTree(BuildContext context) {
    final bool autoPlay = useAppStore().select(context, (state) => state.autoPlay);
    final progress = context.select<MediaPlayer, ({Duration position, Duration duration})>(
      (MediaPlayer player) => (position: player.position, duration: player.duration),
    );
    final Duration duration = progress.duration > Duration.zero
        ? progress.duration
        : const Duration(milliseconds: 1);
    final preview = useState(_clampDuration(progress.position, duration));
    final window = useState(duration);
    final session = useRef<PhoneTimeLensScrubSession?>(null);
    final lastWindow = useRef<Duration?>(null);
    final MediaPlayer player = context.read<MediaPlayer>();
    // Shared seek step: same source as region-gesture double-tap and the
    // middle-zone vertical swipe, so every skip feels consistent.
    final int stepSec =
        useAppStore().select(context, (state) => state.seekStepSeconds);

    // Single-owner scrub flag (latch-proof): `session` alone is never cleared
    // on this surface, so it cannot gate the preview.
    final bool isScrubbing =
        useScrubDragStore().select(context, (s) => s.isScrubbing);

    useEffect(() {
      if (!isScrubbing) {
        preview.value = _clampDuration(progress.position, duration);
      }
      return null;
    }, <Object>[progress.position, duration, isScrubbing]);

    Future<void> step(int seconds) async {
      showControl();
      if (progress.duration <= Duration.zero) return;
      // Route through the player's OWN step path (`seekRelative`) instead of
      // deciding the tail here: the hooks own the shared `decideStepTail`
      // policy, the mpv-parity tail arm (`MpvSeekTailState`), the EOF collapse
      // and the media-switch gate (`gateStepPress`). A local `finishSeek`
      // bypassed all four, so a second tap inside the queue-advance window
      // resolved against the previous file's duration and finished the entry
      // that had just opened — one episode skipped. The side effect is the
      // same landing the region-gesture double tap produces, which is what
      // this button already documents as its reference.
      if (seconds >= 0) {
        await player.forward(seconds);
      } else {
        await player.backward(-seconds);
      }
    }

    final Color accent = color ?? Theme.of(context).colorScheme.primary;

    return SizedBox(
      width: 132,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          _StepButton(
            icon: Icons.replay_rounded,
            badge: '$stepSec',
            color: accent,
            onPressed: () => step(-stepSec),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: 132,
            height: 200,
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                double normalizedDepth(Offset local) {
                  final double fromOuterEdge = isLeftHanded
                      ? local.dx / constraints.maxWidth
                      : 1 - local.dx / constraints.maxWidth;
                  return fromOuterEdge.clamp(0.0, 1.0).toDouble();
                }

                return GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (DragStartDetails details) {
                    final PhoneTimeLensScrubSession s = PhoneTimeLensScrubSession(duration: duration)
                      ..reset(start: _clampDuration(progress.position, duration));
                    session.value = s;
                    lastWindow.value = null;
                    preview.value = s.target;
                    window.value = s.window;
                    showControl();
                    useScrubDragStore().beginSeek(ScrubOwners.timeLens);
                    // ignore: discarded_futures
                    player.pause();
                  },
                  onPanUpdate: (DragUpdateDetails details) {
                    final s = session.value;
                    if (s == null) return;
                    final Duration nextWindow = PhoneTimeLensScrubberMath.windowForDepth(
                      duration: duration,
                      normalizedDepth: normalizedDepth(details.localPosition),
                    );
                    if (nextWindow != lastWindow.value) {
                      HapticFeedback.selectionClick();
                      lastWindow.value = nextWindow;
                    }
                    final double verticalDelta =
                        (details.localPosition.dy - (constraints.maxHeight / 2)) /
                            (constraints.maxHeight / 2);
                    preview.value = s.update(
                      window: nextWindow,
                      verticalDelta: verticalDelta.clamp(-1.0, 1.0).toDouble(),
                    );
                    window.value = s.window;
                    // No per-tick showControl: onPanStart armed the bar and
                    // the scrub flags hold it for the whole drag.
                  },
                  onPanEnd: (DragEndDetails details) async {
                    await _commit(player, preview.value, autoPlay);
                  },
                  onPanCancel: () async {
                    await _cancel(player, autoPlay);
                  },
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(32),
                      border: Border.all(color: accent.withValues(alpha: 0.6)),
                      color: Colors.black.withValues(alpha: 0.22),
                    ),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        Text(
                          formatPhoneScrubberTime(preview.value),
                          style: TextStyle(fontSize: 18, color: color),
                        ),
                        Text(
                          '± ${formatPhoneScrubberTime(Duration(milliseconds: window.value.inMilliseconds ~/ 2))}',
                          style: TextStyle(fontSize: 12, color: color?.withValues(alpha: 0.75)),
                        ),
                        Icon(Icons.unfold_more_rounded, color: color),
                        Text(
                          getLocalizations(context).scrubber_time_lens,
                          style: TextStyle(fontSize: 12, color: color?.withValues(alpha: 0.75)),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 8),
          _StepButton(
            icon: Icons.fast_forward_rounded,
            badge: '$stepSec',
            color: accent,
            onPressed: () => step(stepSec),
          ),
        ],
      ),
    );
  }
}

class _StepButton extends StatelessWidget {
  const _StepButton({
    required this.icon,
    required this.color,
    required this.onPressed,
    required this.badge,
  });

  final IconData icon;
  final Color color;
  final VoidCallback onPressed;

  /// Live step seconds rendered as a small badge so the icon never lies
  /// about how far the skip moves.
  final String badge;

  @override
  Widget build(BuildContext context) {
    return IconButton.filledTonal(
      onPressed: onPressed,
      icon: Stack(
        clipBehavior: Clip.none,
        alignment: Alignment.center,
        children: <Widget>[
          Icon(icon, color: color),
          Positioned(
            right: -7,
            bottom: -5,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Text(
                badge,
                style: TextStyle(
                  fontSize: 8,
                  height: 1.2,
                  color: color.withValues(alpha: 0.9),
                ),
              ),
            ),
          ),
        ],
      ),
      style: IconButton.styleFrom(
        minimumSize: const Size(48, 48),
        backgroundColor: Colors.black.withValues(alpha: 0.22),
      ),
    );
  }
}

Future<void> _commit(MediaPlayer player, Duration target, bool autoPlay) async {
  // A release at the very end is the explicit "finish this item": it lands ON the
  // end so the file completes and advances. Every other release stays inside the
  // shared tail guard.
  final bool atEnd =
      isSeekReleaseFinish(target.inMilliseconds, player.duration.inMilliseconds);
  await (atEnd ? (player.finishSeek ?? player.seek) : player.seek)(target);
  if (autoPlay) await player.play();
  useScrubDragStore().endSeek(ScrubOwners.timeLens);
}

Future<void> _cancel(MediaPlayer player, bool autoPlay) async {
  if (autoPlay) await player.play();
  useScrubDragStore().endSeek(ScrubOwners.timeLens);
}

Duration _clampDuration(Duration candidate, Duration duration) {
  if (candidate < Duration.zero) return Duration.zero;
  if (candidate > duration) return duration;
  return candidate;
}
