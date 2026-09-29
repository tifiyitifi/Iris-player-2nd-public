import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/model/domain/background_mapping.dart';
import 'package:iris/features/background_playback/model/domain/segment_edit_draft.dart';
import 'package:iris/features/background_playback/model/enum/align_ring_assignment.dart';
import 'package:iris/features/background_playback/model/enum/bg_sticky_consume.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/model/enum/mapping_action.dart';
import 'package:iris/features/background_playback/resolver/fg_display_window.dart';
import 'package:iris/features/background_playback/resolver/segment_snap.dart';
import 'package:iris/features/background_playback/resolver/segment_span_math.dart';
import 'package:iris/features/background_playback/rule/segment_color.dart';
import 'package:iris/features/background_playback/services/editor_audition_logic.dart';
import 'package:iris/features/background_playback/store/use_apb_edit_session_store.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/segment_abp_slider.dart';
import 'package:iris/features/background_playback/view/segment_dual_ring_dial.dart';
import 'package:iris/features/background_playback/view/segment_edit_button_bar.dart';
import 'package:iris/features/background_playback/view/segment_edit_context.dart';
import 'package:iris/features/background_playback/view/segment_edit_save.dart';
import 'package:iris/features/background_playback/view/segment_color_dialog.dart';
import 'package:iris/features/virtual_media/interaction/controller/foreground_window_resolver.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/features/phone/one_handed_scrubber/controller/sideway_panel_layout.dart';
import 'package:iris/globals.dart' show apbEditorPanelKeyNotifier;
import 'package:iris/hooks/use_published_global_key.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/format_duration_hms.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/dialogs/show_confirm_suppressible_dialog.dart';
import 'package:provider/provider.dart';

/// Minimum interval between live 副音 seeks while the editor is open. A decoder
/// seek per pointer tick is what made the timeline drag stutter, and seeking
/// the 副音 decoder several times a second made its PICTURE stutter too — this
/// is coarse enough to leave the decoder headroom while editing.
const Duration _kEditorBgSeekInterval = Duration(milliseconds: 300);

// DIAL_DEBUG_LOG: temporary diagnostics for the ring-drag investigation (see
// `kDialDebugLogs`). The fine-grained per-tick logs are OFF (they flooded the
// log and slowed the app); the transport path below keeps a small, focused
// trace because play/pause is still misbehaving in the editor.
const bool kDialDebugLogsPanel = false;

// TRANSPORT_DEBUG_LOG: one short trace per play/pause press in the editor.
const bool kTransportDebugLogs = false;

/// The fb/bg align editor mounted IN PLACE of the control bar.
///
/// Leaving normal playback for a dedicated editing state: the pair is locked
/// (no list jump / no next episode), play-pause and linked seeking remain, and
/// the panel is always visible. It renders either the linear bar (desktop /
/// tablet / phone portrait) or, for the side type, the SAME `CircleSliderLayout`
/// scaffold the normal bar uses — so the panel size and the ring centre never
/// jump when the editor opens.
///
/// Both surfaces drive the SAME shared rules (see `SegmentSpanMath`):
/// A/B resize the usable foreground range, P sets the ALIGNMENT (which bg
/// content plays at a given fg position) and therefore re-clamps that range.
/// Overlaps are allowed — the save path resolves them last-activated-wins.
///
/// PERFORMANCE: a drag keeps its live span in a LOCAL [ValueNotifier] and only
/// commits to the store on release, so a 60 Hz gesture never notifies the
/// global store.
///
/// VM: the editor edits ONE PHYSICAL foreground file against ONE real 副音 file.
/// Entering installs the foreground as the single item of a transient workspace
/// (see `ApbEditContext`), so a Virtual Media merge is not in play; every
/// position/duration here is the VM-undone physical window
/// (`ForegroundWindow`), never the merged virtual timeline. A VM segment is a
/// separate mapping target, not part of one virtual axis.
class SegmentAlignEditPanel extends HookWidget {
  const SegmentAlignEditPanel({
    super.key,
    required this.isSide,
    this.color,
    this.overlayColor,
    this.showControl,
  });

  final bool isSide;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;
  final VoidCallback? showControl;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final bg = useBackgroundPlaybackStore();
    final ctx = useSegmentEditContext(context);
    final fgPlayer = context.read<MediaPlayer>();
    // Commands only — subscribing to the whole engine would rebuild this panel
    // on every position/transport notification.
    final engine = context.read<BackgroundPlaybackEngine>();
    final bgDurMs = context.select<BackgroundPlaybackEngine, int>(
      (e) => e.duration.inMilliseconds,
    );
    // NOTE: no fg/bg POSITION is selected here. A per-tick position would
    // rebuild this panel AND the button bar on every playback tick; the
    // surfaces that paint a position (the dial, the linear rows) subscribe in
    // their own leaf, and handlers read it at event time.

    final isPlaying = context.select<MediaPlayer, bool>((p) => p.isPlaying);
    // Transport of the PAIR (either runtime running counts as "playing").
    final bgIsPlaying =
        context.select<BackgroundPlaybackEngine, bool>((e) => e.isPlaying);
    final fgDurMs = ctx.fgDurMs;
    final int seekStep = useAppStore().select(context, (s) => s.seekStepSeconds);
    final int minSpanMs = bg.select(context, (s) => s.minSegmentSpanMs);
    final bool pKeepMaxLength =
        bg.select(context, (s) => s.pAlignKeepMaxLength);
    final BgStickyConsume stickyConsume =
        bg.select(context, (s) => s.stickyConsume);
    final double fgWindowZoom = bg.select(context, (s) => s.fgWindowZoom);
    final bool fgWindowPushBg = bg.select(context, (s) => s.fgWindowPushBg);

    final draft = ctx.draft;
    final bool snapEnabled = bg.select(context, (s) => s.snapEnabled);
    final int snapReleaseLimit =
        bg.select(context, (s) => s.snapReleaseLimit);

    // Snap-to-saved-boundary (卡值) session: usable walls from the fg-drawn
    // winners, a bounded release memory, and the per-gesture hit record.
    // Session-only — never persisted and never part of the draft. Cleared on
    // toggle / draft change so a stale release never leaks into a fresh edit.
    final snapWalls = useMemoized(
      () => snapEnabled
          ? SegmentSnap.wallsFromSlices(ctx.resolvedSlices, fgDurMs: fgDurMs)
          : const <int>[],
      [snapEnabled, ctx.resolvedSlices, fgDurMs],
    );
    final snapMemory = useMemoized(
      () => SegmentSnapMemory(snapReleaseLimit),
      const <Object?>[],
    );
    if (snapMemory.capacity != snapReleaseLimit) {
      snapMemory.setCapacity(snapReleaseLimit);
    }
    // The in-flight handle gesture under snap (null when idle). It owns the
    // release snapshot plus the same-gesture hold, and records the walls to
    // release on tap-up.
    final snapSession = useRef<SnapDragSession?>(null);
    // Repaint latch for the wall overlay: a hit-and-return leaves the draft
    // untouched, so no store notification would refresh the drawing. Bumped
    // whenever the release memory changes.
    final snapVersion = useState(0);
    // A different draft, or a snap toggle, clears every release. (No version
    // bump here: both already rebuild this panel through the store/context,
    // and notifying state mid-build is illegal. The bump lives in the event
    // handlers that mutate the memory outside of build.)
    final snapScope = useRef<({int draftId, bool enabled})?>(null);
    final snapScopeNow = (draftId: draft?.editingId ?? 0, enabled: snapEnabled);
    if (snapScope.value != snapScopeNow) {
      snapScope.value = snapScopeNow;
      snapMemory.clear();
      snapSession.value = null;
    }

    final fgOnInner = bg.select(
      context,
      (s) => s.alignRingAssignment == AlignRingAssignment.fgInner,
    );

    // Live drag span: non-null ONLY while a handle gesture is in flight. The
    // alignment drag is computed against the span captured at gesture start
    // (dragRefSpan + dragOffAccum) so re-clamping A/B is never destructive:
    // dragging back restores the previous range.
    final dragSpan = useMemoized(() => ValueNotifier<SegmentSpan?>(null),
        const <Object?>[]);
    useEffect(() => () => dragSpan.dispose(), [dragSpan]);
    final dragRefSpan = useRef<SegmentSpan?>(null);
    final dragOffAccum = useRef<int>(0);
    final wasPlaying = useRef<bool>(false);

    // Session-only APB foreground zoom window start (q). Null = auto (centered
    // on the playhead). Reset whenever a different draft is edited. Held in a
    // notifier so a q pan never rebuilds the panel; the window VALIDATION runs
    // in the leaves, which already track the live playhead.
    final qWindowStart = useMemoized(() => ValueNotifier<int?>(null),
        const <Object?>[]);
    useEffect(() => () => qWindowStart.dispose(), [qWindowStart]);
    final qWindowScope = useRef<int?>(null);
    final int windowScopeId = draft?.editingId ?? 0;
    if (qWindowScope.value != windowScopeId) {
      qWindowScope.value = windowScopeId;
      qWindowStart.value = null;
    }
    // The span captured when a pushBg q drag started, so the alignment slide is
    // accumulated against the gesture reference and stays reversible.
    final qRefSpan = useRef<SegmentSpan?>(null);
    final qWasPlaying = useRef<bool>(false);

