import 'dart:async';
import 'dart:math' as m;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/services/bg_seek_window.dart';
import 'package:iris/features/background_playback/services/bg_vm_visibility.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/control_group/domain/center_zone.dart';
import 'package:iris/features/control_group/domain/center_zone_actions.dart';
import 'package:iris/features/control_group/domain/center_zone_icons.dart';
import 'package:iris/features/control_group/view/center_zone_sector_icons.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_edge_lock.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_math.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_ring_dial_palette.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/phone_scrubber_live_seek_throttle.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_scrubber_time.dart';
import 'package:iris/features/virtual_media/interaction/ui/vm_dual_time.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/view/vm_scrubber_marks.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/center_zone_x.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:provider/provider.dart';

/// Scrub-surface diagnostics (`log.dial`): hit-test resolution and drag-state
/// transitions for on-device verification of the "tap works / drag does
/// nothing" report.
final AreaKeyLog _dialLog = AreaKeyLog(LogKeys.dial);

/// Paint color of the dial's two drag thumbs and its two ring-wedge numerals.
/// Always white: these are the primary affordance and must be findable at a
/// glance over any palette or video frame — never palette- or theme-derived.
const Color kDialHandleColor = Colors.white;

/// Dark drop shadow under the white thumbs/numerals so they stay legible on
/// bright video frames without changing the white reading.
const List<Shadow> kDialHandleShadows = <Shadow>[
  Shadow(blurRadius: 3, color: Colors.black87),
];

/// Dual-ring dial scrubber ("Ring dial").
///
/// Two concentric rings share the same 330° notched geometry (scheme A,
/// `-30°·index` per block) but their *functional assignment* is swappable via
/// [RingDialAssignment]:
/// - chunk ring (分块环): segmented wayfinding band (≈7px) sampled at
///   maxBlocks (11), lighting passed blocks, mapping the WHOLE media duration
///   (absolute clock + quadrant edge-lock). VM marks follow it.
/// - progress ring (块内环): thin current-block revolution (≈4px) mapping one
///   block's span (relative delta via [PhoneRingDialSession]).
///
/// `innerChunk` (legacy) = chunk on inner radius, progress on outer;
/// `outerChunk` swaps the radii. Stroke widths follow function, radii follow
/// physical `ringDialOuterRadius`/`ringDialInnerRadius`.
///
/// Both rings live inside an invisible bounding box together with the fixed
/// precision axis strip ([PhoneRingDialMath.dialBox]); the ring and the strip
/// can be shifted horizontally inside that box independently.
///
/// Two controls sit in the "leftover corners" between the ring's outer
/// circle and the dial face square: top-right speed toggle, bottom-left
/// random jump. Top-left / bottom-right stay empty — a one-handed thumb
/// cannot reach them. Quick taps fire on RELEASE; a LONG PRESS
/// describes the control via a tooltip and SWALLOWS the tap action (the
/// gesture arena never delivers onTapUp once the long-press recognizer wins),
/// and keeps the control bar alive while held.
class PhoneRingDialScrubber extends HookWidget {
  const PhoneRingDialScrubber({
    super.key,
    required this.showControl,
    required this.color,
    required this.isLeftHanded,
    this.availableSpan,
    this.dialHeightPx,
  });

  final VoidCallback showControl;
  final Color? color;
  final bool isLeftHanded;

  /// Vertical span between screen top and button-bar top (see
  /// [PhoneOneHandedScrubber.availableSpan]); null falls back to the incoming
  /// layout constraints.
  final double? availableSpan;

  /// Explicit dial box height (px) from the sideway panel's sticky-height
  /// contract — wins over the height-share knob when provided.
  final double? dialHeightPx;

  /// Legacy corner icon size, shared by the step/speed corner widgets.
  static const double _kCornerIconSize = 20;

  @override
  Widget build(BuildContext context) {
    // AXTree stability (flutter/flutter#182444): see PhoneSnakeScrubber —
    // per-tick rebuilds with zero assistive value stay out of semantics.
    return ExcludeSemantics(child: _buildTree(context));
  }

