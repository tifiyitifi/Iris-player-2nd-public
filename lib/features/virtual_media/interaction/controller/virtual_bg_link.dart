import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/hooks/use_background_volume_context.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_vm_scope_mode.dart';
import 'package:iris/features/background_playback/resolver/vm_tiled_plan.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/background_playback/services/vm_scope_identity.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/virtual_media/interaction/ui/vm_tiled_manual_dialog.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';

/// What a Virtual Merge transition does to 副音.
enum VmBgSwitchAction {
  /// Nothing — 副音 keeps playing the same file.
  none,

  /// Start a NEW 副音 file (advance the 副音 queue one step).
  newBg,
}

/// Pure decision for the two 跨视频 switches (`bg.itemSwitch` /
/// `bg.segmentSwitch`).
///
/// - `itemRule`: a switch to a new LIST ITEM (here: a new virtual video) may
///   start a new 副音 file.
/// - `segmentRule`: a switch to another physical SEGMENT of the SAME virtual
///   video may start a new 副音 file (`newBg`) or let 副音 tile across it
///   (`keepPlaying`).
///
/// The 作用范围 always wins: when 副音 does not apply to the new media
/// (`applied` false) nothing is stepped.
///
/// A SEEK-driven change under the full lock is already mapped onto the 副音
/// timeline by `BackgroundRuntimeScope` (fixed offset + queue rollover), so the
/// link must not step again — otherwise the two would double-switch.
VmBgSwitchAction vmSubAudioSwitchAction({
  required BgCrossAction itemRule,
  required BgCrossAction segmentRule,
  required bool applied,
  required bool segmentChanged,
  required bool itemChanged,
  required bool changeWasSeek,
  required bool lockOwnsSeek,
}) {
  if (!applied) return VmBgSwitchAction.none;
  if (!segmentChanged && !itemChanged) return VmBgSwitchAction.none;
  if (changeWasSeek && lockOwnsSeek) return VmBgSwitchAction.none;
  final BgCrossAction rule = itemChanged ? itemRule : segmentRule;
  return rule == BgCrossAction.newBg
      ? VmBgSwitchAction.newBg
      : VmBgSwitchAction.none;
}

/// Cached one-shot tiling layout of one virtual item.
class _TiledPlanCache {
  _TiledPlanCache({
    required this.key,
    required this.queueFp,
    required this.origin,
    required this.slots,
  });

  /// The virtual item key (`scopeKey#displayIndex`) this plan was built for.
  final String key;

  /// The bg queue fingerprint the durations were resolved for.
  final String queueFp;

  /// The bg index the tiling origin aligned to (the track playing when the
  /// plan was first needed for this item).
  final int origin;

  final List<VmTiledSlot?> slots;
}