    // Sealed user piles for the P pull-away (see
    // `SegmentSpanMath.dragAlignment` seals). Re-seeded whenever a different
    // draft is edited; every committed span change refreshes them (an end
    // sitting on a foreground bound unseals to 0, an interior end keeps its
    // pile). Session-only: never persisted and never part of the draft.
    final sealLead = useRef(0);
    final sealTail = useRef(0);
    final sealScope = useRef<int?>(null);
    final sealBgDur = useRef(0);
    final sealScopeId = draft?.editingId ?? 0;
    if (draft != null &&
        (sealScope.value != sealScopeId ||
            (sealBgDur.value <= 0 && bgDurMs > 0))) {
      sealScope.value = sealScopeId;
      sealBgDur.value = bgDurMs;
      final seals = SegmentSpanMath.sealsFor(draft.span,
          fgDurMs: fgDurMs, bgDurMs: bgDurMs);
      sealLead.value = seals.lead;
      sealTail.value = seals.tail;
    }

    // Segments already saved for the SAME bg file are drawn gray on the bg
    // axis; those on other files cannot share the axis and are omitted.
    final sameBgExisting = useMemoized(
      () {
        if (draft == null || draft.bgPath == null) {
          return const <MappingSegment>[];
        }
        return [
          for (final s in ctx.existing)
            if (s.isPlayMedia && s.bgPath == draft.bgPath) s,
        ];
      },
      [ctx.existing, draft?.bgPath],
    );

    // Throttled live follow of the bg runtime (see _kEditorBgSeekInterval).
    final bgSeek = useMemoized(() => _ThrottledBgSeek(engine), [engine]);
    useEffect(() => () => bgSeek.dispose(), [bgSeek]);

    /// Points the bg runtime at the frame the CURRENT mapping shows for the
    /// foreground playhead. Called on playback/seek AND on every drag tick, so
    /// changing the alignment visibly changes the bg picture at once. Pass
    /// [immediate] for the END of an interaction so the final target lands
    /// without waiting for the throttle.
    void requestLiveBgSeek(SegmentSpan s, {bool immediate = false}) {
      final bgDur = engine.duration.inMilliseconds;
      if (bgDur <= 0) return;
      // NEVER re-seek a PLAYING 副音 to follow the foreground: the 1:1 mapping
      // keeps the two in step by itself, and seeking a decoder several times a
      // second is exactly what made its picture stutter. Adjustments happen
      // while the pair is paused (a drag pauses it), where the exact landing
      // below still applies.
      if (!immediate && engine.isPlaying) return;
      final int fgNow = fgPhysicalPositionNow(context);
      final target = (fgNow + s.bgOffsetMs).clamp(0, bgDur);
      if (immediate) {
        bgSeek.requestNow(target);
      } else {
        bgSeek.request(target);
      }
    }

    /// The current APB foreground zoom window. Computed ON DEMAND (never in the
    /// panel build) so the per-tick playhead is read at event time and the panel
    /// keeps its no-position-subscription contract.
    FgDisplayWindow currentWindow() {
      final d = ctx.draft;
      if (d == null) {
        return FgDisplayWindow(startMs: 0, widthMs: fgDurMs, fgDurMs: fgDurMs);
      }
      final int w = FgDisplayWindowMath.windowWidthMs(
          fgDurMs: fgDurMs, bgDurMs: bgDurMs, zoom: fgWindowZoom);
      final int fgNow = fgPhysicalPositionNow(context);
      return FgDisplayWindowMath.forSpan(
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        zoom: fgWindowZoom,
        pushBg: fgWindowPushBg,
        fgPosMs: fgNow,
        spanStartMs: d.span.fgStartMs,
        spanEndMs: d.span.fgEndMs,
        requestedStartMs: qWindowStart.value ?? (fgNow - w ~/ 2),
      );
    }

    void onSeekFg(int localMs) {
      // While the zoom is active, playback/seek is confined to the visible
      // window; the dot can never leave the ring.
      final FgDisplayWindow w = currentWindow();
      final int target = w.active ? w.clampPlayheadMs(localMs) : localMs;
      fgPlayer.seek(
        Duration(milliseconds: ctx.fgWindow.playerPositionFor(target)),
      );
      // APB keeps fg/bg DIRECTLY in step (the alignment is P's job, not the
      // normal panel's linkage): every foreground scrub drags the 副音 to the
      // same instant through the mapping.
      final d = ctx.draft;
      final bgDur = engine.duration.inMilliseconds;
      if (d != null && bgDur > 0) {
        bgSeek.request((target + d.span.bgOffsetMs).clamp(0, bgDur));
      }
    }

    /// Was the app autoplay flag ON when this scrub started? Restored on release
    /// exactly like the normal ring scrubber's begin/finish pair.
    final scrubWasAutoPlay = useRef<bool>(false);

    /// Ring body-scrub lifecycle (once per gesture — never per tick): hold the
    /// panel and pause the pair while the user scrubs, exactly like the normal
    /// scrubber's `beginScrub`/`finishScrub`.
    void onScrubStart() {
      showControl?.call();
      scrubWasAutoPlay.value = useAppStore().state.autoPlay;
      useAppStore().updateAutoPlay(false);
      fgPlayer.pause();
      bg.setPlaying(false);
      useScrubDragStore().beginSeek(ScrubOwners.alignPanel);
    }

    void onScrubEnd() {
      useScrubDragStore().endSeek(ScrubOwners.alignPanel);
      // The scrub already moved the foreground — land the 副音 frame exactly so
      // the pair is realigned the moment the finger lifts.
      final d = ctx.draft;
      if (d != null) requestLiveBgSeek(d.span, immediate: true);
      // Resume only if playback was running when the scrub began (the ring
      // scrubber's contract); also re-arms the foreground's autoplay flag so the
      // seek cannot be undone by the hook. Inlined because playPair is declared
      // later in this build.
      if (scrubWasAutoPlay.value) {
        useAppStore().updateAutoPlay(true);
        fgPlayer.play();
        // 副音 is joined by the audition driver once the playhead is inside [A,B].
      }
      scrubWasAutoPlay.value = false;
    }

    // While editing, 副音 follows the foreground along the draft's offset. The
    // effect only fires when the ALIGNMENT changes (or on mount): a playing 副音
    // is never re-seeked (the 1:1 mapping keeps the pair in step, and seeking a
    // decoder per tick is what stutters its picture), and an explicit fg scrub
    // lands its own exact seek via onScrubEnd.
    useEffect(() {
      final d = draft;
      if (d == null) return null;
      requestLiveBgSeek(d.span);
      return null;
      // ignore: prefer_const_constructors
    }, [draft?.span.bgOffsetMs, bgDurMs, bgSeek]);

    void pausePair() {
      // Flip the app's autoplay flag WITH the transport. The foreground hook
      // owns its own autoplay/resume effect: with the flag still on it re-plays
      // a stopped player immediately, which is exactly why a bare pause() (and
      // even a seek) appeared to "not work" in the editor.
      useAppStore().updateAutoPlay(false);
      fgPlayer.pause();
      bg.setPlaying(false);
      // Drive the engine too: the store flag alone is a request, and a stale
      // flag (already false) would leave a playing engine running.
      unawaited(engine.pause());
      if (kTransportDebugLogs) {
        debugPrint('TRANSPORT_DEBUG_LOG pausePair bgAutoPlay=${bg.state.bgAutoPlay} '
            'appAutoPlay=${useAppStore().state.autoPlay} '
            'enginePlaying=${engine.isPlaying}');
      }
    }

    void playPair() {
      // 副音 is NOT started here: the foreground is the transport master and the
      // audition driver joins 副音 only once the playhead is inside [A,B].
      useAppStore().updateAutoPlay(true);
      fgPlayer.play();
      if (kTransportDebugLogs) {
        debugPrint('TRANSPORT_DEBUG_LOG playPair bgAutoPlay=${bg.state.bgAutoPlay} '
            'appAutoPlay=${useAppStore().state.autoPlay} '
            'enginePlaying=${engine.isPlaying}');
      }
    }

    void onPlayPause() {
      // Play/pause follows the FOREGROUND (the editor's transport master); the
      // audition driver then starts/stops 副音 from the playhead's [A,B] state.
      // The decision reads the FOREGROUND flag ONLY — the button must reflect
      // the same side it toggles, or a bg-only playing state would show "pause"
      // while the press actually started the foreground.
      final bool playing = fgPlayer.isPlaying;
      if (kTransportDebugLogs) {
        debugPrint('TRANSPORT_DEBUG_LOG press before fg=$isPlaying bg=$bgIsPlaying '
            'bgAutoPlay=${bg.state.bgAutoPlay} action=${playing ? 'pause' : 'play'}');
      }
      if (playing) {
        pausePair();
      } else {
        playPair();
      }
      showControl?.call();
    }

    /// The editor's ± transport: move the FOREGROUND by [seekStep] exactly like
    /// normal playback, then pull 副音 to the mapped instant through the draft
    /// offset. The foreground position/rate is never rewritten (the editor only
    /// commands the existing player API), so the playhead stays consistent with
    /// normal playback; the driver then pauses 副音 outside [A,B].
    void stepRelative({required bool forward}) {
      if (forward) {
        fgPlayer.forward(seekStep);
      } else {
        fgPlayer.backward(seekStep);
      }
      final d = ctx.draft;
      if (d != null) requestLiveBgSeek(d.span, immediate: true);
    }