  Widget _buildTree(BuildContext context) {
    final bool autoPlay =
        useAppStore().select(context, (state) => state.autoPlay);
    // Single-owner scrub flag (see ScrubDragStore): the drag session, not a
    // bare boolean, decides who owns the preview.
    final bool isScrubbing =
        useScrubDragStore().select(context, (s) => s.isScrubbing);
    // Centre sectors are relative to the screen centre; the panel's 9-grid
    // anchor decides which horizontal side is "inward". Subscribed (not a
    // one-shot state read) so the sector icons re-seat when the panel flips
    // sides; the tap handler captures the same fresh value per build.
    final bool inwardOnLeft = useAppStore()
        .select(context, (AppState s) => resolveSidePanelAlignment(s).x > 0);
    // Center-sector hint icons: field-scoped like the other dial knobs so a
    // per-frame position tick does not rebuild the overlay.
    final CircleSliderCenterAction centerInward = useAppStore()
        .select(context, (AppState s) => s.centerZoneInwardAction);
    final CircleSliderCenterAction centerOutward = useAppStore()
        .select(context, (AppState s) => s.centerZoneOutwardAction);
    final CircleSliderCenterAction centerTop = useAppStore()
        .select(context, (AppState s) => s.centerZoneTopAction);
    final CircleSliderCenterAction centerBottom = useAppStore()
        .select(context, (AppState s) => s.centerZoneBottomAction);
    final bool desktopPhoneMode = useAppStore()
        .select(context, (AppState s) => s.desktopCenterZonePhoneMode);
    final RingDialPalette dialPalette =
        useAppStore().select(context, (state) => state.ringDialPalette);
    final double heightPct =
        useAppStore().select(context, (state) => state.ringDialHeightPct);
    final DialSide dialSide =
        useAppStore().select(context, (state) => state.ringDialSide);
    final RingDialAssignment assignment = useAppStore()
        .select(context, (state) => state.ringDialAssignment);
    final bool hideChunkWhenUnchunked = useAppStore()
        .select(context, (state) => state.ringDialHideChunkWhenUnchunked);
    // Virtual media: clamp the progress-ring DRAG inside the current file
    // (user setting, default ON). The chunk ring keeps whole-timeline travel.
    final bool lockVmProgress = useAppStore()
        .select(context, (state) => state.ringDialVmProgressLock);
    final bool isChunkInner =
        assignment == RingDialAssignment.innerChunk;
    final double ringSlotT =
        useAppStore().select(context, (state) => state.ringDialRingSlotT);
    final double ringOuterFactor =
        useAppStore().select(context, (state) => state.ringDialOuterRadius);
    final double ringInnerFactor =
        useAppStore().select(context, (state) => state.ringDialInnerRadius);
    final double rate = useAppStore().select(context, (state) => state.rate);
    final double transientRate =
        useAppStore().select(context, (state) => state.transientRate);

    final progress = context.select<MediaPlayer,
        ({Duration position, Duration duration, Duration buffer})>(
      (MediaPlayer p) =>
          (position: p.position, duration: p.duration, buffer: p.buffer),
    );
    final MediaPlayer player = context.read<MediaPlayer>();
    // Virtual-media segment marks (painted on the inner full-timeline ring).
    // Suppressed while the controls target 副音: the bg engine plays a real
    // single file, so the dial must fall back to the time-derived block model
    // instead of the foreground's per-file equal sectors.
    final vmItemRaw = useVmPlaybackStore().select(context, (s) => s.item);
    final bgStore = useBackgroundPlaybackStore();
    final bgIsControl =
        bgStore.select(context, (s) => s.bgOwnsControls);
    // 仅当前 + 高同步 publishes the bg's playable window [floor, ceiling] on the
    // bg file axis. The dial maps the WHOLE file, so the unreachable part must
    // be clamped on commit AND marked (ticks + dim) — the "beyond fg 100%"
    // region otherwise snapped the thumb back with no explanation.
    final int? bgSeekFloorMs =
        bgStore.select(context, (s) => s.bgSeekFloorLocalMs);
    final int? bgSeekCeilingMs =
        bgStore.select(context, (s) => s.bgSeekCeilingLocalMs);
    final vmItem = vmItemForControlTarget(vmItemRaw, bgIsControl: bgIsControl);
    final vmSyncMode = useAppStore().select(context, (s) => s.vmDualTimeSync);
    final VmScrubberMarks vmMarks =
        useMemoized(() => computeVmScrubberMarks(vmItem), [vmItem]);
    // Lengthened boundary ticks, user-tinted (opaque white default) and
    // user-sized (per-side reach from `virtualmedia.markTickExtent`).
    final vmTickArgb =
        useAppStore().select(context, (s) => s.vmMarkTickColor);
    final vmTickExtent =
        useAppStore().select(context, (s) => s.vmMarkTickExtent);
    final Duration duration = progress.duration > Duration.zero
        ? progress.duration
        : const Duration(milliseconds: 1);
    final BgSeekWindow? bgWindow = bgIsControl
        ? resolveBgSeekWindow(
            duration: duration,
            floorMs: bgSeekFloorMs,
            ceilingMs: bgSeekCeilingMs,
          )
        : null;
    final double? bgWindowFloorFraction =
        (bgWindow?.hasLimit ?? false) ? bgWindow!.floorFraction : null;
    final double? bgWindowCeilingFraction =
        (bgWindow?.hasLimit ?? false) ? bgWindow!.ceilingFraction : null;
    // Clamp a whole-file target into the published window (no-op without one).
    Duration clampToWindow(Duration target) =>
        bgWindow == null ? target : clampBgSeekDuration(bgWindow, target);
    final preview =
        useState(clampToWindow(_clamp(progress.position, duration)));
    // Functional drag role — chunk (whole-timeline, absolute) vs progress
    // (current-block, relative). Physical radius is derived from [isChunkInner].
    final ValueNotifier<_DragRole?> surface = useState(null);
    // Relative deltas for the progress (block-local) ring.
    final progressSession = useRef<PhoneRingDialSession?>(null);
    // Absolute clock + quadrant edge-lock for the chunk (wayfinding) ring.
    final InnerEdgeLockSession chunkLock =
        useMemoized(InnerEdgeLockSession.new, const <Object?>[]);
    // Corner currently long-pressed (tooltip anchor), null while idle.
    final ValueNotifier<int?> holdTip = useState<int?>(null);
    final LiveSeekThrottle seekThrottle =
        useMemoized(LiveSeekThrottle.new, const <Object?>[]);

    // Latch-proof teardown: a dial removed mid-gesture (control-bar swap,
    // route change, backend switch) releases only ITS sessions. Deferred to a
    // microtask so the store notification lands outside the unmount frame.
    useEffect(() {
      return () {
        scheduleMicrotask(() {
          useScrubDragStore()
            ..endSeek(ScrubOwners.ringDial)
            ..endHold(ScrubOwners.ringDial);
        });
      };
    }, const <Object?>[]);

    useEffect(() {
      // The preview is owned only while BOTH this surface's armed drag and the
      // single-owner scrub session agree. Either signal alone could latch (a
      // lost end event) and freeze the dial time; the store's flag is released
      // on teardown, so a lost gesture can no longer stick.
      final bool dragOwns = isScrubbing && surface.value != null;
      if (!dragOwns) {
        preview.value = clampToWindow(_clamp(progress.position, duration));
      }
      return null;
    }, <Object>[progress.position, duration, isScrubbing]);

    Future<void> beginScrub() async {
      _dialLog.d('[dial-drag] begin autoPlay=$autoPlay '
          'playing=${player.isPlaying}');
      showControl();
      useScrubDragStore().beginSeek(ScrubOwners.ringDial);
      await player.pause();
    }

    Future<void> finishScrub(Duration committed) async {
      _dialLog.d('[dial-drag] commit target=${committed.inMilliseconds}');
      // The dial commits a POSITION inside the shared tail guard
      // (`kSeekTailGuardMs`), it is not a "finish this item" gesture: the
      // landing stays 100 ms short of the end and the queue advances by
      // PLAYING that tail out (`if (autoPlay) play()` below → EOF →
      // `completed`). Do not "unify" it with the slider's
      // `isSeekReleaseFinish` + `finishSeek` release: a wayfinding dial
      // jumping exactly onto EOF while paused is not the intent here, and with
      // autoPlay off the difference is a 100 ms position, not an advance.
      await player.seek(
          PhoneRingDialMath.clampSeekTarget(clampToWindow(committed), duration));
      _dialLog.d('[dial-drag] end committed=$committed autoPlay=$autoPlay '
          'playing=${player.isPlaying}');
      if (autoPlay) await player.play();
      useScrubDragStore().endSeek(ScrubOwners.ringDial);
    }

    Future<void> abortScrub() async {
      _dialLog.d('[dial-drag] cancel autoPlay=$autoPlay '
          'playing=${player.isPlaying}');
      if (autoPlay) await player.play();
      useScrubDragStore().endSeek(ScrubOwners.ringDial);
    }

    void handleCenterTap(
      BuildContext context,
      Offset local,
      Offset center,
    ) {
      final CenterZone zone =
          centerZoneForOffset(local, center, inwardOnLeft: inwardOnLeft);
      final CircleSliderCenterAction action =
          resolveCenterZoneAction(useAppStore().state, zone);
      handleCenterZoneAction(
        context: context,
        action: action,
        showControl: showControl,
      );
    }

    final bool mediaUnknown =
        progress.duration <= Duration.zero; // live/unknown: disabled
    final bool randomReady =
        PhoneRingDialMath.randomEnabled(progress.duration);
    final bool speedReady = transientRate > 1.0;

    void jumpRandom() {
      final Duration target = PhoneRingDialMath.randomTarget(
        duration: progress.duration,
        current: progress.position,
        rng: m.Random(),
      );
      // ignore: discarded_futures
      player.seek(PhoneRingDialMath.clampSeekTarget(target, progress.duration));
    }

    void toggleFixedSpeed() {
      // ignore: discarded_futures
      useAppStore().updateRate(rate == 1.0 ? transientRate : 1.0);
    }

    final Widget dialWidget = LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double panelW =
            constraints.maxWidth.isFinite ? constraints.maxWidth : 320;
        // Height basis is the measured screen-top↔button-bar span when the
        // hosting panel provides it; constraints are only the fallback.
        final double maxH = availableSpan ??
            (constraints.maxHeight.isFinite ? constraints.maxHeight : 280);

        // Invisible bounding box: ring square + fixed axis strip. The
        // sideway panel's sticky px height wins when provided; otherwise the
        // height share of [maxH] drives the ring size — bottom edge stays
        // flush against the button row, only the TOP edge moves with this
        // knob.
        final RingDialBox box = dialHeightPx != null
            ? PhoneRingDialMath.dialBox(
                panelWidth: panelW,
                maxHeight: dialHeightPx!,
                heightPct: 1.0,
              )
            : PhoneRingDialMath.dialBox(
                panelWidth: panelW,
                maxHeight: maxH,
                heightPct: heightPct,
              );
        final double ringX = PhoneRingDialMath.dialPlacementPx(
          box: box,
          leftHanded: isLeftHanded,
          side: dialSide,
          ringSlotT: ringSlotT,
        );

        // One geometry per layout pass; closures, painter and overlays share it.
        final RingDialGeometry g = PhoneRingDialMath.dialGeometry(
          size: Size.square(box.diameter),
          outerRadiusFactor: ringOuterFactor,
          innerRadiusFactor: ringInnerFactor,
        );

        final int blockCount = vmItem != null
            ? PhoneRingDialMath.vmBlockCountFor(vmItem.segments.length)
            : PhoneRingDialMath.blockCountFor(duration);
        final int currentIndex = vmItem != null
            ? vmItem.locate(preview.value.inMilliseconds).$1
            : PhoneRingDialMath.blockIndexForPosition(preview.value, duration);
        // Requirement #8 + virtual single-segment hide (spec §8):
        // - Real: hideChunkWhenUnchunked applies (blockCount <=1).
        // - Virtual: vmHideChunkWhenSingleSegment applies (segments<=1),
        //   mutually exclusive with the real toggle.
        final bool isVmDial = vmItem != null;
        final bool vmHideSingle = useAppStore()
            .state
            .vmHideChunkWhenSingleSegment;
        final bool chunkVisible = isVmDial
            ? !(vmHideSingle && vmItem.segments.length <= 1)
            : !(hideChunkWhenUnchunked && blockCount <= 1);

        double clockDegFor(Offset ringLocal, Offset center) {
          final double rad =
              m.atan2(ringLocal.dy - center.dy, ringLocal.dx - center.dx);
          return (rad * 180 / m.pi + 90 + 360) % 360;
        }

        // Center readout: `_DialOverlays` renders these four rows, and the
        // very same strings/styles are measured here so the 45° sector X can
        // leave a hole over the numbers instead of drawing through them.
        final Color accent = color ?? Theme.of(context).colorScheme.primary;
        final String centerCurrent =
            _vmTotalCurrentText(vmItem, preview.value, vmSyncMode);
        final String centerTotal = '/ ${formatPhoneScrubberTime(duration)}';
        final String? centerSubCurrent =
            _vmSubCurrentText(vmItem, preview.value, vmSyncMode);
        final String? centerSubTotal =
            _vmSubTotalText(vmItem, preview.value, vmSyncMode);
        final double centerGapRadius = centerZoneGapRadius(
          rows: <({String text, TextStyle style})>[
            (text: centerCurrent, style: _DialOverlays.currentStyle(accent)),
            if (centerSubCurrent != null)
              (text: centerSubCurrent, style: _DialOverlays.subStyle(accent)),
            (text: centerTotal, style: _DialOverlays.totalStyle(accent)),
            if (centerSubTotal != null)
              (text: centerSubTotal, style: _DialOverlays.subStyle(accent)),
          ],
          radius: g.centerHitR,
        );
        // Sector hint icons share the tap resolution (desktop legacy
        // all-toggleControls included) so the glyph always matches the tap.
        final Map<CenterZone, CircleSliderCenterAction> centerActions =
            resolveCenterZoneActionMap(
          inward: centerInward,
          outward: centerOutward,
          top: centerTop,
          bottom: centerBottom,
          desktopPhoneMode: desktopPhoneMode,
        );
        final Map<CenterZone, IconData?> centerSectorIcons =
            <CenterZone, IconData?>{
          for (final MapEntry<CenterZone, CircleSliderCenterAction> e
              in centerActions.entries)
            e.key: centerZoneActionIcon(e.value),
        };

        return SizedBox(
          width: box.width,
          height: box.height,
          child: Stack(
            clipBehavior: Clip.none,
            children: <Widget>[
              // ── The dial itself (ring square, shifted horizontally) ──
              Positioned(
                left: ringX,
                top: (box.height - box.diameter) / 2,
                width: box.diameter,
                height: box.diameter,
                child: Builder(builder: (BuildContext ctx) => GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapDown: (TapDownDetails d) {
                    if (mediaUnknown) return;
                    final RenderBox box2 =
                        ctx.findRenderObject()! as RenderBox;
                    final Offset local = box2.globalToLocal(d.globalPosition);
                    final Offset center = box2.size.center(Offset.zero);
                    final _Hit hit = _classify(local, center, g, blockCount,
                        assignment: assignment,
                        chunkVisible: chunkVisible,
                        isVm: isVmDial);
                    switch (hit.region) {
                      case _HitRegion.center:
                        handleCenterTap(ctx, local, center);
                        return;
                      case _HitRegion.chunk:
                        showControl();
                        HapticFeedback.selectionClick();
                        preview.value = isVmDial
                            // Equal-division tap: sector i IS file i — the
                            // intra-sector angle scales onto that file's real
                            // span (margins keep off exact seams).
                            ? Duration(
                                milliseconds:
                                    PhoneRingDialMath.vmVirtualForChunkTap(
                                  item: vmItem,
                                  sector: hit.sector,
                                  sectorFraction: hit.sectorFraction,
                                ))
                            : PhoneRingDialMath.positionForInnerTap(
                                index: hit.sector,
                                sectorFraction: hit.sectorFraction,
                                duration: duration,
                                rng: m.Random(),
                                // MUST stay on the grid `_classify` derived
                                // hit.sector from: capped (11) slots for real
                                // media, one sector per file for virtual media.
                                // maxBlocks == kMaxInnerSlots keeps real media
                                // 1:1, but the cap remains as a defensive
                                // guard. Passing the raw blockCount here once
                                // re-scaled the sector onto a different grid and
                                // landed the seek up to a whole slot away from
                                // the tapped sector.
                                slotCount: PhoneRingDialMath.chunkSlotCount(
                                    blockCount,
                                    isVm: isVmDial),
                              );
                        preview.value = clampToWindow(preview.value);
                        seekThrottle.reset();
                        _dialLog.d('[dial-tap] band=chunk '
                            'target=${preview.value.inMilliseconds}');
                        // ignore: discarded_futures
                        player.seek(PhoneRingDialMath.clampSeekTarget(
                            preview.value, duration));
                        return;
                      case _HitRegion.progress:
                        final Duration? t = isVmDial
                            ? _vmPositionForOuterTap(
                                local: local,
                                center: center,
                                fileIndex: currentIndex,
                                vmItem: vmItem,
                              )
                            : PhoneRingDialMath.positionForOuterTap(
                                clockDeg: clockDegFor(local, center),
                                blockIndex: currentIndex,
                                duration: duration,
                                blockCount: blockCount,
                              );
                        if (t == null) return;
                        showControl();
                        HapticFeedback.selectionClick();
                        preview.value = clampToWindow(t);
                        seekThrottle.reset();
                        _dialLog.d('[dial-tap] band=progress '
                            'target=${preview.value.inMilliseconds}');
                        // ignore: discarded_futures
                        player.seek(PhoneRingDialMath.clampSeekTarget(
                            preview.value, duration));
                        return;
                      case _HitRegion.btnSpeed:
                      case _HitRegion.btnRandom:
                        // Corners act on RELEASE (onTapUp below) so a winning
                        // long-press intercepts the single-tap function.
                        return;
                      case _HitRegion.dead:
                        return;
                    }
                  },
                  onTapUp: (TapUpDetails d) {
                    if (mediaUnknown) return;
                    final RenderBox box2 =
                        ctx.findRenderObject()! as RenderBox;
                    final Offset local = box2.globalToLocal(d.globalPosition);
                    final Offset center = box2.size.center(Offset.zero);
                    switch (_classify(local, center, g, blockCount,
                            assignment: assignment,
                            chunkVisible: chunkVisible,
                            isVm: isVmDial)
                        .region) {
                      case _HitRegion.btnSpeed:
                        if (!speedReady) return;
                        showControl();
                        HapticFeedback.selectionClick();
                        toggleFixedSpeed();
                        return;
                      case _HitRegion.btnRandom:
                        if (!randomReady) return;
                        showControl();
                        HapticFeedback.selectionClick();
                        jumpRandom();
                        return;
                      default:
                        return;
                    }
                  },
                  onPanStart: (DragStartDetails d) async {
                    if (mediaUnknown) return;
                    final RenderBox box2 =
                        ctx.findRenderObject()! as RenderBox;
                    final Offset local = box2.globalToLocal(d.globalPosition);
                    final Offset center = box2.size.center(Offset.zero);
                    // Ring bands take priority for DRAGS: the corner-button
                    // circles overlap the outer band near the diagonals, and
                    // a pan that starts on a band must scrub instead of dying
                    // on a corner hit (TAPS keep corner priority — see
                    // onTapDown/onTapUp). Every press resolves to a band via
                    // the nearest-band fallback, so a drag is never swallowed
                    // (the old silent `return` here read as "tap jumps, drag
                    // does nothing").
                    final double dist = (local - center).distance;
                    final RingDialDragBand band =
                        PhoneRingDialMath.resolveDragBand(
                      dist: dist,
                      geometry: g,
                      chunkIsOuter: !isChunkInner,
                      chunkVisible: chunkVisible,
                    );
                    _dialLog.d(
                        '[dial-drag] start band=${band.name} '
                        'dist=${dist.toStringAsFixed(1)} '
                        'innerR=${g.innerR.toStringAsFixed(1)} '
                        'outerR=${g.outerR.toStringAsFixed(1)} '
                        'hitHalf=${g.innerHitHalf.toStringAsFixed(1)} '
                        'chunkVisible=$chunkVisible isVm=$isVmDial '
                        'chunkInner=$isChunkInner');
                    switch (band) {
                      case RingDialDragBand.progress:
                        surface.value = _DragRole.progress;
                        progressSession.value = isVmDial
                            ? PhoneRingDialSession.vm(
                                item: vmItem,
                                startVirtualMs: preview.value.inMilliseconds,
                                lockToSegment: lockVmProgress,
                              )
                            : PhoneRingDialSession(
                                duration: duration,
                                start: preview.value,
                                blockCount: blockCount);
                      case RingDialDragBand.chunk:
                        surface.value = _DragRole.chunk;
                        chunkLock.clear();
                    }
                    seekThrottle.reset();
                    await beginScrub();
                  },
                  onPanUpdate: (DragUpdateDetails d) {
                    _DragRole? s = surface.value;
                    final RenderBox box2 =
                        ctx.findRenderObject()! as RenderBox;
                    final Offset local = box2.globalToLocal(d.globalPosition);
                    final Offset center = box2.size.center(Offset.zero);
                    if (s == null) {
                      // Defensive late-arm: a rebuild or a media-state flip
                      // between start and update must not drop the move. The
                      // band is resolved live and the scrub continues.
                      final double dist = (local - center).distance;
                      final RingDialDragBand band =
                          PhoneRingDialMath.resolveDragBand(
                        dist: dist,
                        geometry: g,
                        chunkIsOuter: !isChunkInner,
                        chunkVisible: chunkVisible,
                      );
                      s = band == RingDialDragBand.chunk
                          ? _DragRole.chunk
                          : _DragRole.progress;
                      surface.value = s;
                      if (s == _DragRole.chunk) {
                        chunkLock.clear();
                      } else {
                        progressSession.value = isVmDial
                            ? PhoneRingDialSession.vm(
                                item: vmItem,
                                startVirtualMs: preview.value.inMilliseconds,
                                lockToSegment: lockVmProgress,
                              )
                            : PhoneRingDialSession(
                                duration: duration,
                                start: preview.value,
                                blockCount: blockCount);
                      }
                      seekThrottle.reset();
                      _dialLog.d('[dial-drag] late-arm band=${band.name} '
                          'dist=${dist.toStringAsFixed(1)}');
                    }
                    final double clockDeg = clockDegFor(local, center);
                    if (s == _DragRole.progress) {
                      final PhoneRingDialSession? session =
                          progressSession.value;
                      if (session == null) return;
                      // Relative shortest-path deltas are wrap-free and clamp
                      // at both media ends: dragging past 0% sticks (no wrap
                      // to 100%) and past the end sticks at 100% (held
                      // without release never advances the episode; the
                      // commit guard keeps the final seek sub-end).
                      preview.value = session.update(clockDeg);
                    } else {
                      // Absolute mapping guarded by the quadrant continuity
                      // lock: Q1↔Q2 crossings stick at 0%/100% instead of
                      // wrapping (legacy circle slider contract). VM maps the
                      // equal-division angle back onto the file's real span so
                      // the drag tracks the equal-arc thumb.
                      preview.value = isVmDial
                          ? _vmPositionForChunkDrag(
                              dx: local.dx - center.dx,
                              dy: local.dy - center.dy,
                              clockDeg: clockDeg,
                              vmItem: vmItem,
                              lock: chunkLock,
                            )
                          : chunkLock.apply(
                              dx: local.dx - center.dx,
                              dy: local.dy - center.dy,
                              clockDeg: clockDeg,
                              duration: duration,
                            );
                    }
                    // 仅当前 + 高同步: the whole-file drag target is clamped into
                    // the published window so the thumb never leaves the marked
                    // playable range (and the commit can't roll the fg).
                    final Duration beforeClamp = preview.value;
                    preview.value = clampToWindow(preview.value);
                    if (preview.value != beforeClamp) {
                      _dialLog.d('[dial-drag] window-clamp '
                          '${beforeClamp.inMilliseconds}'
                          '->${preview.value.inMilliseconds}');
                    }
                    // No per-tick showControl: beginScrub armed the bar and
                    // the scrub session holds it for the whole drag.
                    final bool emitted = seekThrottle.allow(DateTime.now());
                    if (emitted) {
                      _dialLog.d('[dial-drag] live-seek '
                          'target=${preview.value.inMilliseconds}');
                      // ignore: discarded_futures
                      player.seek(PhoneRingDialMath.clampSeekTarget(
                          preview.value, duration));
                    } else {
                      _dialLog.d('[dial-drag] update throttled '
                          'role=${s.name} clock=${clockDeg.toStringAsFixed(1)} '
                          'preview=${preview.value.inMilliseconds}');
                    }
                  },
                  onPanEnd: (DragEndDetails d) async {
                    final _DragRole? s = surface.value;
                    _dialLog.d('[dial-drag] panEnd role=${s?.name} '
                        'preview=${preview.value.inMilliseconds} '
                        'playing=${player.isPlaying}');
                    surface.value = null;
                    progressSession.value = null;
                    if (s == null) return;
                    await finishScrub(preview.value);
                  },
                  onPanCancel: () async {
                    _dialLog.d('[dial-drag] panCancel '
                        'role=${surface.value?.name} playing=${player.isPlaying}');
                    surface.value = null;
                    progressSession.value = null;
                    await abortScrub();
                  },
                  onLongPressStart: (LongPressStartDetails d) {
                    if (mediaUnknown) return;
                    final RenderBox box2 =
                        ctx.findRenderObject()! as RenderBox;
                    final Offset local = box2.globalToLocal(d.globalPosition);
                    final Offset center = box2.size.center(Offset.zero);
                    final int? q = switch (_classify(local, center, g,
                            blockCount,
                            assignment: assignment,
                            chunkVisible: chunkVisible,
                            isVm: isVmDial)
                        .region) {
                      // Corner index doubles as the tooltip anchor: top-right
                      // speed (1), bottom-left random (2). Empty corners never
                      // classify here, so a hold there stays inert.
                      _HitRegion.btnSpeed => 1,
                      _HitRegion.btnRandom => 2,
                      _ => null,
                    };
                    if (q == null) return;
                    // Unified corner long-press: describe the control while
                    // held; a hold also counts as active use so the control
                    // bar cannot auto-hide mid-press.
                    holdTip.value = q;
                    showControl();
                    useScrubDragStore().beginHold(ScrubOwners.ringDial);
                    HapticFeedback.selectionClick();
                  },
                  onLongPressEnd: (LongPressEndDetails d) {
                    holdTip.value = null;
                    useScrubDragStore().endHold(ScrubOwners.ringDial);
                  },
                  onLongPressCancel: () {
                    holdTip.value = null;
                    useScrubDragStore().endHold(ScrubOwners.ringDial);
                  },
                    child: CustomPaint(
                    key: const ValueKey('vmDialPaint'),
                    painter: _DialPainter(
                      previewMs: preview.value.inMilliseconds.toDouble(),
                      durationMs: duration.inMilliseconds.toDouble(),
                      bufferMs: progress.buffer.inMilliseconds.toDouble(),
                      blockCount: blockCount,
                      accent: accent,
                      palette: dialPalette,
                      geometry: g,
                      assignment: assignment,
                      showChunk: chunkVisible,
                      vmItem: vmItem,
                      vmMarks: vmMarks.isEmpty ? null : vmMarks,
                      vmTickColor: Color(vmTickArgb),
                      vmTickExtent: vmTickExtent,
                      vmFailedColor:
                          Theme.of(context).colorScheme.error,
                      windowFloorFraction: bgWindowFloorFraction,
                      windowCeilingFraction: bgWindowCeilingFraction,
                      centerGapRadius: centerGapRadius,
                    ),
                     child: _DialOverlays(
                       diameter: box.diameter,
                       accent: accent,
                       currentText: centerCurrent,
                       totalText: centerTotal,
                       // B-scheme dual time follows the DISPLAYED (preview)
                       // value so drag previews and ticks agree. Ring geometry
                       // intentionally stays equal-division (spec §8).
                       subCurrentText: centerSubCurrent,
                       subTotalText: centerSubTotal,
                        randomReady: randomReady,
                        speedReady: speedReady,
                        speedActive: rate != 1.0,
                        rateLabel: _formatRate(rate),
                        midlineIsLeft: !isLeftHanded,
                        holdTip: holdTip.value,
                        transientRate: transientRate,
                        sectorIcons: centerSectorIcons,
                        sectorInwardOnLeft: inwardOnLeft,
                        centerHitR: g.centerHitR,
                        centerGapRadius: centerGapRadius,
                     ),
                   ),
                 ),
               ),
             ),
             // ── Long-press tooltip layer ──
             // Corner coordinates are ring-square-local; re-anchor them into
             // the Stack space so the bubble follows the shifted ring.
             if (holdTip.value != null)
               Positioned(
                 left: (g.cornerCenters[holdTip.value!].dx -
                         _tooltipHalfWidth)
                     .clamp(0.0, m.max(0.0, box.width - _tooltipWidth))
                     .toDouble() +
                     ringX,
                 top: m.max(2.0,
                         g.cornerCenters[holdTip.value!].dy - 46) +
                     (box.height - box.diameter) / 2,
                 child: Container(
                   padding: const EdgeInsets.symmetric(
                       horizontal: 8, vertical: 4),
                   decoration: BoxDecoration(
                     color: Colors.black.withValues(alpha: 0.72),
                     borderRadius: BorderRadius.circular(8),
                   ),
                   child: Text(
                      _tooltipText(
                        getLocalizations(context),
                        corner: holdTip.value!,
                        transientRate: transientRate,
                      ),
                     style: const TextStyle(
                       fontSize: 11,
                       height: 1.15,
                       color: Colors.white,
                     ),
                   ),
                 ),
               ),
           ],
         ),
        );
      },
    );

    if (mediaUnknown) {
      return IgnorePointer(
        child: Opacity(opacity: 0.4, child: dialWidget),
      );
    }
    return dialWidget;
  }

  static const double _tooltipWidth = 96;
  static const double _tooltipHalfWidth = 48;

  static String _formatRate(double rate) {
    if (rate == rate.roundToDouble()) {
      return '${rate.round()}×';
    }
    return '${rate.toStringAsFixed(2)}×';
  }

  /// B-scheme total-position text for the dial center (sync-aligned display
  /// value; non-VM echoes the shown position).
  static String _vmTotalCurrentText(
      VirtualMediaItem? vmItem, Duration shown, VmDualTimeSyncMode sync) {
    final dual =
        VmDualTime.resolve(vmItem, shown.inMilliseconds, sync: sync);
    return formatPhoneScrubberTime(
        Duration(milliseconds: dual.displayVirtualMs));
  }

  /// B-scheme sub-position text for the dial center (null when no VM
  /// session or a single-segment merge). Pure formatting over
  /// [VmDualTime]; geometry untouched.
  static String? _vmSubCurrentText(
      VirtualMediaItem? vmItem, Duration shown, VmDualTimeSyncMode sync) {
    final dual =
        VmDualTime.resolve(vmItem, shown.inMilliseconds, sync: sync);
    if (!dual.showSub) return null;
    return formatPhoneScrubberTime(
        Duration(milliseconds: dual.displayLocalMs));
  }

  /// B-scheme sub-duration text (null additionally while the probe hasn't
  /// resolved the segment duration).
  static String? _vmSubTotalText(
      VirtualMediaItem? vmItem, Duration shown, VmDualTimeSyncMode sync) {
    final dual =
        VmDualTime.resolve(vmItem, shown.inMilliseconds, sync: sync);
    if (!dual.showSub || dual.segDurMs == null) return null;
    return '/ ${formatPhoneScrubberTime(Duration(milliseconds: dual.segDurMs!))}';
  }

  static String _tooltipText(
    AppLocalizations t, {
    required int corner,
    required double transientRate,
  }) {
    switch (corner) {
      case 1:
        return t.dial_tip_speed(_formatRate(transientRate));
      default:
        return t.dial_tip_random;
    }
  }
}

