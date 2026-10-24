import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/services/bg_seek_window.dart';
import 'package:iris/features/background_playback/services/bg_vm_visibility.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/virtual_media/interaction/controller/virtual_seek_handler.dart';
import 'package:iris/features/virtual_media/interaction/ui/vm_drag_preview_overlay.dart';
import 'package:iris/features/virtual_media/interaction/ui/vm_dual_time.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/view/vm_scrubber_marks.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/format_duration_to_minutes.dart';
import 'package:iris/utils/live_seek_throttle.dart';
import 'package:iris/utils/seek_tail_guard.dart';
import 'package:provider/provider.dart';

class ControlBarSlider extends HookWidget {
  const ControlBarSlider({
    super.key,
    this.showControl,
    this.disabled = false,
    this.color,
    this.showTimeLabels = true,
  });

  final void Function()? showControl;
  final bool disabled;
  final Color? color;

  /// Whether the inline position/duration texts flank the track (classic
  /// one-line bar). The stacked desktop layout renders its own time row
  /// above and hides these so the axis claims the full width.
  final bool showTimeLabels;

  @override
  Widget build(BuildContext context) {
    // Visibility gate — invisible (off-screen via AnimatedPositioned) must not
    // subscribe to per-tick position. The control bar hides by translating
    // off-screen; without this gate the slider would rebuild every tick even
    // while hidden (waste + AXTree exposure). Disabled (minimal overlay) is
    // gated by its parent MinimalProgressOverlay, so it always subscribes.
    final isShowControl =
        usePlayerUiStore().select(context, (state) => state.isShowControl);
    if (!disabled && !isShowControl) {
      return const SizedBox.shrink();
    }

    final autoPlay = useAppStore().select(context, (state) => state.autoPlay);

    // Virtual-media session marks (segment boundaries + probe-failed red
    // spans). Item identity only changes on session events, so this never
    // adds per-tick subscriptions.
    //
    // While the controls target 副音 the scrubber drives a REAL single file
    // (bg is never virtual-merged), so the foreground's VM session is
    // suppressed here — its boundaries/blocks must not decorate the bg track.
    //
    // `disabled` (the bottom minimal overlay) is a passive foreground readout
    // with no control ability, so it must ignore the control target entirely:
    // the bg seek window (floor/ceiling) lives on the bg file's local axis and
    // would be clamped against the FOREGROUND duration here, breaking the
    // slider's range assertions (red-text bug). Treat it as foreground always.
    final vmItemRaw = useVmPlaybackStore().select(context, (s) => s.item);
    final bgRaw = useBackgroundPlaybackStore()
        .select(context, (s) => s.bgOwnsControls);
    final bgIsControl = !disabled && bgRaw;
    final vmItem = vmItemForControlTarget(vmItemRaw, bgIsControl: bgIsControl);
    final vmMarks = useMemoized(() => computeVmScrubberMarks(vmItem), [vmItem]);
    // Vertical boundary ticks, user-tinted via `virtualmedia.markTickColor`
    // (opaque white default) with per-side extent from `vmMarkTickExtent`
    // (7px default, 0 = flush with the axis).
    final vmTickArgb = useAppStore().select(context, (s) => s.vmMarkTickColor);
    final vmTickExtent =
        useAppStore().select(context, (s) => s.vmMarkTickExtent);

    final progress = context.select<
        MediaPlayer,
        ({
          Duration position,
          Duration duration,
          Duration buffer,
        })>(
      (player) => (
        position: player.position,
        duration: player.duration,
        buffer: player.buffer,
      ),
    );

    final player = context.read<MediaPlayer>();
    final play = player.play;
    final pause = player.pause;
    final seek = player.seek;
    // Release-at-the-end commits through the explicit "finish this item" seek so
    // it may land ON `duration` and advance; every live tick stays inside the
    // tail guard.
    final finishSeek = player.finishSeek ?? player.seek;

    // Live drag seeks are throttled (same 120ms contract as the circle slider /
    // ring dial) and the FINAL position is committed explicitly on release:
    // an unthrottled per-pointer-event seek floods the backend and is what made
    // dragging feel laggy.
    final seekThrottle = useMemoized(LiveSeekThrottle.new, const <Object?>[]);
    final lastDragTargetMs = useRef<int?>(null);

    // Cross-segment drag preview (spec §6, preview strategy only): the hooks
    // hold the picture during the drag, this overlay shows where the release
    // will land. Local drag refs — the actual commit is centralized in the
    // player hooks' drag-release effect.
    final vmStrategy =
        useAppStore().select(context, (s) => s.vmCrossSegmentDragStrategy);
    final dragStartMs = useRef<double?>(null);
    final dragTickMs = useState<double?>(null);
    const vmSeekHandler = VirtualSeekHandler();
    final vmActive = vmItem != null && VirtualMediaController.instance.isActive;
    final showVmPreview = vmActive &&
        vmStrategy == VmCrossSegmentDragStrategy.previewOnRelease &&
        dragStartMs.value != null &&
        dragTickMs.value != null &&
        vmSeekHandler.isCrossSegment(
            dragStartMs.value!.toInt(), dragTickMs.value!.toInt());
    final vmPreview =
        showVmPreview ? vmSeekHandler.preview(dragTickMs.value!.toInt()) : null;

    final double max = progress.duration.inMilliseconds.toDouble();
    // 副音 control target + published window (仅当前 + 高同步): resolve through
    // the SAME helper as the circle slider / ring dial so the axis and the
    // buffer agree, and an empty/inverted window can never invert the Slider's
    // bounds. The adapter clamps the commit too; this caps the visible track so
    // both limits read as limit stops.
    final bgBounds = bgIsControl
        ? useBackgroundPlaybackStore().select(
            context, (s) => (s.bgSeekFloorLocalMs, s.bgSeekCeilingLocalMs))
        : null;
    final BgSeekWindow? bgWindow = bgBounds == null
        ? null
        : resolveBgSeekWindow(
            duration: progress.duration,
            floorMs: bgBounds.$1,
            ceilingMs: bgBounds.$2,
          );
    double sliderMin = bgWindow?.loMs.toDouble() ?? 0.0;
    double sliderMax = (bgWindow != null && bgWindow.durationMs > 0)
        ? bgWindow.hiMs.toDouble()
        : (max > 0 ? max : 1.0);
    // Slider requires min < max; keep a hair of span for an empty window.
    if (sliderMax <= sliderMin) sliderMax = sliderMin + 1.0;
    final double positionValue =
        progress.position.inMilliseconds.toDouble().clamp(sliderMin, sliderMax);
    // The 副音 view reports buffer == duration (no secondary buffer tracking)
    // and the window ceiling can sit BELOW the file duration, so the buffer
    // MUST be clamped to the slider's own max — otherwise Slider asserts
    // `secondaryTrackValue` is out of [min, max] (the red-screen crash).
    final double bufferValue =
        progress.buffer.inMilliseconds.toDouble().clamp(sliderMin, sliderMax);

    // B-scheme dual time (virtual-merged only): left column shows
    // totalPos/subPos, right column totalDur/subDur. The axis and all seeks
    // stay on the merged total; this only derives the sub companion rows.
    // `progress.position` is already the frozen virtual target while a segment
    // switch is in flight, so locating from it never flashes a stale file.
    // Labels use the sync-aligned display values; the axes keep raw ms.
    final vmSync = useAppStore().select(context, (s) => s.vmDualTimeSync);
    final vmDual = VmDualTime.resolve(vmItem, progress.position.inMilliseconds,
        sync: vmSync);
    final Duration vmTotalPos = Duration(milliseconds: vmDual.displayVirtualMs);
    final Duration? vmSubPos =
        vmDual.showSub ? Duration(milliseconds: vmDual.displayLocalMs) : null;
    final Duration? vmSubDur = (vmDual.showSub && vmDual.segDurMs != null)
        ? Duration(milliseconds: vmDual.segDurMs!)
        : null;

    // Windows AXTree-crash mitigation (#103808 family): the slider's value
    // and its flanking time texts churn every tick while carrying no extra
    // a11y value beyond the control bar's buttons (seek via keyboard
    // shortcuts remains). Exclude the ticking subtree from the bridge.
    final sliderRow = Container(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 0),
      child: Row(
        children: [
          Visibility(
            visible: !disabled && showTimeLabels,
            child: VmDualTimeColumn(
              total: vmTotalPos,
              sub: vmSubPos,
              format: formatDurationToMinutes,
              totalStyle: TextStyle(color: color, height: 2),
            ),
          ),
          Expanded(
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                if (vmPreview != null && vmItem != null)
                  Positioned(
                    top: -30,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: VmDragPreviewOverlay(
                        segIndex: vmPreview.segIdx,
                        segCount: vmItem.segments.length,
                        segName: vmPreview.name,
                        localPos: Duration(milliseconds: vmPreview.localMs),
                        segDur: Duration(milliseconds: vmPreview.segDurMs),
                        virtualPos: Duration(milliseconds: vmPreview.virtualMs),
                        totalDur: Duration(milliseconds: vmPreview.totalMs),
                      ),
                    ),
                  ),
                SliderTheme(
                  data: SliderTheme.of(context).copyWith(
                    activeTrackColor: color?.withAlpha(222) ??
                        Theme.of(context).colorScheme.primary,
                    inactiveTrackColor: color?.withAlpha(70) ??
                        Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.25),
                    secondaryActiveTrackColor: color?.withAlpha(120) ??
                        Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.4),
                    thumbColor: color ?? Theme.of(context).colorScheme.primary,
                    thumbShape: RoundSliderThumbShape(
                      enabledThumbRadius: disabled ? 0 : 6,
                    ),
                    overlayShape: const RoundSliderOverlayShape(
                      overlayRadius: 12,
                    ),
                    trackHeight: 4,
                    trackShape: _CustomTrackShape(
                      marks: vmMarks.isEmpty ? null : vmMarks,
                      tickColor: Color(vmTickArgb),
                      tickExtent: vmTickExtent.toDouble(),
                      failedColor: Theme.of(context).colorScheme.error,
                    ),
                  ),
                  child: Slider(
                    value: positionValue,
                    secondaryTrackValue: bufferValue,
                    min: sliderMin,
                    max: sliderMax,
                    onChanged: disabled
                        ? null
                        : (value) {
                            // Drag lock (see useResizeWindow): the bar is held
                            // visible by isSeeking for the whole gesture, so no
                            // per-tick showControl timer reset here.
                            dragTickMs.value = value;
                            final int ms = value.toInt();
                            // RAW value: only the release may finish the item.
                            lastDragTargetMs.value = ms;
                            if (!seekThrottle.allow(DateTime.now())) return;
                            // 仅拖时驻留: the live tick stops at the shared tail
                            // guard, so the engine never reaches EOF mid-drag.
                            // Seeking the exact end here used to rely on the
                            // suppressed-completed latch to undo it — any surface
                            // that failed to raise the scrub flag would advance
                            // the queue instead. Same contract as the circle
                            // slider's edge lock.
                            seek(Duration(
                              milliseconds: clampSeekTargetMs(
                                ms,
                                progress.duration.inMilliseconds,
                              ),
                            ));
                          },
                    onChangeStart: disabled
                        ? null
                        : (value) {
                            dragStartMs.value = value;
                            dragTickMs.value = value;
                            lastDragTargetMs.value = value.toInt();
                            seekThrottle.reset();
                            showControl?.call();
                            useScrubDragStore().beginSeek(ScrubOwners.linearSlider);
                            pause();
                          },
                    onChangeEnd: disabled
                        ? null
                        : (value) async {
                            // The live ticks are throttled, so the final drag
                            // position must be committed here or the last frame
                            // can be dropped. VM releases commit through the
                            // hooks' central stash path instead, which also
                            // carries the release-finish intent (a same-segment
                            // tick would otherwise stay `stopAtTail` and never
                            // reach `completed`).
                            final int? ms = lastDragTargetMs.value;
                            lastDragTargetMs.value = null;
                            if (ms != null) {
                              final vm = VirtualMediaController.instance;
                              // 副音 owns the controls → the slider drives the bg
                              // player, so a foreground VM session must not take
                              // the release through its stash path.
                              if (vm.isActive && !bgIsControl) {
                                vm.stashDragTarget(ms);
                              } else {
                                // The RELEASE decides: at the very end it is the
                                // explicit "finish this item" (the finish intent
                                // lets the landing sit ON the end → completed →
                                // next entry); anywhere else it stays inside the
                                // tail guard, exactly like the circle slider's
                                // release threshold. The intent only widens the
                                // upper clamp: a release between the 99%
                                // threshold and the exact end still lands on the
                                // release point and plays the tail out.
                                final int durationMs =
                                    progress.duration.inMilliseconds;
                                final commit = isSeekReleaseFinish(ms, durationMs)
                                    ? finishSeek
                                    : seek;
                                commit(Duration(milliseconds: ms));
                              }
                            }
                            dragStartMs.value = null;
                            dragTickMs.value = null;
                            if (autoPlay) {
                              play();
                            }
                            useScrubDragStore().endSeek(ScrubOwners.linearSlider);
                          },
                  ),
                ),
              ],
            ),
          ),
          Visibility(
            visible: !disabled && showTimeLabels,
            child: VmDualTimeColumn(
              total: progress.duration,
              sub: vmSubDur,
              format: formatDurationToMinutes,
              totalStyle: TextStyle(color: color, height: 2),
              align: TextAlign.end,
            ),
          ),
        ],
      ),
    );
    // AXTree stability × Android a11y (#182444 aftermath): the slider value
    // and the flanking time texts churn every tick, so the ticking subtree
    // stays excluded — but a fully silent slider would also drop out of
    // TalkBack traversal on Android (which has no Windows-style AXTree bug).
    // The outer Semantics contributes exactly ONE static, tick-invariant
    // label; the inner ExcludeSemantics keeps every per-tick property away
    // from the bridge. Windows runs with the app-level suppression anyway
    // (wrapPlatformSemantics), so this only serves Android/other platforms.
    // Hardcoded per the rapid-prototyping l10n policy — extract to ARB when
    // the l10n finalization phase begins.
    return Semantics(
      container: true,
      label: 'Playback position',
      child: ExcludeSemantics(child: ExcludeFocus(child: sliderRow)),
    );
  }
}