    /// Refreshes the sealed piles from a freshly committed span: an end on a
    /// foreground bound unseals to 0, an interior end keeps its pile. Every
    /// gesture end (P and A/B alike) funnels through here, so a P gesture can
    /// only spend the new pile above the seal within that gesture.
    void refreshSeals(SegmentSpan s) {
      final seals = SegmentSpanMath.sealsFor(s,
          fgDurMs: fgDurMs, bgDurMs: bgDurMs);
      sealLead.value = seals.lead;
      sealTail.value = seals.tail;
    }

    /// q pan tick: resolve the requested window start, and — when
    /// `bg.fgWindowPushBg` is on — slide the WHOLE alignment over the fixed bg
    /// window by the overflow so the pan may continue past A/B instead of
    /// sticking. The pushed span is kept LOCAL (dragSpan) and committed once on
    /// release. Returns the APPLIED start so the ring dial can hard-stop its
    /// handle at the boundary (see `SegmentDualRingDial.onWindowStartChanged`).
    int onWindowStartChanged(int requestedStart) {
      final d = ctx.draft;
      if (d == null) return requestedStart;
      final SegmentSpan ref = qRefSpan.value ?? d.span;
      final int fgNow = fgPhysicalPositionNow(context);
      final FgDisplayWindow win = FgDisplayWindowMath.forSpan(
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        zoom: fgWindowZoom,
        pushBg: fgWindowPushBg,
        fgPosMs: fgNow,
        spanStartMs: ref.fgStartMs,
        spanEndMs: ref.fgEndMs,
        requestedStartMs: requestedStart,
      );
      int start = win.startMs;
      if (fgWindowPushBg) {
        final int overflow = requestedStart - win.startMs;
        if (overflow != 0) {
          final SegmentSpan pushed = SegmentSpanMath.translateAligned(
            ref,
            overflow,
            fgDurMs: fgDurMs,
            bgDurMs: bgDurMs,
            minSpanMs: minSpanMs,
          );
          if (pushed != ref) {
            dragSpan.value = pushed;
            requestLiveBgSeek(pushed);
            start = FgDisplayWindowMath.forSpan(
              fgDurMs: fgDurMs,
              bgDurMs: bgDurMs,
              zoom: fgWindowZoom,
              pushBg: true,
              fgPosMs: fgNow,
              spanStartMs: pushed.fgStartMs,
              spanEndMs: pushed.fgEndMs,
              requestedStartMs: requestedStart,
            ).startMs;
          }
        }
      }
      qWindowStart.value = start;
      return start;
    }

    /// q drag lifecycle: pause the pair for the gesture, then commit any pushed
    /// span once on release and restore the play state (mirrors the A/B drag).
    void onWindowDragActive(bool active) {
      if (active) {
        qRefSpan.value = ctx.draft?.span;
        qWasPlaying.value = fgPlayer.isPlaying || engine.isPlaying;
        if (qWasPlaying.value) pausePair();
        return;
      }
      final SegmentSpan? live = dragSpan.value;
      dragSpan.value = null;
      final SegmentSpan? ref = qRefSpan.value;
      qRefSpan.value = null;
      final d = ctx.draft;
      if (d != null && live != null && ref != null && live != d.span) {
        bg.updateSegmentEditDraft(d.copyWith(span: live));
        refreshSeals(live);
      }
      final SegmentSpan? settle = live ?? d?.span;
      if (settle != null) requestLiveBgSeek(settle, immediate: true);
      if (qWasPlaying.value) playPair();
      qWasPlaying.value = false;
    }

    /// Discrete span change (the move-to-current buttons): goes straight to the
    /// store and must LAND. Overlaps are allowed — the save path resolves them
    /// last-activated-wins. A/B stay bounded by the fg/bg durations in
    /// SegmentSpanMath.
    void applySpan(SegmentSpan next) {
      final d = ctx.draft;
      if (d == null) return;
      bg.updateSegmentEditDraft(d.copyWith(span: next));
      refreshSeals(next);
    }

    /// Recomputes an A/B span for a snap-clamped scalar, mirroring the
    /// surfaces' `_startSpan` / `_endSpan` (same sticky/seal parameters), so a
    /// wall stop lands exactly on the boundary instead of the finger target.
    SegmentSpan snapStartSpan(SegmentSpan span, int fgMs) =>
        SegmentSpanMath.dragStart(
          span,
          fgMs,
          fgDurMs: fgDurMs,
          bgDurMs: bgDurMs,
          minSpanMs: minSpanMs,
          sticky: stickyConsume.abSticky,
          keepMaxLength: pKeepMaxLength,
          sealLeadMs: sealLead.value,
          sealTailMs: sealTail.value,
        );

    SegmentSpan snapEndSpan(SegmentSpan span, int fgMs) => SegmentSpanMath.dragEnd(
          span,
          fgMs,
          fgDurMs: fgDurMs,
          bgDurMs: bgDurMs,
          minSpanMs: minSpanMs,
          sticky: stickyConsume.abSticky,
          keepMaxLength: pKeepMaxLength,
          sealLeadMs: sealLead.value,
          sealTailMs: sealTail.value,
        );

    /// One snap tick: clamps [desired] against the gesture session (creating
    /// one defensively when a surface skipped the touch-down lifecycle).
    SnapClampResult snapAdvance({required int from, required int desired}) {
      final session = snapSession.value ??= SnapDragSession(
        walls: snapWalls,
        released: snapMemory.released,
      );
      return session.advance(from: from, desired: desired);
    }

    /// An A/B drag tick: keep it LOCAL (no global store notification).
    void onSpanDrag(SegmentSpan next) {
      final d = ctx.draft;
      SegmentSpan target = next;
      if (snapEnabled && d != null && snapWalls.isNotEmpty) {
        final SegmentSpan ref = dragSpan.value ?? d.span;
        final movedA = next.fgStartMs != ref.fgStartMs;
        final movedB = next.fgEndMs != ref.fgEndMs;
        // A lone endpoint meets the walls. A whole-span re-clamp moves both
        // ends at once and funnels through onOffsetDrag instead.
        if (movedA != movedB) {
          final bool isA = movedA;
          final r = snapAdvance(
            from: isA ? ref.fgStartMs : ref.fgEndMs,
            desired: isA ? next.fgStartMs : next.fgEndMs,
          );
          final int desired = isA ? next.fgStartMs : next.fgEndMs;
          if (r.value != desired) {
            target =
                isA ? snapStartSpan(ref, r.value) : snapEndSpan(ref, r.value);
          }
        }
      }
      if (kDialDebugLogsPanel) {
        debugPrint('DIAL_DEBUG_LOG panel spanDrag next=${next.fgStartMs}-${next.fgEndMs} '
            'off=${next.bgOffsetMs}');
      }
      dragSpan.value = target;
      requestLiveBgSeek(target);
    }

    /// A P drag tick: [deltaMs] is the incremental alignment delta since the
    /// previous tick; the offset is accumulated against the gesture's reference
    /// span so the A/B re-clamp can be undone by dragging back.
    void onOffsetDrag(int deltaMs) {
      final ref = dragRefSpan.value;
      if (ref == null) return;
      // Positive = toward the 100% end (the dial reports clockwise as positive).
      dragOffAccum.value += deltaMs;
      // ONE pure ladder (see SegmentSpanMath.dragAlignment): pulling away
      // from a bound end spends only the new pile above the seal, then the
      // rest translates; pressing into a bound piles up as before.
      SegmentSpan target = SegmentSpanMath.dragAlignment(
        ref,
        dragOffAccum.value,
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        minSpanMs: minSpanMs,
        keepMaxLength: pKeepMaxLength,
        sealLeadMs: sealLead.value,
        sealTailMs: sealTail.value,
        pSticky: stickyConsume.pSticky,
      );
      if (snapEnabled && snapWalls.isNotEmpty) {
        // P meets the walls at its centre. Re-run against the wall and REBASE
        // the accumulation onto it, so a reversed finger moves back on the
        // next tick (never unwinds overshoot).
        final r = snapAdvance(
          from: (dragSpan.value ?? ref).centerMs,
          desired: target.centerMs,
        );
        if (r.value != target.centerMs) {
          final eff = dragOffAccum.value + (r.value - target.centerMs);
          target = SegmentSpanMath.dragAlignment(
            ref,
            eff,
            fgDurMs: fgDurMs,
            bgDurMs: bgDurMs,
            minSpanMs: minSpanMs,
            keepMaxLength: pKeepMaxLength,
            sealLeadMs: sealLead.value,
            sealTailMs: sealTail.value,
            pSticky: stickyConsume.pSticky,
          );
          dragOffAccum.value = eff;
        }
      }
      dragSpan.value = target;
      requestLiveBgSeek(target);
    }