enum _DragRole { chunk, progress }

enum _HitRegion { center, chunk, progress, btnSpeed, btnRandom, dead }

class _Hit {
  const _Hit(this.region, this.sector, this.sectorFraction);
  final _HitRegion region;
  final int sector;
  final double sectorFraction;
}

_Hit _classify(
  Offset local,
  Offset center,
  RingDialGeometry g,
  int blockCount, {
  required RingDialAssignment assignment,
  required bool chunkVisible,
  bool isVm = false,
}) {
  // Corner buttons take priority — only top-right (speed toggle) and
  // bottom-left (random jump) host controls. Top-left / bottom-right are
  // empty for one-handed reach: taps there fall through to the bands below
  // instead of being swallowed (环外侧与 panel 背景间的剩余空间).
  for (final int q in const <int>[1, 2]) {
    if ((local - g.cornerCenters[q]).distance <= g.cornerHitR) {
      return q == 1
          ? const _Hit(_HitRegion.btnSpeed, 0, 0)
          : const _Hit(_HitRegion.btnRandom, 0, 0);
    }
  }
  final double dist = (local - center).distance;
  final bool chunkIsOuter = assignment == RingDialAssignment.outerChunk;
  final double chunkR = chunkIsOuter ? g.outerR : g.innerR;
  final double progressR = chunkIsOuter ? g.innerR : g.outerR;

  // Helper to test chunk band (thick, sector-aware). Stroke follows function.
  // Radial tolerance is shared with the drag path (PhoneRingDialMath) so a tap
  // and a drag can never disagree about which band was pressed.
  bool chunkHit() {
    if (!chunkVisible) return false;
    if (!PhoneRingDialMath.chunkBandHit(dist, chunkR, g)) return false;
    final double dx = local.dx - center.dx;
    final double dy = local.dy - center.dy;
    final double rad = m.atan2(dy, dx);
    final double deg = (rad * 180 / m.pi + 90 + 360) % 360;
    final ({double fraction, bool inGap}) hit =
        PhoneRingDialMath.fractionForInnerClock(deg);
    if (hit.inGap) return false; // dead wedge
    return true;
  }

  _Hit chunkSectorHit() {
    final double dx = local.dx - center.dx;
    final double dy = local.dy - center.dy;
    final double rad = m.atan2(dy, dx);
    final double deg = (rad * 180 / m.pi + 90 + 360) % 360;
    final ({double fraction, bool inGap}) hit =
        PhoneRingDialMath.fractionForInnerClock(deg);
    if (hit.inGap) return const _Hit(_HitRegion.dead, 0, 0);
    // VM chunks by file count with no cap (matches the equal-arc painter);
    // single media is 1:1 with the block model (maxBlocks == kMaxInnerSlots),
    // the 11-slot cap remains as a defensive guard.
    final int slots = PhoneRingDialMath.chunkSlotCount(blockCount, isVm: isVm);
    final double t = hit.fraction * slots;
    final int sector = t.floor().clamp(0, slots - 1).toInt();
    final double sectorFraction = (t - sector).clamp(0.0, 1.0);
    return _Hit(_HitRegion.chunk, sector, sectorFraction);
  }

  bool progressHit() => PhoneRingDialMath.progressBandHit(dist, progressR);

  // Keep physical outer priority (corners already handled).
  if (chunkIsOuter) {
    if (chunkHit()) return chunkSectorHit();
    if (progressHit()) return const _Hit(_HitRegion.progress, 0, 0);
  } else {
    if (progressHit()) return const _Hit(_HitRegion.progress, 0, 0);
    if (chunkHit()) return chunkSectorHit();
  }
  if (dist <= g.centerHitR) {
    return const _Hit(_HitRegion.center, 0, 0);
  }
  return const _Hit(_HitRegion.dead, 0, 0);
}