class _CustomTrackShape extends RoundedRectSliderTrackShape {
  const _CustomTrackShape(
      {this.marks,
      this.tickColor,
      this.tickExtent = kVmTickExtentDefault,
      this.failedColor});

  /// Virtual-media segment marks; null (or empty) when no VM session is
  /// active — the track renders exactly as before.
  final VmScrubberMarks? marks;

  /// Vertical boundary tick color (PotPlayer-style white-ish bars).
  final Color? tickColor;

  /// Pixels the tick sticks out past the axis on EACH side (0 = flush).
  final double tickExtent;

  /// Fill color for probe-failed segment spans.
  final Color? failedColor;

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required TextDirection textDirection,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isDiscrete = false,
    bool isEnabled = false,
    double additionalActiveTrackHeight = 2,
  }) {
    if (sliderTheme.trackHeight == null || sliderTheme.trackHeight! <= 0) {
      return;
    }

    final Rect trackRect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
      isEnabled: isEnabled,
      isDiscrete: isDiscrete,
    );

    final Radius trackRadius = Radius.circular(trackRect.height / 2);

    final Paint inactivePaint = Paint()
      ..color = sliderTheme.inactiveTrackColor!;
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(trackRect, trackRadius),
      inactivePaint,
    );

    if (secondaryOffset != null) {
      final Paint secondaryPaint = Paint()
        ..color = sliderTheme.secondaryActiveTrackColor!;
      final Rect secondaryRect = Rect.fromLTRB(
        trackRect.left,
        trackRect.top,
        secondaryOffset.dx,
        trackRect.bottom,
      );
      context.canvas.drawRRect(
        RRect.fromRectAndRadius(secondaryRect, trackRadius),
        secondaryPaint,
      );
    }

    final Paint activePaint = Paint()..color = sliderTheme.activeTrackColor!;
    final Rect activeRect = Rect.fromLTRB(
      trackRect.left,
      trackRect.top,
      thumbCenter.dx,
      trackRect.bottom,
    );
    context.canvas.drawRRect(
      RRect.fromRectAndRadius(activeRect, trackRadius),
      activePaint,
    );

    _paintVmMarks(context.canvas, trackRect);
  }

  /// PotPlayer-style segment decoration on top of the track: red spans for
  /// probe-failed segments, then vertical ticks at every boundary (extent
  /// past the axis per side via `tickExtent`; tint via `vmMarkTickColor`).
  void _paintVmMarks(Canvas canvas, Rect trackRect) {
    final marks = this.marks;
    if (marks == null || marks.isEmpty) return;
    final w = trackRect.width;

    if (failedColor != null) {
      final failedPaint = Paint()..color = failedColor!;
      for (final span in marks.failedSpans) {
        final left = trackRect.left + span.start * w;
        final right = trackRect.left + span.end * w;
        canvas.drawRRect(
          RRect.fromRectAndRadius(
            Rect.fromLTRB(left, trackRect.top - 1, right, trackRect.bottom + 1),
            Radius.circular(trackRect.height / 2),
          ),
          failedPaint,
        );
      }
    }

    if (tickColor != null) {
      final tickPaint = Paint()..color = tickColor!;
      final e = tickExtent
          .clamp(kVmTickExtentMinPx.toDouble(), kVmTickExtentMaxPx.toDouble())
          .toDouble();
      for (final f in marks.boundaries) {
        final x = trackRect.left + f * w;
        canvas.drawRect(
          Rect.fromLTWH(x - 1, trackRect.top - e, 2, trackRect.height + 2 * e),
          tickPaint,
        );
      }
    }
  }
}