    /// Drag lifecycle: pause the pair for the gesture, seed the live span on
    /// touch-down, commit it once on release and restore the play state.
    void onDragActive(bool active) {
      final d = ctx.draft;
      if (kDialDebugLogsPanel) {
        debugPrint('DIAL_DEBUG_LOG panel dragActive=$active draft=${d?.span}');
      }
      if (d == null) return;
      if (active) {
        dragRefSpan.value = d.span;
        dragOffAccum.value = 0;
        dragSpan.value = d.span;
        // A fresh gesture gets its own snap session (release snapshot +
        // same-gesture hold); the walls it hits release on tap-up.
        snapSession.value = SnapDragSession(
          walls: snapWalls,
          released: snapMemory.released,
        );
        wasPlaying.value = fgPlayer.isPlaying || engine.isPlaying;
        if (wasPlaying.value) pausePair();
        return;
      }
      // Tap-up: the hit walls are truly released (the next gesture passes).
      final hits = snapSession.value?.hits ?? const <int>[];
      snapSession.value = null;
      for (final w in hits) {
        snapMemory.release(w);
      }
      if (hits.isNotEmpty) snapVersion.value++;
      final live = dragSpan.value;
      dragSpan.value = null;
      dragRefSpan.value = null;
      dragOffAccum.value = 0;
      if (live != null && live != d.span) {
        bg.updateSegmentEditDraft(d.copyWith(span: live));
        refreshSeals(live);
      }
      // Land the aligned frame exactly on release.
      requestLiveBgSeek(live ?? d.span, immediate: true);
      if (wasPlaying.value) playPair();
      wasPlaying.value = false;
    }

    final committedSpan = draft?.span;

    /// Moves one A/P/B handle to the current playhead. Shows the (suppressible)
    /// one-time explanation the first times it is used — and, because a popup
    /// must not appear over moving video, pauses the pair first.
    ///
    /// Everything positional is read AT PRESS TIME, so the panel build never
    /// subscribes to the playhead (see the note above).
    Future<void> movePointToCurrent(SegmentPoint point) async {
      final d = ctx.draft;
      if (d == null) return;
      final int fgMs = fgPhysicalPositionNow(context);
      // A is legal on the playhead's left of the centre, B on its right.
      final bool allowed = SegmentSpanMath.canMovePoint(
        point: point,
        fgMs: fgMs,
        centerMs: d.span.centerMs,
      );
      if (!allowed) return;
      if (shouldShowWarning(
          useAppStore().state.suppressedWarnings, kWarningBgAlignMovePointHint)) {
        pausePair();
      }
      await showInfoSuppressibleDialog(
        context,
        warningId: kWarningBgAlignMovePointHint,
        title: t.bg_align_move_hint_title,
        message: t.bg_align_move_hint_body,
        // The move itself lands either way — this is a one-time explanation, so
        // the box starts ticked (meta-settings can restore it).
        defaultDontAsk: true,
      );
      if (!context.mounted) return;
      applySpan(SegmentSpanMath.movePointTo(
        span: ctx.draft?.span ?? d.span,
        point: point,
        fgMs: fgPhysicalPositionNow(context),
        bgMs: engine.position.inMilliseconds,
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        minSpanMs: minSpanMs,
      ));
    }

    // The A/B buttons jump their own endpoint to the current playhead. The bar
    // greys the illegal one; the press-time handler re-checks the same rule.
    final isDisplayingBg = bg.select(
      context,
      (s) => s.displayTarget == ControlTarget.background,
    );

    void toggleDisplay() {
      // Arm the capability, then flip which picture is shown.
      bg.setShowBgVideo(true);
      bg.cycleDisplayTarget();
    }

    // Commit-in-flight latch: the save path awaits a DB write + verification,
    // so without it a fast double-tap fires two writes.
    final saving = useState(false);

    Future<void> save() async {
      if (saving.value) return;
      final d = ctx.draft;
      if (d == null) return;
      final bgFile = ctx.bgFile;
      // The DRAFT owns the bg identity: it is seeded from the live file (new
      // segment) or the saved row (re-edit), and every in-editor switch
      // (prev/next/pick) writes it — so an explicit choice must never be
      // overwritten by whatever the engine happens to play. The live resolver
      // is only a fallback when the draft names no file.
      final patched = d.copyWith(
        bgStorageId: d.bgStorageId ?? bgFile?.storageId,
        bgPath: d.bgPath ?? bgFile?.path.join('/'),
        fgPercent: d.fgPercent,
        bgPercent: d.bgPercent,
        colorArgb: d.colorArgb ?? randomSegmentColorArgb(),
      );
      bg.updateSegmentEditDraft(patched);
      saving.value = true;
      try {
        await commitSegmentEdit(
          context,
          ctx,
          action: patched.action,
          draftOverride: patched,
        );
      } finally {
        saving.value = false;
      }
    }

  /// Opens the segment colour picker; a pick updates the in-progress draft's
  /// label colour (persisted on the next Save).
  Future<void> onPickColor() async {
    final d = ctx.draft;
    if (d == null) return;
    final initial = d.colorArgb ??
        resolveSegmentColorArgb(explicit: null, seed: d.span.fgStartMs);
    final picked = await showSegmentColorDialog(context, initialArgb: initial);
    if (picked == null || !context.mounted) return;
    bg.updateSegmentEditDraft(d.copyWith(colorArgb: picked));
  }

    /// 保存为静音 is a STATE toggle, not an immediate write: it flips the
    /// draft's action and the Save button commits it. The first time it is
    /// enabled an explanation pops (suppressible; restorable in meta-settings).
    Future<void> toggleSilence() async {      if (saving.value) return;
      final d = ctx.draft;
      if (d == null) return;
      final enabling = d.action != MappingAction.silence;
      if (enabling &&
          shouldShowWarning(useAppStore().state.suppressedWarnings,
              kWarningBgAlignSilenceNoFile)) {
        await showInfoSuppressibleDialog(
          context,
          warningId: kWarningBgAlignSilenceNoFile,
          title: t.bg_align_silence_no_file_title,
          message: t.bg_align_silence_no_file_body,
          // This one defaults to "don't ask again" (per the requirement) — the
          // knowledge is one-time; meta-settings can restore it.
          defaultDontAsk: true,
        );
        if (!context.mounted) return;
      }
      bg.updateSegmentEditDraft(d.copyWith(
        action: enabling ? MappingAction.silence : MappingAction.playMedia,
      ));
    }

    Future<void> exit() async {
      if (saving.value) return;
      final discard = await showConfirmSuppressibleDialog(
        context,
        warningId: kWarningBgAlignExitDiscard,
        title: t.bg_align_exit_discard_title,
        message: t.bg_align_exit_discard_body,
        confirmLabel: t.bg_align_exit_no_save,
        destructive: true,
      );
      if (!discard) return;
      // Commit-less exit still makes the alignment live in memory: stage the
      // draft as a session overlay so the runtime picks it up without a DB
      // write. It is dropped on session close / file switch / stop.
      final d = ctx.draft;
      if (d != null) stageApbOverlayFromDraft(ctx, d);
      bg.exitSegmentEdit();
      // A manager-driven edit opened a transient single-fg context; close it so
      // the previous playback context resumes.
      await closeActiveApbEditSession();
    }

    final bool silenceOn = draft?.action == MappingAction.silence;

    /// Snap toggle: persists, shows the first-use guide, and reports when
    /// there is nothing to stick to. Switching clears every release.
    Future<void> onToggleSnap() async {
      if (!snapEnabled) {
        if (shouldShowWarning(useAppStore().state.suppressedWarnings,
            kWarningBgAlignSnapGuide)) {
          pausePair();
        }
        await showInfoSuppressibleDialog(
          context,
          warningId: kWarningBgAlignSnapGuide,
          title: t.bg_align_snap_guide_title,
          message: t.bg_align_snap_guide_body,
          // One-time knowledge — the box starts ticked (restorable in
          // Settings → Warning dialogs).
          defaultDontAsk: true,
        );
        if (!context.mounted) return;
        await bg.setSnapEnabled(true);
        if (!context.mounted) return;
        snapMemory.clear();
        snapSession.value = null;
        snapVersion.value++;
        if (snapWalls.isEmpty &&
            shouldShowWarning(useAppStore().state.suppressedWarnings,
                kWarningBgAlignSnapNone)) {
          await showInfoSuppressibleDialog(
            context,
            warningId: kWarningBgAlignSnapNone,
            title: t.bg_align_snap_none_title,
            message: t.bg_align_snap_none_body,
            defaultDontAsk: true,
          );
          if (!context.mounted) return;
        }
        return;
      }
      await bg.setSnapEnabled(false);
      snapMemory.clear();
      snapSession.value = null;
      snapVersion.value++;
    }