class _DialOverlays extends StatelessWidget {
  const _DialOverlays({
    required this.diameter,
    required this.accent,
    required this.currentText,
    required this.totalText,
    this.subCurrentText,
    this.subTotalText,
    required this.randomReady,
    required this.speedReady,
    required this.speedActive,
    required this.rateLabel,
    required this.midlineIsLeft,
    required this.holdTip,
    required this.transientRate,
    required this.sectorIcons,
    required this.sectorInwardOnLeft,
    required this.centerHitR,
    required this.centerGapRadius,
  });

  final double diameter;
  final Color accent;
  final String currentText;
  final String totalText;

  /// B-scheme sub rows (null = non-VM / single-segment / unknown duration).
  final String? subCurrentText;
  final String? subTotalText;
  final bool randomReady;
  final bool speedReady;

  /// Fixed-speed toggle ON — any "faster than 1x" state must be unmistakable
  /// (filled accent disc behind the icon).
  final bool speedActive;
  final String rateLabel;

  /// Whether the screen-centreline side of the dial is to the LEFT (right-
  /// handed layout). The persistent rate label sits on that side of the
  /// speed corner so it never hangs over the outer screen edge.
  final bool midlineIsLeft;

  /// Corner index currently long-pressed (its tooltip is rendered by the
  /// parent Stack layer, which knows about ring shifts) — null when idle.
  final int? holdTip;
  final double transientRate;