/// Virtual-Media ⇄ 副音 bridge.
///
/// Lives on the VM side on purpose: the bg feature must stay VM-agnostic (see
/// `background_playback_no_virtual_merge_test`). Mounted inside the 副音
/// runtime scope, it owns four cross-layer behaviors:
///
/// 1. **Block alignment** — per the two 跨视频 switches (`bgItemSwitch` /
///    `bgSegmentSwitch`), a video or segment switch starts a new 副音 file
///    (or lets 副音 tile across it).
/// 2. **作用范围 identity** — under [BgVmScopeMode.wholeVirtual] it publishes
///    the whole virtual video as the scope identity, so internal block switches
///    stop looking like a media change. The identity is pinned to the virtual
///    item that was current when the run started ("当时的当前"): a LATER
///    virtual item falls back to the physical block identity, so under
///    `smart` only its blocks carrying a saved timeline take over.
/// 3. **Saved-mapping precedence** — a block carrying a saved timeline outranks
///    the rule: leaving it restarts the alignment chain so the following blocks
///    re-align from 00:00.
/// 4. **Tiled plan** — under wholeVirtual + tiled, the bg queue is laid over
///    the virtual item ONCE (loop tiling cut at the segment boundaries) and
///    each internal switch plays its matching bg file + offset. A segment
///    adjusted by the user (align dialog, mapping save, dialog-confirmed
///    manual switch) is remembered in the session-only override map; the rest
///    keep the precomputed layout.
class VmSubAudioLinkScope extends HookWidget {
  const VmSubAudioLinkScope({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final vm = useVmPlaybackStore();
    final item = vm.select(context, (s) => s.item);
    final segmentIndex = vm.select(context, (s) => s.segmentIndex);
    final queueIndex = vm.select(context, (s) => s.queueIndex);
    final transitioning = vm.select(context, (s) => s.transitioning);
    final changeWasSeek = vm.select(context, (s) => s.lastSwitchWasSeek);

    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);
    final itemRule = bg.select(context, (s) => s.bgItemSwitch);
    final segmentRule = bg.select(context, (s) => s.bgSegmentSwitch);
    final scopeMode = bg.select(context, (s) => s.bgVmScopeMode);
    final applyScope = bg.select(context, (s) => s.applyScope);
    final anchorKey = bg.select(context, (s) => s.scopeAnchorKey);
    final offMediaKeys = bg.select(context, (s) => s.bgOffMediaKeys);
    final gateOpen = bg.select(context, (s) => s.gateOpen);
    final seekLink = bg.select(context, (s) => s.seekLink);
    final lockLevel = bg.select(context, (s) => s.lockLevel);
    final bgQueue = bg.select(context, (s) => s.queue);
    final bgCurrentIndex = bg.select(context, (s) => s.currentIndex);
    final vmTiledOverrides = bg.select(context, (s) => s.vmTiledOverrides);
    final userBgSwitchSeq = bg.select(context, (s) => s.userBgSwitchSeq);
    final userBgSwitchIndex = bg.select(context, (s) => s.userBgSwitchIndex);
    final physicalKey = useForegroundRatioKey(context);

    // ── 作用范围 identity (wholeVirtual, pinned to 当时的当前) ──
    //
    // Published BEFORE the scope observer reads it; the observer's effect runs
    // one frame later, which is well inside its existing settle window.
    //
    // Liveness (not mere presence): a stale store item whose queue already
    // left the segment (reconcile not yet run) must NOT publish the
    // whole-virtual override — gate on the controller's session liveness. A
    // switch in flight is legitimately alive, so transitioning counts as live.
    final vmLive = item != null &&
        (transitioning || VirtualMediaController.instance.isActive);
    final vmItemKey = item == null ? null : vmScopeItemKey(item.scopeKey);
    final pinnedItemKey = useRef<String?>(null);
    final override = vmScopeIdentityOverride(
      vmActive: vmLive,
      vmItemKey: vmItemKey,
      mode: scopeMode,
      pinnedItemKey: pinnedItemKey.value,
    );
    useEffect(() {
      bg.setVmScopeOverride(override);
      if (item != null &&
          scopeMode == BgVmScopeMode.wholeVirtual &&
          (pinnedItemKey.value == null || pinnedItemKey.value!.isEmpty) &&
          vmItemKey != null) {
        pinnedItemKey.value = vmItemKey;
      }
      if (item == null) {
        pinnedItemKey.value = null;
      }
      return null;
    }, [override, item, scopeMode, vmItemKey]);

    // VM-session activity: lets the bg side treat a VM block/video switch as a
    // 跨视频 transition (owned here) instead of a real list-item change.
    // Same liveness gate as the scope identity above: a stale item must not
    // hold the session active for a dead session.
    useEffect(() {
      bg.setVmSessionActive(vmLive);
      return null;
    }, [vmLive]);
    useEffect(() {
      return () => bg.setVmSessionActive(false);
    }, const []);

    // Scope identity in effect this frame (override → whole virtual video).
    final effectiveKey = override ?? physicalKey;

    // ── Saved-mapping precedence ──
    //
    // The block currently on screen may carry a saved timeline; knowing it lets
    // the link restart the alignment chain once that block is left, and lets
    // the tiled plan yield to it while it is on screen.
    final segment = (item == null || item.segments.isEmpty)
        ? null
        : item.segments[segmentIndex.clamp(0, item.segments.length - 1)];
    final blockMapping = useFuture(
      useMemoized(
        () async {
          final s = segment;
          if (s == null || !BackgroundPlaybackGate.enabled) {
            return false;
          }
          try {
            return await DbModule.bgMappingRepo.hasTimelineFor(
              storageId: s.storageId,
              path: s.fullPath,
            );
          } catch (_) {
            return false;
          }
        },
        [segment?.mediaKey],
      ),
    );
    final bool blockHasSavedMapping = blockMapping.data ?? false;

    final prevSegmentKey = useRef<String?>(null);
    final prevBlockHadMapping = useRef(false);
    useEffect(() {
      final key = segment?.mediaKey;
      // Leaving a block that carried a saved mapping outranks this rule: the
      // following blocks must re-align from 00:00 rather than chain onto the
      // mapped block's position.
      if (prevSegmentKey.value != null &&
          prevSegmentKey.value != key &&
          prevBlockHadMapping.value) {
        bg.bumpVmAlignReset();
      }
      prevSegmentKey.value = key;
      prevBlockHadMapping.value = blockHasSavedMapping;
      return null;
    }, [segment?.mediaKey, blockHasSavedMapping]);

    // ── Tiled plan inputs ──
    //
    // bg queue durations resolve like the runtime scope's timeline (DB rows;
    // unknown stays 0 and is skipped by the tiling math).
    final bgQueueFp = useMemoized(
      () => [
        for (final f in bgQueue) canonicalKey(f.storageId, f.path.join('/')),
      ].join('|'),
      [bgQueue],
    );
    final bgDurationsFuture = useFuture(
      useMemoized(
        () async {
          if (bgQueue.isEmpty || !BackgroundPlaybackGate.enabled) {
            return const <int>[];
          }
          try {
            final keys = <String>{
              for (final f in bgQueue)
                canonicalKey(f.storageId, f.path.join('/')),
            };
            final nodes = await DbModule.mediaNodeRepo.nodesByMediaKeys(keys);
            final byKey = <String, int>{};
            for (final n in nodes) {
              final f = n.maybeMap(file: (v) => v, orElse: () => null);
              final d = f?.durationMs;
              if (f == null || d == null || d <= 0) continue;
              byKey[canonicalKey(f.storageId, f.path.join('/'))] = d;
            }
            return <int>[
              for (final f in bgQueue)
                byKey[canonicalKey(f.storageId, f.path.join('/'))] ?? 0,
            ];
          } catch (_) {
            return <int>[for (var i = 0; i < bgQueue.length; i++) 0];
          }
        },
        [bgQueueFp],
      ),
    );
    final List<int>? bgDurations = bgDurationsFuture.data;
    final planCache = useRef<_TiledPlanCache?>(null);
    final pendingTiledSegment = useRef<int?>(null);

    _TiledPlanCache? ensureTiledPlan(String itemKey) {
      final it = item;
      final durs = bgDurations;
      if (it == null || durs == null || bgQueue.isEmpty) {
        return planCache.value?.key == itemKey ? planCache.value : null;
      }
      final cached = planCache.value;
      if (cached != null &&
          cached.key == itemKey &&
          cached.queueFp == bgQueueFp) {
        return cached;
      }
      final origin = (cached != null && cached.key == itemKey)
          ? cached.origin
          : (bgCurrentIndex >= 0 && bgCurrentIndex < bgQueue.length
              ? bgCurrentIndex
              : 0);
      final built = _TiledPlanCache(
        key: itemKey,
        queueFp: bgQueueFp,
        origin: origin,
        slots: resolveVmTiledBgPlan(
          segmentDurationsMs: [
            for (final s in it.segments) s.durationMs ?? 0,
          ],
          bgDurationsMs: durs,
          startBgIndex: origin,
        ),
      );
      planCache.value = built;
      return built;
    }

    // Whether the tiled plan owns internal switches right now.
    bool tiledPlanActive({required bool applied}) {
      if (item == null) return false;
      if (!enabled) return false;
      if (scopeMode != BgVmScopeMode.wholeVirtual) return false;
      if (segmentRule != BgCrossAction.keepPlaying) return false;
      if (!applied) return false;
      // A block with a saved timeline is owned by its mapping, and under
      // `smart` only such blocks take over at all.
      if (blockHasSavedMapping) return false;
      if (applyScope == BgApplyScope.smart) return false;
      return true;
    }

    // ── Block/video switch → new 副音 file (or tiled entrance) ──
    final prevSegment = useRef<int?>(null);
    final prevItem = useRef<String?>(null);
    // Previous VM queue index, for the switch DIRECTION when the play queue left
    // no move stamp (a row tap). 「上一集」 used to advance 副音.
    final prevQueueIndex = useRef<int?>(null);

    useEffect(() {
      final it = item;
      if (it == null) {
        prevSegment.value = null;
        prevItem.value = null;
        pendingTiledSegment.value = null;
        return null;
      }
      // Wait for a switch in flight to settle: acting mid-open would fight the
      // feed. `prev*` is NOT advanced here, so the transition is still seen
      // once it lands.
      if (transitioning) return null;

      final itemKey = '${it.scopeKey}#${it.displayIndex}';
      final prevS = prevSegment.value;
      final prevI = prevItem.value;
      final int? prevQ = prevQueueIndex.value;
      final segmentChanged = prevS != null && prevS != segmentIndex;
      final itemChanged = prevI != null && prevI != itemKey;

      prevSegment.value = segmentIndex;
      prevItem.value = itemKey;
      prevQueueIndex.value = queueIndex;

      // First observation of a session — nothing to compare against.
      if (prevS == null && prevI == null) return null;
      // No switch: a deferred tiled entrance (durations arrived late) is
      // owned by the effect below — never clear it here.
      if (!segmentChanged && !itemChanged) return null;
      // Gate closed: an explicit stop must never be undone by an automatic
      // block/video switch (the switch itself was already recorded above).
      if (!gateOpen) return null;

      final applied = resolveApplyToCurrent(
        enabled: enabled,
        applyScope: applyScope,
        anchorKey: anchorKey,
        offMediaKeys: offMediaKeys,
        fgKey: effectiveKey,
      );
      final lockOwns =
          enabled && shouldSyncPosition(link: seekLink, level: lockLevel);
      final action = vmSubAudioSwitchAction(
        itemRule: itemRule,
        segmentRule: segmentRule,
        applied: applied,
        segmentChanged: segmentChanged,
        itemChanged: itemChanged,
        changeWasSeek: changeWasSeek,
        lockOwnsSeek: lockOwns,
      );
      if (action == VmBgSwitchAction.newBg) {
        // Step the pair the SAME way the foreground went: 「上一集」 must walk
        // 副音 backward (the unconditional forward step was the bug the
        // foreground queue already cured).
        final PlayQueueMove? move = usePlayQueueStore().lastMove;
        final int playIndex = usePlayQueueStore().state.currentIndex;
        unawaited(
          bg.step(
            forward: vmBgStepForward(
              moveWasForward: (move != null && move.index == playIndex)
                  ? move.forward
                  : null,
              previousQueueIndex: prevQ,
              queueIndex: queueIndex,
            ),
            excludedKey: excludedForegroundKey(),
          ),
        );
        return null;
      }

      // WholeVirtual tiled entrance for an INTERNAL segment switch (an item
      // change stays on the item rule above): play the segment's matching bg
      // file + offset from the one-shot plan.
      if (segmentChanged &&
          !itemChanged &&
          !(changeWasSeek && lockOwns) &&
          tiledPlanActive(applied: applied)) {
        final seg = segment;
        if (seg == null) return null;
        final planned = ensureTiledPlan(itemKey);
        final VmTiledSlot? slot =
            vmTiledOverrides[seg.mediaKey] ??
                ((planned != null && segmentIndex < planned.slots.length)
                    ? planned.slots[segmentIndex]
                    : null);
        if (slot == null) {
          // Durations not ready yet: retry when they land (same segment).
          if (planned == null && bgDurations == null) {
            pendingTiledSegment.value = segmentIndex;
          }
          return null;
        }
        if (slot.bgIndex < 0 || slot.bgIndex >= bgQueue.length) return null;
        final excluded = excludedForegroundKey();
        if (excluded != null &&
            backgroundMediaKey(bgQueue[slot.bgIndex]) == excluded) {
          return null;
        }
        pendingTiledSegment.value = null;
        unawaited(
          bg.requestTiledTarget(
            index: slot.bgIndex,
            targetMs: slot.bgOffsetMs,
          ),
        );
      }
      return null;
    }, [
      item,
      segmentIndex,
      queueIndex,
      transitioning,
      changeWasSeek,
      enabled,
      gateOpen,
      itemRule,
      segmentRule,
      applyScope,
      anchorKey,
      offMediaKeys,
      seekLink,
      lockLevel,
      effectiveKey,
      bgQueueFp,
      bgDurations,
      bgQueue,
      bgCurrentIndex,
      vmTiledOverrides,
      blockHasSavedMapping,
      segment?.mediaKey,
    ]);

    // Deferred tiled entrance: durations landed after the switch.
    useEffect(() {
      final it = item;
      final pending = pendingTiledSegment.value;
      if (it == null || pending == null || bgDurations == null) return null;
      if (pending != segmentIndex || transitioning) return null;
      // Gate closed: drop the deferred entrance — nothing should start 副音.
      if (!gateOpen) {
        pendingTiledSegment.value = null;
        return null;
      }
      final itemKey = '${it.scopeKey}#${it.displayIndex}';
      final applied = resolveApplyToCurrent(
        enabled: enabled,
        applyScope: applyScope,
        anchorKey: anchorKey,
        offMediaKeys: offMediaKeys,
        fgKey: effectiveKey,
      );
      if (!tiledPlanActive(applied: applied)) {
        pendingTiledSegment.value = null;
        return null;
      }
      final seg = segment;
      if (seg == null) return null;
      final planned = ensureTiledPlan(itemKey);
      final VmTiledSlot? slot =
          vmTiledOverrides[seg.mediaKey] ??
              ((planned != null && segmentIndex < planned.slots.length)
                  ? planned.slots[segmentIndex]
                  : null);
      if (slot == null) return null;
      if (slot.bgIndex < 0 || slot.bgIndex >= bgQueue.length) {
        pendingTiledSegment.value = null;
        return null;
      }
      pendingTiledSegment.value = null;
      unawaited(
        bg.requestTiledTarget(
          index: slot.bgIndex,
          targetMs: slot.bgOffsetMs,
        ),
      );
      return null;
    }, [
      bgDurations,
      item,
      segmentIndex,
      transitioning,
      enabled,
      gateOpen,
      segmentRule,
      scopeMode,
      applyScope,
      anchorKey,
      offMediaKeys,
      effectiveKey,
      blockHasSavedMapping,
      segment?.mediaKey,
      vmTiledOverrides,
      bgQueue,
      bgQueueFp,
    ]);

    // ── Manual bg switch → ask, then remember for this launch ──
    //
    // User-initiated queue moves raise `userBgSwitchSeq` at the store; while
    // a tiled plan is active the link asks how the current segment should
    // align the new track and records the pick as its session-only override
    // ("按弹窗结果记"). A dismissed dialog still keeps the switch itself,
    // aligned from 00:00. Outside the tiled scope the signal is consumed
    // silently (the normal alignment chain owns those moves).
    final askingTiled = useRef(false);
    useEffect(() {
      if (userBgSwitchSeq <= 0) return null;
      final int landedIndex = userBgSwitchIndex;
      bg.consumeUserBgSwitch();
      final applied = resolveApplyToCurrent(
        enabled: enabled,
        applyScope: applyScope,
        anchorKey: anchorKey,
        offMediaKeys: offMediaKeys,
        fgKey: effectiveKey,
      );
      if (!tiledPlanActive(applied: applied)) return null;
      final seg = segment;
      if (seg == null || askingTiled.value || transitioning) return null;
      if (landedIndex < 0 || landedIndex >= bgQueue.length) return null;
      if (!context.mounted) return null;
      askingTiled.value = true;
      unawaited(
        showVmTiledManualDialog(context).then((pick) {
          askingTiled.value = false;
          if (!context.mounted) return;
          final store = useBackgroundPlaybackStore();
          if (pick == null) {
            // Dismissed: the switch stands, aligned from the head.
            store.recordVmTiledOverride(
              seg.mediaKey,
              VmTiledSlot(bgIndex: landedIndex, bgOffsetMs: 0),
            );
            return;
          }
          if (pick.overshot && pick.choice == BgAlignChoice.percent) {
            // >100: move to the NEXT bg file at 00:00 (dialog-owned jump,
            // single wrap without repeat/exclusion subtleties). A "from head"
            // choice must win even if a stale overshoot flag survived.
            final next = bgQueue.isEmpty
                ? landedIndex
                : (landedIndex + 1) % bgQueue.length;
            store.recordVmTiledOverride(
              seg.mediaKey,
              VmTiledSlot(bgIndex: next, bgOffsetMs: 0),
            );
            unawaited(store.requestTiledTarget(index: next, targetMs: 0));
            return;
          }
          final durs = bgDurations;
          final int bgDur = (durs != null &&
                  landedIndex >= 0 &&
                  landedIndex < durs.length)
              ? durs[landedIndex]
              : 0;
          final int targetMs = resolveBgAlignmentChoice(
            choice: pick.choice,
            bgDurMs: bgDur,
            percent: pick.percent,
          );
          store.recordVmTiledOverride(
            seg.mediaKey,
            VmTiledSlot(bgIndex: landedIndex, bgOffsetMs: targetMs),
          );
          unawaited(
            store.requestTiledTarget(
              index: landedIndex,
              targetMs: targetMs,
            ),
          );
        }),
      );
      return null;
    }, [
      userBgSwitchSeq,
      userBgSwitchIndex,
      enabled,
      segmentRule,
      scopeMode,
      applyScope,
      anchorKey,
      offMediaKeys,
      effectiveKey,
      blockHasSavedMapping,
      segment?.mediaKey,
      transitioning,
      bgQueue,
      bgQueueFp,
      bgDurations,
    ]);

    return child;
  }
}