    final bar = SegmentEditButtonBar(
      // The transport button reflects the FOREGROUND only: it is the side the
      // press toggles (see onPlayPause), so a bg-only playing state must not
      // show a "pause" icon the press would then contradict.
      isPlaying: isPlaying,
      busy: saving.value,
      onPlayPause: onPlayPause,
      onBackward: () => stepRelative(forward: false),
      onForward: () => stepRelative(forward: true),
      snapOn: snapEnabled,
      onToggleSnap: () => unawaited(onToggleSnap()),
      onSave: save,
      onExit: exit,
      onSwapRings: isSide ? bg.toggleAlignRingAssignment : null,
      isDisplayingBg: isDisplayingBg,
      onToggleDisplay: toggleDisplay,
      abCenterMs: draft?.span.centerMs,
      onMoveA: () => movePointToCurrent(SegmentPoint.a),
      onMoveB: () => movePointToCurrent(SegmentPoint.b),
      // P move-to-current is intentionally disabled in the bar
      // (kEnablePMoveButton); the handler is retained, not deleted.
      canMoveP: true,
      onMoveP: () => movePointToCurrent(SegmentPoint.p),
      silenceOn: silenceOn,
      onToggleSilence: toggleSilence,
      colorArgb: draft == null
          ? null
          : (draft.colorArgb ??
              resolveSegmentColorArgb(
                  explicit: null, seed: draft.span.fgStartMs)),
      onPickColor: draft == null ? null : () => onPickColor(),
      color: color,
      overlayColor: overlayColor,
    );

    // A leaf reports the dot reaching the window end; pause the pair so the dot
    // can never leave the ring (the user may still seek inside the window).
    void onWindowEndReached() {
      if (fgPlayer.isPlaying || engine.isPlaying) pausePair();
    }

    // The editor can only draw a MEANINGFUL A-B window once both durations are
    // known: during the entry context switch (and while a 副音 is still
    // initializing) either can be 0 for a few frames, and the window math would
    // then degrade to a full-fg view that collapses A/P/B onto a point. Hold a
    // neutral placeholder until the pair is ready instead.
    final bool editorReady = fgDurMs > 0 &&
        (draft == null || !draft.isPlayMedia || bgDurMs > 0);

    final timeline = _Timeline(
      ready: editorReady,
      ctx: ctx,
      draft: draft,
      liveSpan: dragSpan,
      fgDurMs: fgDurMs,
      bgDurMs: bgDurMs,
      minSpanMs: minSpanMs,
      sameBgExisting: sameBgExisting,
      onSeekFg: onSeekFg,
      onPauseFg: fgPlayer.pause,
      onSpanDrag: onSpanDrag,
      onOffsetDrag: onOffsetDrag,
      onDragActive: onDragActive,
      abSticky: stickyConsume.abSticky,
      keepMaxLength: pKeepMaxLength,
      sealLeadMs: sealLead.value,
      sealTailMs: sealTail.value,
      fgWindowZoom: fgWindowZoom,
      fgWindowPushBg: fgWindowPushBg,
      windowStart: qWindowStart,
      onWindowStartChanged: onWindowStartChanged,
      onWindowEndReached: onWindowEndReached,
      snapActive: snapEnabled,
      snapWalls: snapWalls,
      snapReleased: snapMemory.released,
    );

    // The audition driver owns bg transport on BOTH layouts: the side shell
    // bypasses the linear Container but still needs the span-gated join/st~p,
    // otherwise the generic transport mirror's `editing` stand-down would leave
    // 副音 undriven for the whole session.
    if (isSide) {
      return _EditorAuditionDriver(
        draft: draft,
        engine: engine,
        child: _SideShell(
          ready: editorReady,
          color: color,
          fgDurMs: fgDurMs,
          bgDurMs: bgDurMs,
          minSpanMs: minSpanMs,
          fgOnInner: fgOnInner,
          span: committedSpan,
          liveSpan: dragSpan,
          existing: ctx.existing,
          bar: bar,
          onSeekFg: onSeekFg,
          onSpanDrag: onSpanDrag,
          onOffsetDrag: onOffsetDrag,
          onDragActive: onDragActive,
          onScrubStart: onScrubStart,
          onScrubEnd: onScrubEnd,
          vmWindow: ctx.fgWindow,
          abSticky: stickyConsume.abSticky,
          keepMaxLength: pKeepMaxLength,
          sealLeadMs: sealLead.value,
          sealTailMs: sealTail.value,
          fgWindowZoom: fgWindowZoom,
          fgWindowPushBg: fgWindowPushBg,
          windowStart: qWindowStart,
          onWindowStartChanged: onWindowStartChanged,
          onWindowDragActive: onWindowDragActive,
          onWindowEndReached: onWindowEndReached,
          snapActive: snapEnabled,
          snapWalls: snapWalls,
          snapReleased: snapMemory.released,
        ),
      );
    }

    return _EditorAuditionDriver(
      draft: draft,
      engine: engine,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [
              Colors.black.withValues(alpha: 0.42),
              Colors.black.withValues(alpha: 0.62),
              Colors.black.withValues(alpha: 0.82),
            ],
          ),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _Header(
              fgName: ctx.fgFile?.name ?? '—',
              bgName: ctx.bgFile?.name,
              noBgLabel: t.bg_segment_no_bg,
            ),
            const SizedBox(height: 4),
            timeline,
            const SizedBox(height: 4),
            if (draft == null)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Text(
                  t.bg_segment_edit_no_span,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            const SizedBox(height: 2),
            bar,
          ],
        ),
      ),
    );
  }
}

/// Live-audition driver of the align editor.
///
/// The foreground is the transport master (the panel's play/pause drives it and
/// the playhead keeps advancing). This leaf watches the playhead and joins 副音
/// ONLY while it sits inside the edited span [A,B] — the foreground interval
/// whose 1:1 alignment maps real bg content. Outside [A,B] (before A the bg
/// position would be negative, after B bg has run out, a silence draft, or no
/// loaded bg) the 副音 stays stopped and the foreground plays alone at its
/// configured volume share.
///
/// It is a LEAF on purpose: subscribing to the per-tick foreground/engine state
/// here keeps the editor panel itself from rebuilding on every playback frame
/// (the panel is handed down as a stable [child]).
class _EditorAuditionDriver extends HookWidget {
  const _EditorAuditionDriver({
    required this.draft,
    required this.engine,
    required this.child,
  });

  final SegmentEditDraft? draft;
  final BackgroundPlaybackEngine engine;
  final Widget child;

  /// Alignment tolerance for the in-span join: re-seek only when the mapping
  /// target drifted past this, so a healthy lockstep never stutters the decoder.
  static const int _kJoinToleranceMs = 250;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    // PHYSICAL foreground window (a VM merge undone): the draft span is stored
    // against the single real file, so the join test must use the same axis —
    // never the merged virtual position.
    final ForegroundWindow fgWindow = useForegroundWindow(context);
    final bool fgPlaying =
        context.select<MediaPlayer, bool>((p) => p.isPlaying);
    final bgPlaying =
        context.select<BackgroundPlaybackEngine, bool>((e) => e.isPlaying);
    final bool bgInitializing =
        context.select<BackgroundPlaybackEngine, bool>((e) => e.isInitializing);
    final int bgDurMs = context
        .select<BackgroundPlaybackEngine, int>((e) => e.duration.inMilliseconds);
    final String? bgPath = draft?.bgPath;
    // A 副音 is audition-able only once it is TRULY open: a duration alone can
    // be reported while the decoder is still initializing, and joining then
    // would race the open (the seek/play lands on the old/no media).
    final bool bgReady = bgDurMs > 0 && !bgInitializing;

    // The last offset the driver aligned for. A change to a LIVE offset (the P
    // handle while auditioning) must re-align once, like a fresh join.
    final lastOffset = useRef<int?>(null);

    useEffect(() {
      if (draft == null || !draft!.isPlayMedia || bgPath == null) {
        if (bgPlaying) {
          bg.setPlaying(false);
          unawaited(engine.pause());
        }
        lastOffset.value = null;
        return null;
      }
      lastOffset.value ??= draft!.span.bgOffsetMs;
      final action = resolveEditorAudition(
        isPlayMedia: draft!.isPlayMedia,
        bgReady: bgReady,
        fgPlaying: fgPlaying,
        bgPlaying: bgPlaying,
        fgPosMs: fgWindow.positionMs,
        spanStartMs: draft!.span.fgStartMs,
        spanEndMs: draft!.span.fgEndMs,
      );
      switch (action) {
        case EditorAuditionAction.none:
          lastOffset.value = draft!.span.bgOffsetMs;
        case EditorAuditionAction.startBg:
          final int target =
              (fgWindow.positionMs + draft!.span.bgOffsetMs).clamp(0, bgDurMs);
          // Join at the mapped instant (a fresh join or an offset change); a
          // healthy lockstep leaves the decoder alone.
          final int? prevOff = lastOffset.value;
          final bool offsetMoved = prevOff != null &&
              prevOff != draft!.span.bgOffsetMs;
          if (offsetMoved ||
              (engine.position.inMilliseconds - target).abs() >
                  _kJoinToleranceMs) {
            bg.noteSystemSeek();
            unawaited(engine.seek(Duration(milliseconds: target)));
          }
          bg.setPlaying(true);
          unawaited(engine.play());
          lastOffset.value = draft!.span.bgOffsetMs;
        case EditorAuditionAction.stopBg:
          bg.setPlaying(false);
          unawaited(engine.pause());
          lastOffset.value = draft!.span.bgOffsetMs;
      }
      return null;
    }, [
      draft?.isPlayMedia,
      draft?.bgPath,
      draft?.span.fgStartMs,
      draft?.span.fgEndMs,
      draft?.span.bgOffsetMs,
      bgDurMs,
      bgInitializing,
      fgWindow.positionMs,
      fgPlaying,
      bgPlaying,
    ]);