  /// Resolved sector hint icons (null = leave empty), keyed by logical zone.
  final Map<CenterZone, IconData?> sectorIcons;

  /// Screen side of the logical inward sector, from the panel anchor.
  final bool sectorInwardOnLeft;

  /// Parent-geometry hit radius + readout hole the icon orbit is derived from.
  /// The overlay's own default geometry is NOT used: the parent sizes rings
  /// with custom factors, so it passes the real numbers down.
  final double centerHitR;
  final double centerGapRadius;

  /// Center readout styles. Shared with the 45° sector-X hole measurement in
  /// [PhoneRingDialScrubber.build] so the laid-out text and the lines that
  /// dodge it can never drift apart; only the layout-relevant fields matter
  /// for the measurement, the color keeps the `Text` rendering identical.
  static TextStyle currentStyle(Color accent) =>
      TextStyle(fontSize: 16, color: accent);

  static TextStyle totalStyle(Color accent) =>
      TextStyle(fontSize: 15, color: accent.withValues(alpha: 0.75));

  static TextStyle subStyle(Color accent) =>
      TextStyle(fontSize: 11, height: 1.1, color: accent.withValues(alpha: 0.6));

  @override
  Widget build(BuildContext context) {
    final RingDialGeometry g = PhoneRingDialMath.dialGeometry(
      size: Size.square(diameter),
    );
    const double iconSize = PhoneRingDialScrubber._kCornerIconSize;
    final Color onAccent =
        accent.computeLuminance() > 0.5 ? Colors.black87 : Colors.white;

    /// Plain corner icon (bottom-left random). The top-right speed corner
    /// additionally carries a persistent rate label on the screen-centreline
    /// side — the CURRENT rate must be readable without any long-press, and
    /// a label hanging past the corner disc gets clipped by the dial bounds.
    Widget cornerIcon(
      int q,
      IconData icon,
      bool enabled, {
      bool active = false,
      String? rateLabel,
    }) {
      final Offset cc = g.cornerCenters[q];
      return Positioned(
        key: q == 1
            ? const ValueKey<String>('ring-dial-corner-speed')
            : null,
        left: cc.dx - 17,
        top: cc.dy - 17,
        width: 34,
        height: 34,
        child: Stack(
          clipBehavior: Clip.none,
          children: <Widget>[
            Container(
              width: 34,
              height: 34,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: active ? accent : Colors.transparent,
              ),
              child: Icon(
                icon,
                size: iconSize,
                color: !enabled
                    ? Colors.white24
                    : active
                        ? onAccent
                        : Colors.white.withValues(alpha: 0.92),
              ),
            ),
            if (rateLabel != null)
              Positioned.fill(
                child: Align(
                  alignment: midlineIsLeft
                      ? Alignment.centerLeft
                      : Alignment.centerRight,
                  // Shift by the label's own width so it hugs the disc edge.
                  child: FractionalTranslation(
                    translation:
                        Offset(midlineIsLeft ? -1.0 : 1.0, 0),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 3),
                      child: Text(
                        rateLabel,
                        style: TextStyle(
                          fontSize: 10,
                          height: 1,
                          color: active ? Colors.white : Colors.white70,
                          shadows: const <Shadow>[
                            Shadow(blurRadius: 3, color: Colors.black54),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      );
    }

    return Stack(children: <Widget>[
      // Only the one-handed-reachable corners host controls: top-right
      // speed toggle, bottom-left random jump. Top-left / bottom-right stay
      // empty (no paint, no hit — see _classify).
      cornerIcon(2, Icons.casino_outlined, randomReady),
      cornerIcon(
        1,
        Icons.speed_rounded,
        speedReady,
        active: speedActive,
        rateLabel: rateLabel,
      ),
      Center(
        child: Column(mainAxisSize: MainAxisSize.min, children: <Widget>[
          // Current position reads one pixel larger than the total.
          Text(currentText, style: currentStyle(accent)),
          // B-scheme sub rows: smaller/dimmer, omitted when inactive so the
          // layout collapses exactly to the legacy two rows.
          if (subCurrentText != null)
            Text(subCurrentText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: subStyle(accent)),
          Text(totalText, style: totalStyle(accent)),
          if (subTotalText != null)
            Text(subTotalText!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: subStyle(accent)),
        ]),
      ),
      // Sector hint icons on the X arms' free span; `none` sectors stay empty.
      CenterZoneSectorIcons(
        center: g.center,
        orbitRadius: centerZoneIconOrbitRadius(
          hitRadius: centerHitR,
          gapRadius: centerGapRadius,
        ),
        icons: sectorIcons,
        inwardOnLeft: sectorInwardOnLeft,
      ),
    ]);
  }
}

class _DialPainter extends CustomPainter {
  const _DialPainter({
    required this.previewMs,
    required this.durationMs,
    required this.bufferMs,
    required this.blockCount,
    required this.accent,
    required this.palette,
    required this.geometry,
    required this.assignment,
    this.showChunk = true,
    this.vmItem,
    this.vmMarks,
    this.vmTickColor,
    this.vmTickExtent = kVmTickExtentDefaultPx,
    this.vmFailedColor,
    this.windowFloorFraction,
    this.windowCeilingFraction,
    this.centerGapRadius = 0,
  });

  final double previewMs;
  final double durationMs;
  final double bufferMs;
  final int blockCount;
  final Color accent;
  final RingDialPalette palette;
  final RingDialGeometry geometry;
  final RingDialAssignment assignment;

  /// 仅当前 + 高同步 bg playable window, as whole-file fractions; null when the
  /// window covers the whole file (draw NO marks — the "不要画" case). Painted
  /// as two radial ticks on the chunk ring plus a dim over the unreachable
  /// regions.
  final double? windowFloorFraction;
  final double? windowCeilingFraction;

  /// Requirement #8: false = short video with the hide-unchunked opt-in —
  /// the chunk wayfinding ring (and its thumb / VM marks) is not painted.
  final bool showChunk;

  /// The active Virtual Media item driving VM-specific partitioning. When non
  /// null the dial treats each video file as one EQUAL block: the progress ring
  /// maps the CURRENT file's local 0–100%, and the chunk ring renders one equal
  /// sector per file (blockCount == segments.length).
  final VirtualMediaItem? vmItem;

  /// Virtual-media segment marks; painted on the chunk ring (the band mapping
  /// the full timeline, now swappable). Null when no VM session is active.
  final VmScrubberMarks? vmMarks;
  final Color? vmTickColor;

  /// Per-side reach of each boundary tick past the chunk-ring centreline, from
  /// `virtualmedia.markTickExtent` — the same value the linear slider and the
  /// circle slider read, so the one setting drives all three surfaces.
  final int vmTickExtent;

  final Color? vmFailedColor;

  /// Radius of the hole the 45° sector X leaves over the center readout, from
  /// [centerZoneGapRadius]. 0 = no readout, full X.
  final double centerGapRadius;

  @override
  void paint(Canvas canvas, Size size) {
    final RingDialGeometry g = geometry;
    final Offset c = g.center;
    final double safeDur = m.max(1.0, durationMs);
    // ── Block model ─────────────────────────────────────────────────────
    // Real single file: time-derived uniform blocks (blockCount blocks of
    // equal duration). Virtual media: every real video file is ONE block of
    // EQUAL arc length, so the block the cursor sits in IS the current file
    // and the progress fraction is the file's local 0–100%.
    final VirtualMediaItem? vm = vmItem;
    final int idx = vm != null
        ? vm.locate(previewMs.round()).$1
        : ((previewMs / safeDur) * blockCount).floor().clamp(0, blockCount - 1);
    // 外环逐块旋转不变量：每块起点 = (-30°·idx) mod 360，固定 330°（scheme A），
    // 中段 360° 全圆已废弃 — 缺口本身即"第几块"的视觉编码，首/末不再特殊。
    final double blockMs = vm != null
        ? (vm.segments[idx].durationMs ?? 1).toDouble().clamp(1.0, double.infinity)
        : safeDur / blockCount;
    final double blockIdxMs =
        (vm != null
                ? previewMs - vm.offsetOf(idx)
                : previewMs - idx * blockMs)
            .clamp(0.0, blockMs);
    final double f = (blockIdxMs / blockMs).clamp(0.0, 1.0).toDouble();

    final bool isChunkInner = assignment == RingDialAssignment.innerChunk;
    final double progressR = isChunkInner ? g.outerR : g.innerR;
    final double chunkR = isChunkInner ? g.innerR : g.outerR;

    // ── Progress ring: CURRENT block (thin, 4px) — swappable radius
    // Why 逐块 330°: 见 phone_ring_dial_math.dart 外环不变量；Boundary: 任意
    // idx 的死区 [start+330°, start+360°) 均判定 inGap → tap null、drag clamp。
    final Rect progressRect = Rect.fromCircle(center: c, radius: progressR);
    final Paint track = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = PhoneRingDialMath.kOuterBandW
      ..strokeCap = StrokeCap.round;
    final double sweepDeg = PhoneRingDialMath.outerSweepClockForBlock(idx);
    final double startDeg = PhoneRingDialMath.outerStartClockForBlock(idx);
    // Canvas spans come pre-shifted (-90 deg): drawArc measures from the
    // +x axis while these values speak clock degrees (see outerArcRadForBlock).
    final ({double startRad, double sweepRad}) outerArc =
        PhoneRingDialMath.outerArcRadForBlock(idx);

    Color bgTrack;
    Color nowColor;
    if (blockCount <= 1) {
      bgTrack = accent.withValues(alpha: 0.27); // accent.withAlpha(70)
      nowColor = accent;
    } else {
      // Previous block hue as dim background, current hue as "now".
      final Color prevHue = idx > 0
          ? dialBlockColor(palette, idx - 1)
          : accent;
      final Color curHue = dialBlockColor(palette, idx);
      bgTrack = prevHue.withValues(alpha: idx == 0 ? 0.27 : 0.22);
      nowColor = curHue;
    }
    // Inactive track (full block span).
    track.color = bgTrack;
    canvas.drawArc(progressRect, outerArc.startRad, outerArc.sweepRad, false, track);

    // Buffer inside the current block beyond the watched tip. For VM the
    // virtual total buffer is translated to the current file's local span.
    final double blockBufMs =
        (vm != null ? bufferMs - vm.offsetOf(idx) : bufferMs - idx * blockMs)
            .clamp(0.0, blockMs)
            .toDouble();
    final double bufFrac = (blockBufMs / blockMs).clamp(0.0, 1.0).toDouble();
    if (bufFrac > f + 1e-9) {
      final Color bufCol = blockCount <= 1
          ? accent.withValues(alpha: 0.47)
          : nowColor.withValues(alpha: 0.45);
      track.color = bufCol;
      canvas.drawArc(
        progressRect,
        outerArc.startRad + outerArc.sweepRad * f,
        outerArc.sweepRad * (bufFrac - f),
        false,
        track,
      );
    }

    if (f > 1e-9) {
      track.color = nowColor.withValues(alpha: 0.87);
      canvas.drawArc(
          progressRect, outerArc.startRad, outerArc.sweepRad * f, false, track);
    }

    final Offset thumb = _pointAtClock(c, progressR, startDeg + sweepDeg * f);
    _paintHandleDot(canvas, thumb);

    // ── Chunk ring: block wayfinding SLOTS on the level-1 domain
    // (arc starts at 12 o'clock, sweeps 330°, notch sits at 11–12 o'clock).
    // Real media is 1:1 with the block model (maxBlocks == kMaxInnerSlots), so
    // each slot takes the hue of its own block; the ≤11 aggregation path is a
    // defensive guard for an out-of-range raw count only.
    // Stroke follows function (7px for chunk), radius follows assignment.
    // Requirement #8: skipped entirely for short videos with the opt-in.
    if (showChunk) {
      _paintChunk(canvas, c, chunkR, previewMs, bufferMs,
          durationMs, blockCount, accent, palette);
      _paintBgWindow(canvas, c, chunkR);
      // Chunk ring 缺口: total block count (how many files/blocks in total).
      // Level-1 band is pinned with its notch at 11→12, gap centre 345°.
      _paintGapLabel(
        canvas,
        text: '$blockCount',
        center: c,
        radius: chunkR,
        clockDeg: PhoneRingDialMath.gapCenterClockForBlock(0),
      );
    }

    // Progress ring 缺口: which ring/lap the cursor currently sits on
    // (1-based), at the rotating notch of the current block.
    _paintGapLabel(
      canvas,
      text: '${idx + 1}',
      center: c,
      radius: progressR,
      clockDeg: PhoneRingDialMath.gapCenterClockForBlock(idx),
    );

    _paintCenterZoneX(canvas, c, g.centerHitR);
  }

  /// Faint 45° X inside the centre hit circle, marking the four tap sectors.
  /// Four independent arms around [centerGapRadius]: the outer ends keep the
  /// sector hint on the hit-circle edge, the middle stays clear of the center
  /// time readout (see [paintCenterZoneX]). Low alpha by design: a
  /// reachability hint over live video, not decoration.
  void _paintCenterZoneX(Canvas canvas, Offset c, double r) {
    paintCenterZoneX(
      canvas,
      center: c,
      radius: r,
      gapRadius: centerGapRadius,
    );
  }

  /// 仅当前 + 高同步: marks the published bg playable window on the
  /// full-timeline chunk band — the unreachable regions are dimmed and both
  /// edges get a radial tick, so a seek that stops at them reads as a limit
  /// rather than a broken scrub. No-op when the window is null or full.
  void _paintBgWindow(Canvas canvas, Offset c, double chunkR) {
    final double? lo = windowFloorFraction;
    final double? hi = windowCeilingFraction;
    if (lo == null || hi == null) return;
    if (lo <= 0 && hi >= 1) return;
    final ({double startRad, double sweepRad}) arc =
        PhoneRingDialMath.innerArcRad;
    final Rect band = Rect.fromCircle(center: c, radius: chunkR);
    final Paint dim = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = PhoneRingDialMath.kInnerBandW + 2
      ..strokeCap = StrokeCap.butt
      ..color = Colors.black.withValues(alpha: 0.5);
    if (lo > 0) {
      canvas.drawArc(band, arc.startRad, lo * arc.sweepRad, false, dim);
    }
    if (hi < 1) {
      canvas.drawArc(
        band,
        arc.startRad + hi * arc.sweepRad,
        (1 - hi) * arc.sweepRad,
        false,
        dim,
      );
    }
    final Paint tick = Paint()
      ..strokeWidth = 2
      ..color = Colors.white.withValues(alpha: 0.85);
    final double halfBand = PhoneRingDialMath.kInnerBandW / 2;
    for (final double f in <double>[lo, hi]) {
      final double rad = arc.startRad + f * arc.sweepRad;
      final Offset dir = Offset(m.cos(rad), m.sin(rad));
      canvas.drawLine(
        c + dir * (chunkR - halfBand - 3),
        c + dir * (chunkR + halfBand + 3),
        tick,
      );
    }
  }

  /// Filled white thumb over a soft dark halo. The drag handle must pop
  /// against both the ring bands and live video, whatever the palette says,
  /// so its color is fixed ([kDialHandleColor]) rather than sampled from the
  /// current block hue.
  void _paintHandleDot(Canvas canvas, Offset center) {
    canvas.drawCircle(
      center,
      7,
      Paint()
        ..color = Colors.black.withValues(alpha: 0.45)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
    canvas.drawCircle(center, 5, Paint()..color = kDialHandleColor);
  }

  /// Draws a numeric label centred inside a ring's 30° dead wedge (缺口),
  /// placed at the wedge midpoint on that ring's band. Always white with a
  /// dark shadow — the wedge number is part of the drag affordance.
  void _paintGapLabel(
    Canvas canvas, {
    required String text,
    required Offset center,
    required double radius,
    required double clockDeg,
  }) {
    final TextPainter tp = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: text,
        style: const TextStyle(
          fontSize: 15,
          height: 1,
          fontWeight: FontWeight.w600,
          color: kDialHandleColor,
          shadows: kDialHandleShadows,
        ),
      ),
    )..layout();
    final Offset pos = _pointAtClock(center, radius, clockDeg);
    tp.paint(
      canvas,
      pos - Offset(tp.width / 2, tp.height / 2),
    );
  }

  void _paintChunk(
    Canvas canvas,
    Offset c,
    double chunkR,
    double previewMs,
    double bufferMs,
    double durationMs,
    int blockCount,
    Color accent,
    RingDialPalette palette,
  ) {
    final double safeDur = m.max(1.0, durationMs);
    final ({double startRad, double sweepRad}) innerArc =
        PhoneRingDialMath.innerArcRad;
    final Rect chunkRect = Rect.fromCircle(center: c, radius: chunkR);
    final double posGlobal = (previewMs / safeDur).clamp(0.0, 1.0).toDouble();
    final double bufGlobal = (bufferMs / safeDur).clamp(0.0, 1.0).toDouble();
    final VirtualMediaItem? vm = vmItem;
    if (vm != null) {
      // Virtual media: one EQUAL sector per real file. The cursor maps onto
      // the equal-arc index space (idx + file-local fraction) / count, so a
      // sector's fill tracks how far through its own arc the cursor sits —
      // the precision trade-off of continuous cross-file viewing (spec).
      // Per-file 0–100% lives on the progress ring.
      final int count = vm.segments.length;
      final double sectorRad = innerArc.sweepRad / count;
      final (int curIdx, _, double posEqual) =
          PhoneRingDialMath.vmEqualFraction(vm, previewMs.round());
      final double bufEqual = vm.segments.isEmpty
          ? 0.0
          : PhoneRingDialMath.vmEqualFraction(vm, bufferMs.round()).$3;
      for (int i = 0; i < count; i++) {
        final double a0 = innerArc.startRad + i * sectorRad;
        final Paint p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = PhoneRingDialMath.kInnerBandW;
        final Color col = dialBlockColor(palette, i);
        final double fill = (posEqual * count - i).clamp(0.0, 1.0).toDouble();
        final bool watched = fill >= 1.0;
        final bool isCurrent = curIdx == i;
        p.color = col.withValues(alpha: watched ? 0.80 : 0.13);
        canvas.drawArc(chunkRect, a0, sectorRad, false, p);

        if (isCurrent) {
          final double bufFill =
              (bufEqual * count - i).clamp(fill, 1.0).toDouble();
          if (bufFill > fill) {
            p.color = Colors.white.withValues(alpha: 0.24);
            canvas.drawArc(chunkRect, a0, sectorRad * bufFill, false, p);
          }
          if (fill > 1e-9) {
            p.color = col;
            canvas.drawArc(chunkRect, a0, sectorRad * fill, false, p);
          }
        } else if (!watched) {
          final double bFill =
              (bufEqual * count - i).clamp(0.0, 1.0).toDouble();
          if (bFill > 1e-9 && bFill < 1.0) {
            p.color = Colors.white.withValues(alpha: 0.18 * bFill);
            canvas.drawArc(chunkRect, a0, sectorRad * bFill, false, p);
          }
        }
      }
      _paintChunkThumb(canvas, c, chunkR, posEqual);
      _paintVmChunkMarks(canvas, c, chunkR);
      return;
    } else {
      final int slots = PhoneRingDialMath.innerSlotCount(blockCount);
      final double sectorRad = innerArc.sweepRad / slots;
      final int curSlot =
          (posGlobal * slots).floor().clamp(0, slots - 1);
      for (int i = 0; i < slots; i++) {
        final double a0 = innerArc.startRad + i * sectorRad;
        final int firstBlock = i * blockCount ~/ slots;
        final Paint p = Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = PhoneRingDialMath.kInnerBandW;
        final Color col = dialBlockColor(palette, firstBlock);
        final double fill = (posGlobal * slots - i).clamp(0.0, 1.0).toDouble();
        final bool watched = fill >= 1.0;
        p.color = col.withValues(alpha: watched ? 0.80 : 0.13);
        canvas.drawArc(chunkRect, a0, sectorRad, false, p);

        if (i == curSlot) {
          final double bufFill = (bufGlobal * slots - i).clamp(fill, 1.0).toDouble();
          if (bufFill > fill) {
            p.color = Colors.white.withValues(alpha: 0.24);
            canvas.drawArc(chunkRect, a0, sectorRad * bufFill, false, p);
          }
          if (fill > 1e-9) {
            p.color = col;
            canvas.drawArc(chunkRect, a0, sectorRad * fill, false, p);
          }
        } else if (!watched) {
          final double bFill = (bufGlobal * slots - i).clamp(0.0, 1.0).toDouble();
          if (bFill > 1e-9 && bFill < 1.0) {
            p.color = Colors.white.withValues(alpha: 0.18 * bFill);
            canvas.drawArc(chunkRect, a0, sectorRad * bFill, false, p);
          }
        }
      }
    }

    // Chunk floating thumb dot (whole timeline). 100% lands on arc end at 11 o'clock.
    _paintChunkThumb(canvas, c, chunkR, posGlobal);

    _paintVmChunkMarks(canvas, c, chunkR);
  }

  /// Floating thumb dot on the chunk band: [fraction] is the duration-weighted
  /// global fraction for single media, the equal-division fraction for VM.
  void _paintChunkThumb(
    Canvas canvas,
    Offset c,
    double chunkR,
    double fraction,
  ) {
    final double chunkThumbClock =
        PhoneRingDialMath.arcStartClockForLevel(1) +
            fraction * PhoneRingDialMath.kRingLevelSweepDeg;
    final Offset chunkThumb = _pointAtClock(c, chunkR, chunkThumbClock);
    _paintHandleDot(canvas, chunkThumb);
  }

  /// VM segment decoration on the chunk (full-timeline) band: red arcs over
  /// probe-failed segments, then lengthened radial ticks at every boundary.
  ///
  /// Geometry source: when [vmItem] is set the dial partitions by FILE COUNT
  /// (equal arcs), so every boundary sits at i/count and each failed segment
  /// spans its own equal sector [i/count,(i+1)/count] — computed here from the
  /// item, NOT from the duration-weighted [vmMarks]. The duration-weighted
  /// marks are only a legacy fallback for VMs without a live item.
  void _paintVmChunkMarks(Canvas canvas, Offset c, double chunkR) {
    final vm = vmItem;
    final ({double startRad, double sweepRad}) arc =
        PhoneRingDialMath.innerArcRad;
    final Rect band = Rect.fromCircle(center: c, radius: chunkR);

    final List<double> boundaries = vm != null
        ? <double>[
            for (var i = 1; i < vm.segments.length; i++)
              PhoneRingDialMath.vmSectorFraction(i, vm.segments.length),
          ]
        : (vmMarks?.boundaries ?? const <double>[]);
    final List<({double start, double end})> failed = vm != null
        ? <({double start, double end})>[
            for (var i = 0; i < vm.segments.length; i++)
              if (vm.segments[i].durationEstimated)
                (
                  start: PhoneRingDialMath.vmSectorFraction(i, vm.segments.length),
                  end: PhoneRingDialMath.vmSectorFraction(i + 1, vm.segments.length),
                ),
          ]
        : (vmMarks?.failedSpans ?? const []);

    if (vmFailedColor != null && failed.isNotEmpty) {
      final Paint failedPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = PhoneRingDialMath.kInnerBandW + 2
        ..strokeCap = StrokeCap.butt
        ..color = vmFailedColor!;
      for (final span in failed) {
        canvas.drawArc(
          band,
          arc.startRad + span.start * arc.sweepRad,
          (span.end - span.start) * arc.sweepRad,
          false,
          failedPaint,
        );
      }
    }

    if (vmTickColor != null && boundaries.isNotEmpty) {
      final Paint tick = Paint()
        ..strokeWidth = 2
        ..color = vmTickColor!;
      for (final f in boundaries) {
        final double rad = arc.startRad + f * arc.sweepRad;
        final ({Offset from, Offset to}) span =
            PhoneRingDialMath.vmChunkTickSpan(
          center: c,
          radius: chunkR,
          angleRad: rad,
          extentPx: vmTickExtent,
        );
        canvas.drawLine(span.from, span.to, tick);
      }
    }
  }

  static double _deg2rad(double deg) => deg * m.pi / 180;

  static Offset _pointAtClock(Offset c, double radius, double clockDeg) {
    final double rad = _deg2rad(clockDeg) - m.pi / 2;
    return c + Offset(radius * m.cos(rad), radius * m.sin(rad));
  }

  @override
  bool shouldRepaint(_DialPainter old) =>
      old.previewMs != previewMs ||
      old.durationMs != durationMs ||
      old.bufferMs != bufferMs ||
      old.blockCount != blockCount ||
      old.accent != accent ||
      old.palette != palette ||
      old.assignment != assignment ||
      old.showChunk != showChunk ||
      !identical(old.vmItem, vmItem) ||
      !identical(old.vmMarks, vmMarks) ||
      old.vmTickColor != vmTickColor ||
      old.vmTickExtent != vmTickExtent ||
      old.vmFailedColor != vmFailedColor ||
      old.windowFloorFraction != windowFloorFraction ||
      old.windowCeilingFraction != windowCeilingFraction ||
      old.centerGapRadius != centerGapRadius ||
      old.geometry.outerR != geometry.outerR ||
      old.geometry.innerR != geometry.innerR;
}

Duration _clamp(Duration candidate, Duration duration) {
  if (candidate < Duration.zero) return Duration.zero;
  if (candidate > duration) return duration;
  return candidate;
}

/// VM progress-ring tap: the angle fraction inside the CURRENT file maps onto
/// that file's real span (the painter's inverse). Gap taps return null.
Duration? _vmPositionForOuterTap({
  required Offset local,
  required Offset center,
  required int fileIndex,
  required VirtualMediaItem vmItem,
}) {
  final double rad = m.atan2(local.dy - center.dy, local.dx - center.dx);
  final double clockDeg = (rad * 180 / m.pi + 90 + 360) % 360;
  final ({double fraction, bool inGap}) hit =
      PhoneRingDialMath.fractionForOuterClock(clockDeg, fileIndex);
  if (hit.inGap) return null;
  return Duration(
    milliseconds: PhoneRingDialMath.vmVirtualForOuterFraction(
      item: vmItem,
      index: fileIndex,
      fraction: hit.fraction,
    ),
  );
}

/// VM chunk-ring drag: absolute equal-division angle guarded by the shared
/// quadrant edge-lock (Q1↔Q2 stick at the virtual ends), mapped back onto
/// the tapped file's real span so the preview tracks the equal-arc thumb.
Duration _vmPositionForChunkDrag({
  required double dx,
  required double dy,
  required double clockDeg,
  required VirtualMediaItem vmItem,
  required InnerEdgeLockSession lock,
}) {
  final double eq = lock.applyEqualFraction(
    dx: dx,
    dy: dy,
    clockDeg: clockDeg,
  );
  return Duration(
    milliseconds: PhoneRingDialMath.vmVirtualForEqualFraction(vmItem, eq),
  );
}