    return child;
  }
}

/// Coalesces live 副音 seeks: at most one per [_kEditorBgSeekInterval], with a
/// trailing call so the LAST requested target always lands (mirrors the
/// engine's own `_notifyThrottled`).
class _ThrottledBgSeek {
  _ThrottledBgSeek(this._engine);

  final BackgroundPlaybackEngine _engine;
  Timer? _trailing;
  DateTime _last = DateTime.fromMillisecondsSinceEpoch(0);
  int? _pending;

  void request(int targetMs) {
    final now = DateTime.now();
    final elapsed = now.difference(_last);
    if (elapsed >= _kEditorBgSeekInterval) {
      _last = now;
      _trailing?.cancel();
      _trailing = null;
      unawaited(_engine.seek(Duration(milliseconds: targetMs)));
      return;
    }
    _pending = targetMs;
    _trailing ??= Timer(_kEditorBgSeekInterval - elapsed, () {
      _trailing = null;
      final int? target = _pending;
      _pending = null;
      if (target == null) return;
      _last = DateTime.now();
      unawaited(_engine.seek(Duration(milliseconds: target)));
    });
  }

  /// Lands [targetMs] now (end of an interaction), cancelling any pending
  /// trailing seek so the final frame is exact.
  void requestNow(int targetMs) {
    _pending = null;
    _trailing?.cancel();
    _trailing = null;
    _last = DateTime.now();
    unawaited(_engine.seek(Duration(milliseconds: targetMs)));
  }

  void dispose() {
    _trailing?.cancel();
    _trailing = null;
  }
}

/// Foreground + background media names, so the pair under edit is unmistakable.
class _Header extends StatelessWidget {
  const _Header({
    required this.fgName,
    required this.bgName,
    required this.noBgLabel,
  });

  final String fgName;
  final String? bgName;
  final String noBgLabel;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final bgName = this.bgName ?? noBgLabel;
    return Row(
      children: [
        Icon(Icons.videocam_rounded, size: 14, color: theme.colorScheme.primary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            fgName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ),
        Icon(Icons.headset_rounded, size: 14, color: theme.colorScheme.tertiary),
        const SizedBox(width: 4),
        Expanded(
          child: Text(
            bgName,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: theme.textTheme.labelSmall,
          ),
        ),
      ],
    );
  }
}

/// The two axes (fg slider row + bg slider row with the A-P-B handles) and the
/// fg↔bg playhead connector, mirroring the former mapping editor's timeline.
///
/// The span-dependent widgets are driven by [liveSpan] so a drag only rebuilds
/// this timeline — never the surrounding panel or the store.
class _Timeline extends HookWidget {
  const _Timeline({
    required this.ready,
    required this.ctx,
    required this.draft,
    required this.liveSpan,
    required this.fgDurMs,
    required this.bgDurMs,
    required this.minSpanMs,
    required this.sameBgExisting,
    required this.onSeekFg,
    required this.onPauseFg,
    required this.onSpanDrag,
    required this.onOffsetDrag,
    required this.onDragActive,
    required this.abSticky,
    required this.keepMaxLength,
    required this.sealLeadMs,
    required this.sealTailMs,
    required this.fgWindowZoom,
    required this.fgWindowPushBg,
    required this.windowStart,
    required this.onWindowStartChanged,
    required this.onWindowEndReached,
    required this.snapActive,
    required this.snapWalls,
    required this.snapReleased,
  });

  final SegmentEditContext ctx;
  final SegmentEditDraft? draft;

  /// Both durations known — the A-B window is drawable. False during the entry
  /// context switch / while 副音 initializes; a neutral placeholder is shown.
  final bool ready;

  /// Local drag span (null when idle) — wins over [draft]?.span while dragging.
  final ValueListenable<SegmentSpan?> liveSpan;

  final int fgDurMs;
  final int bgDurMs;
  final int minSpanMs;
  final List<MappingSegment> sameBgExisting;
  final ValueChanged<int> onSeekFg;
  final VoidCallback onPauseFg;
  final ValueChanged<SegmentSpan> onSpanDrag;
  final ValueChanged<int> onOffsetDrag;
  final ValueChanged<bool> onDragActive;

  /// `bg.stickyConsume` — whether an A/B outward drag spends the opposite
  /// end's pile once its own is exhausted.
  final bool abSticky;

  /// `bg.pAlignKeepMaxLength` — whether the spent pile stops at the sealed
  /// pile or may go to zero.
  final bool keepMaxLength;

  /// The gesture-locked sealed piles (captured at build time; a drag does not
  /// rebuild this widget).
  final int sealLeadMs;
  final int sealTailMs;

  /// APB foreground zoom (setting + session window start).
  final double fgWindowZoom;
  final bool fgWindowPushBg;
  final ValueListenable<int?> windowStart;
  final int Function(int) onWindowStartChanged;
  final VoidCallback onWindowEndReached;

  /// Snap-to-saved-boundary (卡值） overlay: usable fg walls, of which the
  /// released ones are drawn as passable (not drawn at all).
  final bool snapActive;
  final List<int> snapWalls;
  final Set<int> snapReleased;

  @override
  Widget build(BuildContext context) {
    // Leaf position subscriptions: only THIS timeline rebuilds on a playback
    // tick — the editor panel and its button bar do not.
    final int rawFg =
        context.select<MediaPlayer, int>((p) => p.position.inMilliseconds);
    final int fgPosMs = ctx.fgWindow.virtualActive
        ? rawFg - ctx.fgWindow.virtualOffsetMs
        : rawFg;
    final int bgPosMs = context.select<BackgroundPlaybackEngine, int>(
        (e) => e.position.inMilliseconds);

    // 窗口边界暂停: pause once the dot CROSSES the visible window's end. The
    // hook MUST live in the build method (not a builder callback), so it is
    // computed here; the reactive override only affects the painted window.
    final FgDisplayWindow windowForClamp =
        _windowFor(windowStart.value, fgPosMs);
    final int? prevFgPosMs = usePrevious(fgPosMs);
    useEffect(() {
      if (FgDisplayWindowMath.reachedWindowEnd(
          windowForClamp, prevFgPosMs, fgPosMs)) {
        onWindowEndReached();
      }
      return null;
    }, <Object>[fgPosMs, windowForClamp]);

    return ValueListenableBuilder<int?>(
      valueListenable: windowStart,
      builder: (context, startOverride, _) {
        final FgDisplayWindow window = _windowFor(startOverride, fgPosMs);
        return ValueListenableBuilder<SegmentSpan?>(
          valueListenable: liveSpan,
          builder: (context, live, _) => _build(
              context, live ?? draft?.span, fgPosMs, bgPosMs, window),
        );
      },
    );
  }

  FgDisplayWindow _windowFor(int? startOverride, int fgPosMs) {
    final SegmentSpan? s = draft?.span;
    if (s == null) {
      return FgDisplayWindow(startMs: 0, widthMs: fgDurMs, fgDurMs: fgDurMs);
    }
    final int w = FgDisplayWindowMath.windowWidthMs(
        fgDurMs: fgDurMs, bgDurMs: bgDurMs, zoom: fgWindowZoom);
    return FgDisplayWindowMath.forSpan(
      fgDurMs: fgDurMs,
      bgDurMs: bgDurMs,
      zoom: fgWindowZoom,
      pushBg: fgWindowPushBg,
      fgPosMs: fgPosMs,
      spanStartMs: s.fgStartMs,
      spanEndMs: s.fgEndMs,
      requestedStartMs: startOverride ?? (fgPosMs - w ~/ 2),
    );
  }

  Widget _build(BuildContext context, SegmentSpan? span, int fgPosMs, int bgPosMs,
      FgDisplayWindow window) {
    final theme = Theme.of(context);
    final SegmentEditDraft? d = draft;
    if (!ready) {
      // Durations not known yet: never paint a degenerate (collapsed) window.
      return const SizedBox(
        height: kSegmentTimelineHeight,
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }
    return SizedBox(
      height: kSegmentTimelineHeight,
      child: LayoutBuilder(
        builder: (context, c) {
          final section = SegmentAxisMetrics.section(context, c.maxWidth);
          // Snap walls (卡值） on the bg axis: fg wall + the live offset, kept
          // to the real file so nothing draws outside the track.
          final List<int> snapTicks;
          final Set<int> snapReleasedTicks;
          if (snapActive && span != null && snapWalls.isNotEmpty) {
            final off = span.bgOffsetMs;
            snapTicks = [
              for (final w in snapWalls)
                if (w + off >= 0 && w + off <= bgDurMs) w + off,
            ];
            snapReleasedTicks = {
              for (final w in snapReleased)
                if (w + off >= 0 && w + off <= bgDurMs) w + off,
            };
          } else {
            snapTicks = const <int>[];
            snapReleasedTicks = const <int>{};
          }
          return Stack(
            clipBehavior: Clip.none,
            children: [
              Column(
                children: [
                  SizedBox(
                    height: kSegmentTrackRowHeight,
                    child: _fgRow(context, theme, span, fgPosMs, window),
                  ),
                  const SizedBox(height: kSegmentGapAfterFg),
                  SizedBox(
                    height: kSegmentTrackRowHeight,
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                          horizontal: kSegmentRowPadding),
                      child: Row(
                        children: [
                          SizedBox(
                            width: kSegmentLabelWidth,
                            child: Text(
                              formatDurationHms(
                                  Duration(milliseconds: bgPosMs)),
                              style: theme.textTheme.labelSmall,
                            ),
                          ),
                          Expanded(
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: SliderTheme(
                                    data: SliderTheme.of(context).copyWith(
                                      trackHeight: 4,
                                      thumbShape: const RoundSliderThumbShape(
                                          enabledThumbRadius: 6),
                                      overlayShape: const RoundSliderOverlayShape(
                                          overlayRadius: 12),
                                    ),
                                    child: Slider(
                                      value: bgDurMs <= 0
                                          ? 0
                                          : bgPosMs
                                              .toDouble()
                                              .clamp(0, bgDurMs)
                                              .toDouble(),
                                      max: bgDurMs <= 0
                                          ? 1.0
                                          : bgDurMs.toDouble(),
                                      // Dragging bg = linked seek: project the
                                      // bg target back onto the fg axis.
                                      onChangeStart: (_) => onPauseFg(),
                                      onChanged: (v) {
                                        if (span == null) return;
                                        onSeekFg(
                                          (v.round() - span.bgOffsetMs)
                                              .clamp(0, fgDurMs),
                                        );
                                      },
                                    ),
                                  ),
                                ),
                                if (span != null)
                                  Positioned.fill(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                          horizontal: 10),
                                      child: SegmentAbpTrack(
                                        bgDurMs: bgDurMs,
                                        startMs: span.bgStartMs,
                                        endMs: span.bgEndMs,
                                        sameFileExisting: sameBgExisting,
                                        editingId: d?.editingId ?? 0,
                                        snapActive: snapActive,
                                        snapWallTicks: snapTicks,
                                        snapReleasedTicks: snapReleasedTicks,
                                        onChangeStart: (ms) =>
                                            onSpanDrag(_startSpan(span, ms)),
                                        onChangeEnd: (ms) =>
                                            onSpanDrag(_endSpan(span, ms)),
                                        onTranslate: onOffsetDrag,
                                        onDragActive: onDragActive,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          SizedBox(
                            width: kSegmentLabelWidth,
                            child: Text(
                              formatDurationHms(
                                  Duration(milliseconds: bgDurMs)),
                              style: theme.textTheme.labelSmall,
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
              if (span != null)
                Positioned.fill(
                  child: IgnorePointer(
                    child: CustomPaint(
                      painter: SegmentLinkPainter(
                        metrics: section,
                        fgDurMs: fgDurMs,
                        bgDurMs: bgDurMs,
                        fgPosMs: fgPosMs,
                        bgPosMs: bgPosMs,
                        color: theme.colorScheme.primary,
                        span: span,
                        viewStartMs: window.active ? window.startMs : 0,
                        viewWidthMs: window.active ? window.widthMs : 0,
                      ),
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  /// The active span clipped to what the bg file can actually cover: an
  /// alignment that moves the window only lights the covered part (it never
  /// looks longer than A–B). A silence segment has no bg and is drawn whole.
  ({int? start, int? end}) _coveredActive(SegmentSpan? span) {
    final dd = draft;
    if (dd == null || span == null) return (start: null, end: null);
    if (!dd.isPlayMedia || bgDurMs <= 0) {
      return (start: span.fgStartMs, end: span.fgEndMs);
    }
    final covStart = math.max(span.fgStartMs, -span.bgOffsetMs);
    final covEnd = math.min(span.fgEndMs, bgDurMs - span.bgOffsetMs);
    if (covEnd <= covStart) return (start: null, end: null);
    return (start: covStart, end: covEnd);
  }

  Widget _fgRow(BuildContext context, ThemeData theme, SegmentSpan? span,
      int fgPosMs, FgDisplayWindow window) {
    final SegmentEditDraft? d = draft;
    final covered = _coveredActive(span);
    final bool active = window.active;
    final double lo = active ? window.startMs.toDouble() : 0.0;
    final double hi = active
        ? window.endMs.toDouble()
        : (fgDurMs <= 0 ? 1.0 : fgDurMs.toDouble());
    final double value = active
        ? window.clampPlayheadMs(fgPosMs).toDouble()
        : fgPosMs.clamp(0, fgDurMs).toDouble();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: kSegmentRowPadding),
      child: Row(
        children: [
          SizedBox(
            width: kSegmentLabelWidth,
            child: Text(
              formatDurationHms(Duration(milliseconds: fgPosMs)),
              style: theme.textTheme.labelSmall,
            ),
          ),
          Expanded(
            child: LayoutBuilder(
              builder: (context, c) => Stack(
                clipBehavior: Clip.none,
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: SegmentFgMarksPainter(
                        metrics: SegmentAxisMetrics.row(context, c.maxWidth),
                        fgDurMs: fgDurMs,
                        // Resolved slices (activation-order winners only): the
                        // fg axis agrees with playback and the manager overview.
                        existing: ctx.resolvedSlices,
                        editingId: 0,
                        tick: Colors.white.withValues(alpha: 0.9),
                        activeStartMs: covered.start,
                        activeEndMs: covered.end,
                        activeSilence: d != null && !d.isPlayMedia,
                        accent: theme.colorScheme.primary,
                        viewStartMs: active ? window.startMs : 0,
                        viewWidthMs: active ? window.widthMs : 0,
                      ),
                    ),
                  ),
                  SliderTheme(
                    data: SliderTheme.of(context).copyWith(
                      trackHeight: 4,
                      thumbShape:
                          const RoundSliderThumbShape(enabledThumbRadius: 6),
                      overlayShape:
                          const RoundSliderOverlayShape(overlayRadius: 12),
                    ),
                    child: Slider(
                      value: value,
                      min: lo,
                      max: hi <= lo ? lo + 1.0 : hi,
                      onChangeStart: (_) => onPauseFg(),
                      onChanged: (v) => onSeekFg(v.round()),
                    ),
                  ),
                  // q: the fg window pan handle at the left (12 o'clock) edge.
                  if (active)
                    Positioned(
                      left: -7,
                      top: 0,
                      bottom: 0,
                      width: 22,
                      child: GestureDetector(
                        key: const ValueKey('segment_fg_window_q'),
                        behavior: HitTestBehavior.opaque,
                        onHorizontalDragUpdate: (details) {
                          final double trackW = c.maxWidth;
                          if (trackW <= 0) return;
                          onWindowStartChanged(window.startMs +
                              (details.delta.dx / trackW * window.widthMs)
                                  .round());
                        },
                        child: Center(
                          child: Container(
                            width: 11,
                            height: 11,
                            decoration: BoxDecoration(
                              color: theme.colorScheme.primary,
                              borderRadius: BorderRadius.circular(3),
                              border: Border.all(
                                  color: Colors.white.withValues(alpha: 0.85),
                                  width: 1.4),
                            ),
                          ),
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
          SizedBox(
            width: kSegmentLabelWidth,
            child: Text(
              formatDurationHms(Duration(milliseconds: fgDurMs)),
              style: theme.textTheme.labelSmall,
              textAlign: TextAlign.right,
            ),
          ),
        ],
      ),
    );
  }

  /// A dragged on the bg axis → the new foreground span (bg→fg projection).
  SegmentSpan _startSpan(SegmentSpan span, int bgMs) => SegmentSpanMath.dragStart(
        span,
        bgMs - span.bgOffsetMs,
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        minSpanMs: minSpanMs,
        sticky: abSticky,
        keepMaxLength: keepMaxLength,
        sealLeadMs: sealLeadMs,
        sealTailMs: sealTailMs,
      );

  SegmentSpan _endSpan(SegmentSpan span, int bgMs) => SegmentSpanMath.dragEnd(
        span,
        bgMs - span.bgOffsetMs,
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        minSpanMs: minSpanMs,
        sticky: abSticky,
        keepMaxLength: keepMaxLength,
        sealLeadMs: sealLeadMs,
        sealTailMs: sealTailMs,
      );
}

/// Side-type shell: a self-drawn panel whose box and dial slot are the SAME
/// ones the normal layout gives the ring ([panelSizeForWindow] for the box,
/// [dialSpanForPanel] for the dial slot), so neither entering the editor nor
/// swapping the bottom bar can move or resize the ring.
///
/// It deliberately does NOT reuse `CircleSliderLayout`: that scaffold brings
/// the panel-resize handles/edges and the 副音 quick column, which must neither
/// appear nor steal gestures while editing. The bottom bar lives in a LOCKED
/// slot (it scrolls instead of growing).
class _SideShell extends HookWidget {
  const _SideShell({
    required this.ready,
    required this.color,
    required this.fgDurMs,
    required this.bgDurMs,
    required this.minSpanMs,
    required this.fgOnInner,
    required this.span,
    required this.liveSpan,
    required this.existing,
    required this.bar,
    required this.onSeekFg,
    required this.onSpanDrag,
    required this.onOffsetDrag,
    required this.onDragActive,
    required this.onScrubStart,
    required this.onScrubEnd,
    required this.vmWindow,
    required this.abSticky,
    required this.keepMaxLength,
    required this.sealLeadMs,
    required this.sealTailMs,
    required this.fgWindowZoom,
    required this.fgWindowPushBg,
    required this.windowStart,
    required this.onWindowStartChanged,
    required this.onWindowDragActive,
    required this.onWindowEndReached,
    required this.snapActive,
    required this.snapWalls,
    required this.snapReleased,
  });

  final Color? color;

  /// Both durations known — the A-B ring is drawable (see `_Timeline.ready`).
  final bool ready;

  final int fgDurMs;
  final int bgDurMs;
  final int minSpanMs;
  final bool fgOnInner;

  /// `bg.stickyConsume` — whether an A/B outward drag spends the opposite
  /// end's pile once its own is exhausted.
  final bool abSticky;

  /// `bg.pAlignKeepMaxLength` — whether the spent pile stops at the sealed
  /// pile or may go to zero.
  final bool keepMaxLength;

  /// The gesture-locked sealed piles (captured at build time).
  final int sealLeadMs;
  final int sealTailMs;

  /// APB foreground zoom (setting + session window start).
  final double fgWindowZoom;
  final bool fgWindowPushBg;
  final ValueListenable<int?> windowStart;
  final int Function(int) onWindowStartChanged;
  final ValueChanged<bool> onWindowDragActive;
  final VoidCallback onWindowEndReached;

  /// Snap-to-saved-boundary (卡值） overlay: usable fg walls, of which the
  /// released ones are drawn as passable (not drawn at all).
  final bool snapActive;
  final List<int> snapWalls;
  final Set<int> snapReleased;

  /// The physical foreground window — only for its VM flags (the dial's live
  /// position is subtracted from the raw player position in this build).
  final ForegroundWindow vmWindow;

  /// The committed mapped window; null before a draft is seeded.
  final SegmentSpan? span;

  /// Local drag span (null when idle) — wins over [span] while dragging.
  final ValueListenable<SegmentSpan?> liveSpan;

  final List<MappingSegment> existing;
  final Widget bar;
  final ValueChanged<int> onSeekFg;
  final ValueChanged<SegmentSpan> onSpanDrag;
  final ValueChanged<int> onOffsetDrag;
  final ValueChanged<bool> onDragActive;
  final VoidCallback onScrubStart;
  final VoidCallback onScrubEnd;

  @override
  Widget build(BuildContext context) {
    final app = useAppStore();
    // Per-mount panel-box key, published for the tests/anchor lookups (see
    // `usePublishedGlobalKey`): a shared key would let a new editor panel
    // re-take the old one and re-activate its OverlayPortals mid-layout.
    final GlobalKey panelKey = usePublishedGlobalKey(apbEditorPanelKeyNotifier);
    // Resolved from the panel anchor (see resolvePanelSideIsLeft) so the
    // editor's scrubber mirrors the same way the live panel does.
    final isLeftHanded = app.select(context, panelIsLeftHanded);
    final widthPct = app.select(context, (s) => s.sidewayPanelWidthPct);
    final heightPct = app.select(context, (s) => s.sidewayPanelHeightPct);
    final widthPx = app.select(context, (s) => s.sidewayPanelWidthPx);
    final heightPx = app.select(context, (s) => s.sidewayPanelHeightPx);
    final window = MediaQuery.sizeOf(context);
    final panel = panelSizeForWindow(
      windowW: window.width,
      windowH: window.height,
      isPhone: isMobilePlatform,
      widthPct: widthPct,
      heightPct: heightPct,
      widthPx: widthPx,
      heightPx: heightPx,
    );
    // The two slots take the sizes the NORMAL panel gives them (its LIVE
    // measurement of the bottom bar), so swapping in this editor's
    // slider / bottom-bar contents never changes either size.
    const double gap = 8;
    final committed = span;

    // Leaf position subscriptions (see the field docs): this widget rebuilds per
    // playback tick, but the `bar` it was handed is the SAME widget instance as
    // last build, so the button bar's subtree is not rebuilt.
    final int rawFg =
        context.select<MediaPlayer, int>((p) => p.position.inMilliseconds);
    final int fgPosMs =
        vmWindow.virtualActive ? rawFg - vmWindow.virtualOffsetMs : rawFg;
    final int bgPosMs = context.select<BackgroundPlaybackEngine, int>(
        (e) => e.position.inMilliseconds);

    // 窗口边界暂停 (side dial): pause once the dot CROSSES the window end. A
    // playhead already outside the window (the editor frames a span the dot
    // sits away from) must not re-pause on the first frame.
    final FgDisplayWindow fgWindowNow =
        _windowFor(fgPosMs, windowStart.value);
    final int? prevFgPosMs = usePrevious(fgPosMs);
    useEffect(() {
      if (FgDisplayWindowMath.reachedWindowEnd(
          fgWindowNow, prevFgPosMs, fgPosMs)) {
        onWindowEndReached();
      }
      return null;
    }, <Object>[fgPosMs, fgWindowNow]);

    return ValueListenableBuilder<double>(
      valueListenable: sidewayBarHeight,
      builder: (context, barSlotH, _) => SizedBox(
        key: panelKey,
        width: panel.panelW,
        height: panel.panelH,
        child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            width: panel.panelW,
            height: dialSpanForPanel(
                totalH: panel.panelH, barSlotH: barSlotH, gap: gap),
            child: Align(
              alignment: Alignment.bottomCenter,
              child: !ready
                  ? const Center(
                      child: SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                  : (committed == null || fgDurMs <= 0)
                      ? const SizedBox.shrink()
                      : ValueListenableBuilder<int?>(
                      valueListenable: windowStart,
                      builder: (context, startOverride, _) =>
                          ValueListenableBuilder<SegmentSpan?>(
                        valueListenable: liveSpan,
                        builder: (context, live, _) {
                          final s = live ?? committed;
                          return SegmentDualRingDial(
                            fgPosMs: fgPosMs,
                            fgDurMs: fgDurMs,
                            bgPosMs: bgPosMs,
                            bgDurMs: bgDurMs,
                            span: s,
                            window: _windowFor(fgPosMs, startOverride),
                            existing: existing,
                            snapActive: snapActive,
                            snapWalls: snapWalls,
                            snapReleased: snapReleased,
                            fgOnInner: fgOnInner,
                            availableSpan: dialSpanForPanel(
                                totalH: panel.panelH,
                                barSlotH: barSlotH,
                                gap: gap),
                            isLeftHanded: isLeftHanded,
                            onSeekFg: onSeekFg,
                            onChangeStart: (a) => onSpanDrag(_startSpan(s, a)),
                            onChangeEnd: (b) => onSpanDrag(_endSpan(s, b)),
                            onOffsetDrag: onOffsetDrag,
                            onDragActive: onDragActive,
                            onWindowStartChanged: onWindowStartChanged,
                            onWindowDragActive: onWindowDragActive,
                            onScrubStart: onScrubStart,
                            onScrubEnd: onScrubEnd,
                            color: color,
                          );
                        },
                      ),
                    ),
            ),
          ),
          const SizedBox(height: gap),
          // Bottom bar slot: the SAME height the normal panel measured for its
          // own bar, so swapping the contents cannot change the footprint (the
          // bar scrolls instead of growing).
          SizedBox(
            height: barSlotH,
            child: SingleChildScrollView(child: bar),
          ),
        ],
        ),
      ),
    );
  }

  // The side dial measures in FOREGROUND ms (its angular scale is the fg
  // duration), so these take the fg value directly — unlike the linear
  // `SegmentAbpTrack`, whose handles report bg-axis ms.
  SegmentSpan _startSpan(SegmentSpan span, int fgMs) => SegmentSpanMath.dragStart(
        span,
        fgMs,
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        minSpanMs: minSpanMs,
        sticky: abSticky,
        keepMaxLength: keepMaxLength,
        sealLeadMs: sealLeadMs,
        sealTailMs: sealTailMs,
      );

  SegmentSpan _endSpan(SegmentSpan span, int fgMs) => SegmentSpanMath.dragEnd(
        span,
        fgMs,
        fgDurMs: fgDurMs,
        bgDurMs: bgDurMs,
        minSpanMs: minSpanMs,
        sticky: abSticky,
        keepMaxLength: keepMaxLength,
        sealLeadMs: sealLeadMs,
        sealTailMs: sealTailMs,
      );

  /// Resolves the APB foreground zoom window for the current playhead and the
  /// session start override.
  FgDisplayWindow _windowFor(int fgPosMs, int? startOverride) {
    final SegmentSpan? s = span;
    if (s == null) {
      return FgDisplayWindow(startMs: 0, widthMs: fgDurMs, fgDurMs: fgDurMs);
    }
    final int w = FgDisplayWindowMath.windowWidthMs(
        fgDurMs: fgDurMs, bgDurMs: bgDurMs, zoom: fgWindowZoom);
    return FgDisplayWindowMath.forSpan(
      fgDurMs: fgDurMs,
      bgDurMs: bgDurMs,
      zoom: fgWindowZoom,
      pushBg: fgWindowPushBg,
      fgPosMs: fgPosMs,
      spanStartMs: s.fgStartMs,
      spanEndMs: s.fgEndMs,
      requestedStartMs: startOverride ?? (fgPosMs - w ~/ 2),
    );
  }
}
