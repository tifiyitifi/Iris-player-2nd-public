import 'dart:convert';

import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/engine/bg_tag_sync_logic.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/model/domain/media_ratio.dart';
import 'package:iris/features/background_playback/model/domain/segment_edit_draft.dart';
import 'package:iris/features/background_playback/model/enum/align_ring_assignment.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_default.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_gate_stop_behavior.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_bar_align.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/model/enum/bg_queue_sync_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_reactivate_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/bg_step_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_sticky_consume.dart';
import 'package:iris/features/background_playback/model/enum/bg_video_layout.dart';
import 'package:iris/features/background_playback/model/enum/bg_vm_scope_mode.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/model/enum/ratio_scope.dart';
import 'package:iris/features/background_playback/resolver/fg_display_window.dart';
import 'package:iris/features/background_playback/resolver/segment_snap.dart';
import 'package:iris/features/background_playback/resolver/segment_span_math.dart';
import 'package:iris/features/background_playback/resolver/vm_tiled_plan.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/background_playback/services/background_sync_logic.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/meta_settings/data/value_codec.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/store/persistent_store.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyStore);

/// State holder of the 副音播放 subsystem.
///
/// The engine (BackgroundPlaybackScope) is a widget-layer observer: it watches
/// [BackgroundPlaybackState.enabled]/[currentIndex]/[queue] and opens files;
/// this store never talks to a player directly. Natural completion and user
/// navigation both funnel through [step]/[setPlaying] here so queue math has
/// exactly one home.
class BackgroundPlaybackStore extends PersistentStore<BackgroundPlaybackState> {
  BackgroundPlaybackStore() : super(const BackgroundPlaybackState());

  static const _key = KvKeys.backgroundPlaybackState;

  // ── Session lifecycle ──

  /// Starts background playback from a concrete candidate list (never empty).
  /// Default shuffle applies here so the very first 副音 play is random.
  ///
  /// [applyScope] records the 作用范围 of this run (defaults to the persisted
  /// preference); [anchorKey] is the media a non-`all` run applies to.
  ///
  /// [focusControl] hands the shared controls to the new engine immediately.
  /// It follows [BackgroundPlaybackState.autoFocusControl], so the meta switch
  /// is the single authority over whether starting 副音 steals the controls.
  ///
  /// [autoplay] seeds [BackgroundPlaybackState.bgAutoPlay]; auto-start callers
  /// pass the foreground's live transport so a paused foreground is never
  /// force-resumed by a 副音 activation.
  Future<void> enableWithQueue(
    List<FileItem> files, {
    BgApplyScope? applyScope,
    String? anchorKey,
    bool? focusControl,
    bool autoplay = true,
  }) async {
    if (files.isEmpty) {
      _log.w('enableWithQueue: empty candidate list refused');
      return;
    }
    final ordered = state.shuffle
        ? BackgroundQueueLogic.shuffled(files)
        : List<FileItem>.of(files);
    // The queue keeps the foreground's own file (it is the 音库 source for the
    // NEXT foreground); the same-file guard only decides where playback STARTS.
    final startIndex = BackgroundQueueLogic.pickStartIndex(
      queue: ordered,
      excludedKey: excludedForegroundKey(),
    );
    final bool focus = focusControl ?? state.autoFocusControl;
    final scope = applyScope ?? state.applyScope;
    set(state.copyWith(
      enabled: true,
      gateOpen: true,
      controlTarget:
          focus ? ControlTarget.background : ControlTarget.foreground,
      displayTarget: ControlTarget.foreground,
      applyScope: scope,
      scopeAnchorKey:
          scope == BgApplyScope.all ? null : (anchorKey ?? currentScopeKey()),
      bgOffMediaKeys: const <String>{},
      queue: ordered,
      currentIndex: startIndex,
      bgAutoPlay: autoplay,
      alignMode: modeForAlignDefault(state.alignDefault),
      bgExhausted: false,
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedSilenceOn: false,
      mappedExitAdvanced: false,
    ));
    await save(state);
  }

  /// Full stop (the quick bar's power switch / the float panel's X): the engine
  /// is stopped by the scope, the control target returns to the foreground
  /// player and the queue position is cleared so a later enable starts clean.
  Future<void> disable() async {
    set(state.copyWith(
      enabled: false,
      gateOpen: false,
      controlTarget: ControlTarget.foreground,
      displayTarget: ControlTarget.foreground,
      bgAutoPlay: false,
      bgExhausted: false,
      currentIndex: -1,
      scopeAnchorKey: null,
      alignOffsetMs: null,
      openQuickPanel: BgQuickPanel.none,
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedSilenceOn: false,
      mappedExitAdvanced: false,
      segmentEditMode: false,
      segmentEditDraft: null,
      segmentEditStageOnly: false,
    ));
    await save(state);
  }

  // ── Gate / feature (开机状态) ──

  /// Arms the run WITHOUT playing anything: the engine is built, but no file is
  /// loaded, [BackgroundPlaybackState.bgAutoPlay] stays false and the gate stays
  /// CLOSED. This is the "feature on, stopped" state of a fresh launch
  /// ([BackgroundPlaybackState.startArmed]) and of the 副音 menu's ON row. No
  /// scope/映射 auto-start may fire until the user opens the gate from the quick
  /// bar ("用户按快速栏播放后才允许自动").
  void armRunStopped() {
    if (state.enabled) return;
    set(state.copyWith(
      enabled: true,
      gateOpen: false,
      bgAutoPlay: false,
      currentIndex: -1,
      controlTarget: ControlTarget.foreground,
      displayTarget: ControlTarget.foreground,
      bgExhausted: false,
      alignOffsetMs: null,
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedSilenceOn: false,
      mappedExitAdvanced: false,
    ));
  }

  /// Explicit gate stop (quick-bar gate OFF / the bg stop button): stop playing
  /// and latch the gate closed so NO scope auto-resumes or auto-starts 副音
  /// until the user opens the gate again. The run (enabled, queue, index,
  /// anchor) and the warm engine always survive — this is never a [disable].
  ///
  /// A deactivation leaves the pair fully independent WITHOUT rewriting the
  /// linkage preferences ([BackgroundPlaybackState.seekLink]/
  /// [BackgroundPlaybackState.lockLevel] keep their values, so the next
  /// activation resumes the saved behavior): the shared controls and the
  /// picture are handed back to the FOREGROUND, and every fg↔bg mirror already
  /// stands down on the closed gate — so at runtime the two run in sync with
  /// nothing, exactly like 完全独立.
  ///
  /// The mapped/silence override is dropped here too ("统一退出"): a gate stop
  /// must always leave 副音 unable to sound, regardless of the E 节 state it
  /// interrupted. How much media state is released is the runtime's choice,
  /// driven by [BackgroundPlaybackState.gateStopBehavior] (pause vs unload).
  void stopGate() {
    if (!state.enabled) return;
    set(state.copyWith(
      gateOpen: false,
      bgAutoPlay: false,
      controlTarget: ControlTarget.foreground,
      displayTarget: ControlTarget.foreground,
      alignOffsetMs: null,
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedSilenceOn: false,
      mappedExitAdvanced: false,
    ));
  }

  /// Gate open for the current foreground: permits playback, clears [mediaKey]'s
  /// opt-out, re-anchors a [BgApplyScope.currentOnly] run and re-aligns.
  /// [stepForward] walks the queue one step (wrap) first — the「仅当前」
  /// [BgReactivateMode.nextBg] behavior; false keeps the loaded file
  /// ([BgReactivateMode.sameBg]). Session-only, no write.
  ///
  /// Activation follows [BackgroundPlaybackState.autoFocusControl] (the 开启
  /// 副音时先切换控制权 preference): with it on, the shared controls move to
  /// 副音, mirroring the first [enableWithQueue]. The picture is never stolen
  /// — the display target stays wherever it was.
  ///
  /// [autoplay] is the transport the activation lands on: the gate is a
  /// PERMISSION, not a play command, so a caller that activates while the
  /// foreground is paused passes `false` — the run loads paused and the pair's
  /// transport is left untouched (the fg is never force-resumed).
  void openGate({
    String? mediaKey,
    bool stepForward = false,
    bool autoplay = true,
  }) {
    if (!state.enabled) return;
    final int nextIndex;
    if (state.queue.isEmpty) {
      nextIndex = -1;
    } else if (state.currentIndex < 0) {
      // A queue that never started (a fresh enable, or one whose only member
      // is the foreground file) still has to land somewhere playable — the
      // queue itself is the complete pool, so the head is NOT automatically
      // safe to open.
      nextIndex = BackgroundQueueLogic.pickStartIndex(
        queue: state.queue,
        excludedKey: excludedForegroundKey(),
      );
    } else if (stepForward) {
      // 下一首 re-activation walks the queue through the SAME step math as a
      // manual step, so the foreground double-play guard ([excludedForegroundKey])
      // applies here too. Repeat.one normalizes to all (a user re-activation
      // always advances); a fully-excluded queue keeps the loaded track.
      nextIndex = BackgroundQueueLogic.stepIndex(
            queue: state.queue,
            current: state.currentIndex,
            forward: true,
            repeat: Repeat.all,
            excludedKey: excludedForegroundKey(),
          ) ??
          state.currentIndex;
    } else {
      nextIndex = state.currentIndex;
    }
    final bool hasKey = mediaKey != null && mediaKey.isNotEmpty;
    set(state.copyWith(
      gateOpen: true,
      bgAutoPlay: autoplay,
      controlTarget: state.autoFocusControl
          ? ControlTarget.background
          : state.controlTarget,
      currentIndex: nextIndex,
      bgOffMediaKeys:
          hasKey ? (Set<String>.of(state.bgOffMediaKeys)..remove(mediaKey)) : state.bgOffMediaKeys,
      scopeAnchorKey:
          hasKey && state.applyScope == BgApplyScope.currentOnly
              ? mediaKey
              : state.scopeAnchorKey,
      bgRunSeq: state.bgRunSeq + 1,
      bgExhausted: false,
      alignOffsetMs: null,
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedSilenceOn: false,
      mappedExitAdvanced: false,
    ));
  }

  // ── A-中心-B 段编辑器 (session-only) ──

  /// Enters A-B editing: publishes [draft], pauses 副音 and hands the shared
  /// controls back to the FOREGROUND (the editor draws the fg axis). The
  /// foreground pause is issued by the entry point (the store has no foreground
  /// player); every freeze guard reads [segmentEditMode].
  ///
  /// The editor's background selection IS the live queue: prev/next and the
  /// queue panel both operate on [BackgroundPlaybackState.queue], so the file
  /// under edit is always the file being heard. There is no separate session
  /// candidate pool.
  void enterSegmentEdit(
    SegmentEditDraft draft, {
    bool stageOnly = false,
  }) {
    if (!state.enabled) return;
    set(state.copyWith(
      segmentEditMode: true,
      segmentEditDraft: draft,
      segmentEditStageOnly: stageOnly,
      bgAutoPlay: false,
      controlTarget: ControlTarget.foreground,
    ));
  }

  /// Replaces the in-progress span while editing (drag ticks). No-op when the
  /// editor is closed.
  void updateSegmentEditDraft(SegmentEditDraft draft) {
    if (!state.segmentEditMode) return;
    set(state.copyWith(segmentEditDraft: draft));
  }

  /// Leaves A-B editing and restores transport. Never persists a draft —
  /// saving is the editor's explicit command.
  void exitSegmentEdit() {
    if (!state.segmentEditMode && state.segmentEditDraft == null) return;
    set(state.copyWith(
      segmentEditMode: false,
      segmentEditDraft: null,
      segmentEditStageOnly: false,
    ));
  }

  // ── Engine-facing session controls ──

  void setPlaying(bool playing) {
    if (!state.enabled || !state.gateOpen) return;
    set(state.copyWith(bgAutoPlay: playing));
  }

  /// Walks the queue (see [BackgroundQueueLogic.stepIndex]). [excludedKey] is
  /// the foreground current file's key — the double-play guard. Returns false
  /// when no eligible next item exists (caller pauses instead of looping onto
  /// the foreground file).
  ///
  /// [userInitiated] marks a MANUAL switch (queue panel, control bar,
  /// keyboard via the router): it raises the one-shot [userBgSwitchSeq]
  /// signal so the VM link can ask how the current segment should remember
  /// it. System moves (tiling, scope, mapping, completion) leave it false.
  Future<bool> step({
    required bool forward,
    String? excludedKey,
    bool userInitiated = false,
  }) async {
    if (!state.enabled) return false;
    // A-B editor open: transport is frozen — prev/next is a hard no-op. The
    // editor exists only to align and save/discard the current pair, so it must
    // never swap the file out from under the span being adjusted.
    if (state.segmentEditMode) return false;
    // A mapped playMedia segment owns the audible output, but a user step
    // stays legal: abandon the override with the abort latch (the scope sees
    // it and skips its own exit step) and advance the natural queue exactly
    // once below. The foreground is never touched; the new file goes through
    // the normal alignment chain (pause + ask when it needs aligning).
    if (state.mappedFile != null) _abandonMappedForUserStep();
    // User navigation treats Repeat.one like Repeat.all (wrap) — replaying is
    // a natural-completion behavior only.
    final effectiveRepeat =
        state.bgRepeat == Repeat.one ? Repeat.all : state.bgRepeat;
    final idx = BackgroundQueueLogic.stepIndex(
      queue: state.queue,
      current: state.currentIndex,
      forward: forward,
      repeat: effectiveRepeat,
      excludedKey: excludedKey,
    );
    if (idx == null) {
      // End of queue (repeat none) or every candidate collides with the
      // foreground file — stop advancing but keep the current media loaded.
      set(state.copyWith(bgAutoPlay: false));
      return false;
    }
    // A discrete step always bumps the event seq (even a single-item wrap that
    // keeps the same index): the runtime observer uses it to keep the step out
    // of the position mirror under BgStepMode.swapOnly.
    // Session-only fields (currentIndex / bgStepSeq) — the persisted snapshot
    // is unchanged, so this must not pay a secure-storage write on the step
    // hot path.
    set(state.copyWith(
      currentIndex: idx,
      bgStepSeq: state.bgStepSeq + 1,
      bgUserAlignSeq:
          userInitiated ? state.bgUserAlignSeq + 1 : state.bgUserAlignSeq,
      userBgSwitchSeq:
          userInitiated ? state.userBgSwitchSeq + 1 : state.userBgSwitchSeq,
      userBgSwitchIndex: userInitiated ? idx : state.userBgSwitchIndex,
    ));
    return true;
  }

  /// Natural completion of the current media. [Repeat.one] replays the same
  /// file (index unchanged); otherwise [step] forward with the real repeat
  /// rules.
  ///
  /// Returns `true` when the same file should be replayed in place (repeat-one,
  /// or a single-track queue wrapped back onto itself under repeat-all/none).
  /// Returns `false` when the queue advanced to a different file (the open
  /// effect re-fires on that [fileKey] change) or playback stopped (repeat-none
  /// at the end).
  Future<bool> advanceOnCompleted({String? excludedKey}) async {
    if (state.bgRepeat == Repeat.one && state.currentIndex >= 0) {
      set(state.copyWith(
        bgAutoPlay: true,
        bgStepSeq: state.bgStepSeq + 1,
      ));
      return true;
    }
    final prevIndex = state.currentIndex;
    final moved = await step(forward: true, excludedKey: excludedKey);
    if (!moved) {
      set(state.copyWith(bgAutoPlay: false));
      return false;
    }
    // Stepping wrapped back onto the very same index (a one-item queue under
    // repeat-all/none). Since the file identity didn't change, the open effect
    // won't re-fire — the caller must replay it in place.
    return state.currentIndex == prevIndex;
  }

  // ── Prefs ──

  Future<void> cycleTarget() async {
    if (!state.enabled || !state.gateOpen) return;
    set(state.copyWith(
      controlTarget: state.controlTarget == ControlTarget.background
          ? ControlTarget.foreground
          : ControlTarget.background,
    ));
    await save(state);
  }

  Future<void> setShowBgVideo(bool value) async {
    set(state.copyWith(showBgVideo: value));
    await save(state);
  }

  /// Persists the 副音 video-surface layout choice. Only `fullscreen` has a
  /// behavior today; `pip`/`split` are stored placeholders (no visual change).
  Future<void> setBgVideoLayout(BgVideoLayout value) async {
    set(state.copyWith(bgVideoLayout: value));
    await save(state);
  }

  /// Collapse/expand of the float panel (pill). Never stops 副音 playback —
  /// closing the subsystem is the X button / [disable] only.
  Future<void> setPanelVisible(bool value) async {
    if (!state.enabled) return;
    set(state.copyWith(bgPanelVisible: value));
  }

  /// Foreground media switch → re-resolve mapping of the new foreground file.
  /// The resolver (P5) reads this; the row is here so the pref persists with
  /// the subsystem's own state.
  Future<void> setFollowFgSwitch(bool value) async {
    set(state.copyWith(bgFollowsFgSwitch: value));
    await save(state);
  }

  /// Natural-playback rate lock (bg follows the foreground app rate).
  Future<void> setRateLock(bool value) async {
    set(state.copyWith(bgRateLock: value));
    await save(state);
  }

  /// Same-file double-play guard override (default OFF = still guarded).
  Future<void> setAllowSameFgBgFile(bool value) async {
    set(state.copyWith(allowSameFgBgFile: value));
    await save(state);
  }

  // ── Startup preload (sub_media §1) ──

  /// Toggles the always-present secondary engine (default ON).
  Future<void> setKeepWarmPlayer(bool value) async {
    set(state.copyWith(keepWarmPlayer: value));
    await _writeAux(
      _kAuxKeepWarm,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// 开机状态: whether the 副音 feature is armed (on, stopped) at launch.
  /// Independent of [setKeepWarmPlayer]. A runtime change only takes effect on
  /// the NEXT launch — it never arms or disarms the current session.
  Future<void> setStartArmed(bool value) async {
    set(state.copyWith(startArmed: value));
    await _writeAux(
      _kAuxStartArmed,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// What the quick-bar gate / bg stop button does on close (pause vs unload).
  /// Applies to the NEXT gate stop; the persisted row lives in `bg.` AUX.
  Future<void> setGateStopBehavior(BgGateStopBehavior value) async {
    set(state.copyWith(gateStopBehavior: value));
    await _writeAux(_kAuxGateStopBehavior, value.name);
  }

  // ── 对齐默认方案 ──

  /// Remembers (or clears, with [BgAlignDefault.ask]) the "bg shorter than fg"
  /// alignment choice so the prompt does not re-appear.
  Future<void> setAlignDefault(BgAlignDefault value) async {
    set(state.copyWith(alignDefault: value));
    await _writeAux(_kAuxAlignDefault, value.name);
  }

  // ── 作用范围: 仅当前 / 智能 / 全部 ──

  /// Records the 作用范围 preference. Persisted via AUX; the cold load only
  /// honours it while [scopePersist] is on.
  Future<void> setApplyScope(BgApplyScope scope) async {
    set(state.copyWith(
      applyScope: scope,
      scopeAnchorKey: scope == BgApplyScope.all ? null : state.scopeAnchorKey,
    ));
    await _writeAux(_kAuxApplyScope, scope.name);
  }

  /// Whether the 作用范围 choice survives a restart ("跨重启保存").
  Future<void> setScopePersist(bool value) async {
    set(state.copyWith(scopePersist: value));
    await _writeAux(
      _kAuxScopePersist,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// What a「仅当前」re-activation lands on (same bg / next bg). `bg.reactivateMode`.
  Future<void> setBgReactivateMode(BgReactivateMode value) async {
    set(state.copyWith(bgReactivateMode: value));
    await _writeAux(_kAuxReactivateMode, value.name);
  }

  /// Anchors a non-`all` run to [mediaKey].
  void setScopeAnchor(String? mediaKey) {
    set(state.copyWith(scopeAnchorKey: mediaKey));
  }

  /// Quick-bar "对当前": applies 副音 to [mediaKey] and RESUME on it.
  ///
  /// Re-anchors a [BgApplyScope.currentOnly] run to [mediaKey] so the switch
  /// reflects reality after a foreground media switch — without this the
  /// anchor stayed on the old media and the toggle could never report "on"
  /// again (第 4 轮问题 2: "点一次就丢目标").
  ///
  /// [autoplay] follows the foreground's live transport when this is an
  /// automatic (scope/saved-pairing) entry: a paused foreground must not be
  /// force-resumed by the auto-apply.
  void applyToCurrent(String? mediaKey, {bool autoplay = true}) {
    if (!state.enabled || mediaKey == null || mediaKey.isEmpty) return;
    final next = Set<String>.of(state.bgOffMediaKeys)..remove(mediaKey);
    set(state.copyWith(
      bgOffMediaKeys: next,
      gateOpen: true,
      bgAutoPlay: autoplay,
      scopeAnchorKey: state.applyScope == BgApplyScope.currentOnly
          ? mediaKey
          : state.scopeAnchorKey,
    ));
    // Explicit "use bg for THIS fg": clear the old queue progress and
    // re-align instead of continuing mid-queue.
    restartForCurrent();
  }

  /// 副音 left its anchored media — pause but keep the subsystem alive.
  void pauseForScope() {
    if (!state.enabled) return;
    set(state.copyWith(bgAutoPlay: false));
  }

  /// 副音 came back to its anchored media — resume. Suppressed while the user
  /// gate is closed: an explicit stop must survive every scope and media switch
  /// until the gate is opened again.
  ///
  /// [play] is the foreground's live transport: a return to the anchor while
  /// the video is paused opens nothing to sound (the transport mirror owns the
  /// later resume).
  void resumeForScope({bool play = true}) {
    if (!state.enabled || !state.gateOpen) return;
    set(state.copyWith(bgAutoPlay: play));
  }

  /// 关闭副音（仅当前）: this media opts out of 副音.
  ///
  /// Independent of the all-media scope — other media keep using 副音, and the
  /// 「全部」row keeps offering to enable (第 3 轮问题 1/2).
  ///
  /// The controls are handed back to the video as well: with nothing playing on
  /// 副音 for this media, leaving the bar targeted at it only produced a frame
  /// around a silent engine — the user pressed "close" and saw nothing close.
  void closeScopeForMedia(String? mediaKey) {
    if (!state.enabled || mediaKey == null || mediaKey.isEmpty) return;
    set(state.copyWith(
      bgOffMediaKeys: {...state.bgOffMediaKeys, mediaKey},
      bgAutoPlay: false,
      controlTarget: ControlTarget.foreground,
    ));
  }

  /// Focuses the shared controls on 副音 (used when the user explicitly turns
  /// a scope ON — 第 3 轮问题 4). No-op while the gate is closed: deactivation
  /// owns the foreground target, and the retarget UI is greyed there anyway.
  void setControlTarget(ControlTarget target) {
    if (!state.enabled || !state.gateOpen) return;
    if (state.controlTarget == target) return;
    set(state.copyWith(controlTarget: target));
  }

  // ── 进度锁定 (第 3 轮问题 3) ──

  /// Whether a foreground seek drags 副音 with it (`bg.seekLink`).
  Future<void> setSeekLink(BgSeekLink value) async {
    set(state.copyWith(seekLink: value));
    await _writeAux(_kAuxSeekLink, value.name);
  }

  /// How much of the transport mirrors the foreground (`bg.lockLevel`).
  Future<void> setLockLevel(BgLockLevel value) async {
    set(state.copyWith(lockLevel: value));
    await _writeAux(_kAuxLockLevel, value.name);
  }

  /// 换集行为: whether a user step on 副音 also moves the foreground
  /// (`bg.stepMode`). Independent of the seek-link axis.
  Future<void> setStepMode(BgStepMode value) async {
    set(state.copyWith(stepMode: value));
    await _writeAux(_kAuxStepMode, value.name);
  }

  /// Side-type align dial: which ring hosts the foreground media.
  Future<void> setAlignRingAssignment(AlignRingAssignment value) async {
    set(state.copyWith(alignRingAssignment: value));
    await MetaSettingsModule.saveDialRingRow(_kAuxAlignRing, value.name);
  }

  /// Flip the foreground ring between inner and outer radius.
  Future<void> toggleAlignRingAssignment() => setAlignRingAssignment(
        state.alignRingAssignment == AlignRingAssignment.fgInner
            ? AlignRingAssignment.fgOuter
            : AlignRingAssignment.fgInner,
      );

  /// Remembered "start at this share" (%) for the alignment prompt.
  Future<void> setAlignPercent(int percent) async {
    final v = percent.clamp(0, 100);
    set(state.copyWith(alignPercent: v));
    await _writeAux(
      _kAuxAlignPercent,
      ValueCodec.encode(SettingValueType.int, v),
    );
  }

  /// Remaining-副音 threshold (seconds) below which the alignment popup is
  /// raised (`bg.alignAutoPauseRemainSec`), clamped to 1..120. The popup is
  /// raised only under [BgExhaustedAction.stopRestoreFg]; under
  /// [BgExhaustedAction.nextBg] the continuation is automatic, so the runtime
  /// observer never interrupts playback with it (see `shouldRaiseAlignThreshold`).
  Future<void> setAlignAutoPauseRemainSec(int seconds) async {
    final v = clampAlignWarnRemainSec(seconds);
    set(state.copyWith(alignAutoPauseRemainSec: v));
    await _writeAux(
      _kAuxAlignAutoPauseSec,
      ValueCodec.encode(SettingValueType.int, v),
    );
  }

  /// What happens when the current 副音 file finishes (`bg.exhaustedAction`).
  Future<void> setBgExhaustedAction(BgExhaustedAction value) async {
    set(state.copyWith(
      bgExhaustedAction: value,
      // Picking "keep playing" clears a terminal restore so the pair resumes.
      bgExhausted: value == BgExhaustedAction.nextBg
          ? false
          : state.bgExhausted,
    ));
    await _writeAux(_kAuxExhaustedAction, value.name);
  }

  /// Marks the run terminal under [BgExhaustedAction.stopRestoreFg]: 副音 is
  /// stopped and the foreground returns to its own (un-ducked) volume. Session
  /// only, no write.
  void markBgExhausted() {
    if (!state.enabled) return;
    set(state.copyWith(bgExhausted: true, bgAutoPlay: false));
  }

  /// Clears the terminal restore (a new run/alignment resumes normal ducking).
  void clearBgExhausted() {
    if (!state.bgExhausted) return;
    set(state.copyWith(bgExhausted: false));
  }

  /// Physical minimum length of an A–B segment (`bg.minSegmentSpanMs`), in
  /// milliseconds. Clamped to 100..5000 — below 100 ms a segment is not
  /// perceptible, and a larger minimum would swallow most segments.
  Future<void> setMinSegmentSpanMs(int ms) async {
    final v = ms.clamp(kMinMinSegmentSpanMs, kMaxMinSegmentSpanMs);
    set(state.copyWith(minSegmentSpanMs: v));
    await _writeAux(
      _kAuxMinSegmentSpanMs,
      ValueCodec.encode(SettingValueType.int, v),
    );
  }

  /// Whether P keeps a window's maximum length when a reverse drag reaches the
  /// boundary-hit point (`bg.pAlignKeepMaxLength`). True carries the window off
  /// the boundary; false keeps re-mapping the other end.
  Future<void> setPAlignKeepMaxLength(bool value) async {
    set(state.copyWith(pAlignKeepMaxLength: value));
    await _writeAux(
      _kAuxPAlignKeepMaxLength,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// Which handles spend a bundled pile before translating
  /// (`bg.stickyConsume`). Orthogonal to [setPAlignKeepMaxLength]: this decides
  /// WHETHER a drag spends a pile, that one decides HOW FAR (seal or zero).
  Future<void> setStickyConsume(BgStickyConsume value) async {
    set(state.copyWith(stickyConsume: value));
    await _writeAux(_kAuxStickyConsume, value.name);
  }

  /// APB foreground zoom multiplier (`bg.fgWindowZoom`): the align editor shows
  /// `zoom × bgDur` of foreground so the A–B mapping stays readable. Clamped to
  /// 1.0..10.0; 1.0 disables the zoom.
  Future<void> setFgWindowZoom(double zoom) async {
    final v = zoom.clamp(FgDisplayWindowMath.kMinZoom,
        FgDisplayWindowMath.kMaxZoom);
    set(state.copyWith(fgWindowZoom: v));
    await _writeAux(
      _kAuxFgWindowZoom,
      ValueCodec.encode(SettingValueType.double, v),
    );
  }

  /// Whether the q handle's pan pushes the mapping at the A/B boundary
  /// (`bg.fgWindowPushBg`). False clamps the pan; true slides the alignment.
  Future<void> setFgWindowPushBg(bool value) async {
    set(state.copyWith(fgWindowPushBg: value));
    await _writeAux(
      _kAuxFgWindowPushBg,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// Snap-to-saved-boundary (卡值） mode (`bg.snapEnabled`): A / P / B stop
  /// exactly at saved segment boundaries like at the 0% / 100% ends.
  Future<void> setSnapEnabled(bool value) async {
    set(state.copyWith(snapEnabled: value));
    await _writeAux(
      _kAuxSnapEnabled,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// How many recently released snap walls stay passable
  /// (`bg.snapReleaseLimit`). Clamped to 1..10000.
  Future<void> setSnapReleaseLimit(int n) async {
    final v = n.clamp(
        SegmentSnap.kMinReleaseLimit, SegmentSnap.kMaxReleaseLimit);
    set(state.copyWith(snapReleaseLimit: v));
    await _writeAux(
      _kAuxSnapReleaseLimit,
      ValueCodec.encode(SettingValueType.int, v),
    );
  }

  /// 跨视频开关 (新列表项): what 副音 does when the foreground moves to a new
  /// LIST ITEM (real media or a whole virtual-merged item). `bg.itemSwitch`.
  Future<void> setBgItemSwitch(BgCrossAction value) async {
    set(state.copyWith(bgItemSwitch: value));
    await _writeAux(_kAuxItemSwitch, value.name);
  }

  /// 跨视频开关 (虚拟视频内部切段): what 副音 does when a virtual video switches
  /// to a different physical segment. `bg.segmentSwitch`.
  Future<void> setBgSegmentSwitch(BgCrossAction value) async {
    set(state.copyWith(bgSegmentSwitch: value));
    await _writeAux(_kAuxSegmentSwitch, value.name);
  }

  /// Session-only VM-session flag published by the VM link, so a VM block
  /// switch is never mistaken for a real list-item change. Never persisted.
  void setVmSessionActive(bool value) {
    if (state.vmSessionActive == value) return;
    set(state.copyWith(vmSessionActive: value));
  }

  /// How 作用范围「仅当前」reads a Virtual Media foreground (`bg.vmScopeMode`).
  Future<void> setBgVmScopeMode(BgVmScopeMode value) async {
    set(state.copyWith(bgVmScopeMode: value));
    await _writeAux(_kAuxVmScopeMode, value.name);
  }

  /// Session-only 作用范围 identity published by the VM link (see
  /// [BackgroundPlaybackState.vmScopeKeyOverride]). Never persisted: it is
  /// meaningless outside the live VM session that owns it.
  void setVmScopeOverride(String? key) {
    final next = (key == null || key.isEmpty) ? null : key;
    if (state.vmScopeKeyOverride == next) return;
    set(state.copyWith(vmScopeKeyOverride: next));
  }

  /// Restarts the runtime observer's per-run alignment chain — called when a
  /// VM block with a SAVED mapping is left, so the following blocks re-align
  /// from 00:00 instead of chaining onto the mapped block.
  void bumpVmAlignReset() {
    set(state.copyWith(vmAlignResetSeq: state.vmAlignResetSeq + 1));
  }

  /// Records a per-segment override of the wholeVirtual tiled plan for THIS
  /// app launch only (align-dialog pick, mapping-editor save, or a
  /// dialog-confirmed manual bg switch on that segment). Empty keys are
  /// refused; session-only, so no persistence write. Bumps [vmTiledSeq] so
  /// the VM link re-resolves the entrance target.
  void recordVmTiledOverride(String segmentKey, VmTiledSlot slot) {
    if (segmentKey.isEmpty) return;
    set(state.copyWith(
      vmTiledOverrides: {...state.vmTiledOverrides, segmentKey: slot},
      vmTiledSeq: state.vmTiledSeq + 1,
    ));
  }

  /// Drops every tiled-plan override — called when the VM session ends or a
  /// different virtual item is entered without carrying overrides over.
  void clearVmTiledOverrides() {
    if (state.vmTiledOverrides.isEmpty) return;
    set(state.copyWith(
      vmTiledOverrides: const <String, VmTiledSlot>{},
      vmTiledSeq: state.vmTiledSeq + 1,
    ));
  }

  /// Lock-mapping rollover: a foreground seek that maps onto a DIFFERENT 副音
  /// file. Selects the queue entry and queues a one-shot seek the scope lands
  /// once that file has opened. Same-file targets never come through here.
  Future<void> requestLockTarget({
    required int index,
    required int targetMs,
  }) async {
    if (!state.enabled) return;
    if (index < 0 || index >= state.queue.length) return;
    // Session-only fields — nothing persistent changed, so skip the write.
    // A lock rollover is a SYSTEM seek (same shape as a tiled entrance):
    // raise the system-seek seq so the runtime observer swallows the landing
    // instead of mirroring it back onto the foreground.
    set(state.copyWith(
      currentIndex: index,
      lockTargetIndex: index,
      lockSeekTargetMs: targetMs < 0 ? 0 : targetMs,
      lockSeekSeq: state.lockSeekSeq + 1,
      bgSystemSeekSeq: state.bgSystemSeekSeq + 1,
    ));
  }

  // ── 快速控制栏 (第 3 轮问题 5) ──

  Future<void> setQuickBarEnabled(bool value) async {
    set(state.copyWith(
      quickBarEnabled: value,
      // Hiding the bar must not leave a dangling floating card behind — its
      // opener is gone, and the card is only reachable from the bar.
      openQuickPanel: value ? state.openQuickPanel : BgQuickPanel.none,
    ));
    await _writeAux(
      _kAuxQuickBar,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  Future<void> setQuickBarAlign(BgQuickBarAlign value) async {
    set(state.copyWith(quickBarAlign: value));
    await _writeAux(_kAuxQuickBarAlign, value.name);
  }

  // ── 快速栏浮窗 (第 4 轮问题 3/4) ──

  /// Opens one non-modal quick card (closing any other). Session-only.
  void showQuickPanel(BgQuickPanel panel) {
    if (!state.enabled) return;
    if (state.openQuickPanel == panel) return;
    set(state.copyWith(openQuickPanel: panel));
  }

  /// Closes whichever quick card is open.
  void closeQuickPanel() {
    if (state.openQuickPanel == BgQuickPanel.none) return;
    set(state.copyWith(openQuickPanel: BgQuickPanel.none));
  }

  /// Quick-button behavior: opens [panel], or closes it when already open.
  void toggleQuickPanel(BgQuickPanel panel) {
    if (state.openQuickPanel == panel) {
      closeQuickPanel();
      return;
    }
    showQuickPanel(panel);
  }

  /// Whether starting 副音 takes the shared controls (第 3 轮追加需求).
  Future<void> setAutoFocusControl(bool value) async {
    set(state.copyWith(autoFocusControl: value));
    await _writeAux(
      _kAuxAutoFocus,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  // ── Display target (sub_media §5.3) ──

  /// Flips which engine's picture the surface shows — independent of
  /// [BackgroundPlaybackState.controlTarget]. No-op while the gate is closed:
  /// deactivation owns the foreground picture.
  Future<void> cycleDisplayTarget() async {
    if (!state.enabled || !state.gateOpen) return;
    set(state.copyWith(
      displayTarget: state.displayTarget == ControlTarget.background
          ? ControlTarget.foreground
          : ControlTarget.background,
    ));
  }

  Future<void> setDisplayTarget(ControlTarget target) async {
    if (!state.enabled || !state.gateOpen) return;
    set(state.copyWith(displayTarget: target));
  }

  // ── Volume ratio (sub_media §5.5) ──

  /// Clears/restores "use the saved ratio" (false = both sides at master).
  Future<void> setVolumeRatioEnabled(bool value) async {
    set(state.copyWith(volumeRatioEnabled: value));
    await _writeAux(
      _kAuxRatioEnabled,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  /// Meta switch: true = the ratio dialog commits only on Save; false = live
  /// drag, committed when the finger lifts.
  Future<void> setRatioExplicitSave(bool value) async {
    set(state.copyWith(ratioExplicitSave: value));
    await _writeAux(
      _kAuxRatioExplicit,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  Future<void> setRatioScope(RatioScope value) async {
    set(state.copyWith(ratioScope: value));
    await _writeAux(_kAuxRatioScope, value.name);
  }

  /// Writes the GLOBAL pair (also edited by the float panel's two tracks).
  Future<void> setGlobalRatio(MediaRatio ratio) async {
    final clamped = MediaRatio(
      fgPercent: ratio.fgPercent.clamp(0, 100),
      bgPercent: ratio.bgPercent.clamp(0, 100),
    );
    set(state.copyWith(
      fgVolumePercent: clamped.fgPercent,
      bgVolumePercent: clamped.bgPercent,
    ));
    await save(state);
  }

  /// Writes the per-media override for [mediaKey] (仅当前 scope).
  Future<void> setMediaRatio(String mediaKey, MediaRatio ratio) async {
    if (mediaKey.isEmpty) return;
    final clamped = MediaRatio(
      fgPercent: ratio.fgPercent.clamp(0, 100),
      bgPercent: ratio.bgPercent.clamp(0, 100),
    );
    set(state.copyWith(
      perMediaRatio: {...state.perMediaRatio, mediaKey: clamped},
    ));
    await _writeAux(
      '$_kAuxRatioItemPrefix$mediaKey',
      ValueCodec.encode(SettingValueType.json, clamped.toJson()),
    );
  }

  /// Drops the per-media override so the media falls back to the global pair.
  Future<void> clearMediaRatio(String mediaKey) async {
    if (mediaKey.isEmpty) return;
    final next = Map<String, MediaRatio>.of(state.perMediaRatio)
      ..remove(mediaKey);
    set(state.copyWith(perMediaRatio: next));
    await _deleteAux('$_kAuxRatioItemPrefix$mediaKey');
  }

  /// Writes [ratio] to whichever layer [BackgroundPlaybackState.ratioScope]
  /// currently points at — the shared edit path of the float panel tracks and
  /// the ratio dialog.
  Future<void> applyRatio({
    required String? fgKey,
    required MediaRatio ratio,
  }) async {
    if (state.ratioScope == RatioScope.current &&
        fgKey != null &&
        fgKey.isNotEmpty) {
      await setMediaRatio(fgKey, ratio);
      return;
    }
    await setGlobalRatio(ratio);
  }

  // ── Mapping timeline commands (E 节; executed by the scope effects) ──

  Future<void> setMappingEnabled(bool value) async {
    if (!value && state.enabled) {
      if (state.mappedFile != null) {
        // Turning the switch off mid-segment = leaving a playMedia segment:
        // natural advances once and resumes.
        await exitMappedNatural();
      } else if (state.mappedSilenceOn) {
        // Leaving a silence segment: resume the paused natural file.
        await resumeNatural();
      }
    }
    set(state.copyWith(mappingEnabled: value));
    await _writeAux(
      _kAuxUseSavedMapping,
      ValueCodec.encode(SettingValueType.bool, value),
    );
  }

  Future<void> setIgnoreNoBg(bool value) async {
    if (!state.enabled) return;
    set(state.copyWith(ignoreNoBg: value));
    await save(state);
  }

  /// Enters a playMedia segment: bg opens [file] at [targetMs], plays with
  /// the segment's alignment [rate], while the natural queue keeps its index.
  Future<void> enterMappedSegment(
    FileItem file, {
    required int targetMs,
    required double rate,
    int? fgPercent,
    int? bgPercent,
  }) async {
    if (!state.enabled) return;
    set(state.copyWith(
      mappedFile: file,
      mappedExitAdvanced: false,
      mappedSilenceOn: false,
      mappedRate: rate,
      mappedFgPercent: fgPercent,
      mappedBgPercent: bgPercent,
      bgAutoPlay: true,
      mappedSeekTargetMs: targetMs,
      mappedSeekSeq: state.mappedSeekSeq + 1,
    ));
  }

  /// Proportional reposition inside the ACTIVE mapped segment.
  Future<void> requestMappedSeek(int targetMs) async {
    if (!state.enabled || state.mappedFile == null) return;
    if (targetMs < 0) targetMs = 0;
    set(state.copyWith(
      mappedSeekTargetMs: targetMs,
      mappedSeekSeq: state.mappedSeekSeq + 1,
    ));
  }

  /// Silence segment: pause bg in place (natural index untouched).
  Future<void> silenceHold() async {
    if (!state.enabled) return;
    set(state.copyWith(mappedSilenceOn: true, bgAutoPlay: false));
  }

  /// Leaving silence back to a gap: resume the paused natural file.
  Future<void> resumeNatural() async {
    if (!state.enabled) return;
    set(state.copyWith(mappedSilenceOn: false, bgAutoPlay: true));
  }

  /// User stepped/jumped the 副音 queue while a mapped playMedia segment owned
  /// the audible output: drop the override WITHOUT advancing (the caller
  /// advances exactly once itself) and latch the segment as aborted, so the
  /// scope will not re-enter it — or step again on exit — while the
  /// foreground stays inside. Transport flags are inherited untouched, so the
  /// newly opened natural file keeps the current play/pause state.
  void _abandonMappedForUserStep() {
    set(state.copyWith(
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedExitAdvanced: true,
      mappedSilenceOn: false,
    ));
  }

  /// Leaving a playMedia segment for a `silence` segment: drop the mapped
  /// override in place (abort latch, natural index untouched) — silence only
  /// pauses the runtime via [silenceHold], it never advances the queue.
  /// Contrast [exitMappedNatural], whose step belongs to the play → gap path.
  Future<void> exitMappedInPlace() async {
    if (!state.enabled) return;
    if (state.mappedFile == null) return;
    _abandonMappedForUserStep();
  }

  /// Leaving a playMedia segment (natural next, per §13 semantics) — or the
  /// mapped file finished early inside the segment (abort path).
  Future<void> exitMappedNatural() async {
    if (!state.enabled) return;
    // Advance the natural queue once, then hand back to natural playback.
    await step(forward: true, excludedKey: excludedForegroundKey());
    set(state.copyWith(
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedExitAdvanced: true,
      mappedSilenceOn: false,
      bgAutoPlay: true,
    ));
  }

  /// Natural end of the mapped file BEFORE the segment window completes:
  /// advance once and mark the segment aborted (host won't re-enter it while
  /// the foreground stays inside).
  Future<void> mappedCompletionEarly() async {
    if (!state.enabled) return;
    await step(forward: true, excludedKey: excludedForegroundKey());
    set(state.copyWith(
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedExitAdvanced: true,
      mappedSilenceOn: false,
      bgAutoPlay: true,
    ));
  }

  /// Host clears the abort latch once the foreground leaves the aborted
  /// segment (re-entry becomes legal again).
  Future<void> clearMappedExitLatch() async {
    if (!state.enabled) return;
    set(state.copyWith(mappedExitAdvanced: false));
  }

  // ── Candidate source rules moved to the `bg_source_rules` Drift table ──
  // (see BgSourceRuleRepository / BgSourceBootstrap); the store no longer
  // holds them.

  Future<void> setRate(double value) async {
    if (value <= 0) return;
    set(state.copyWith(rate: value));
    await save(state);
  }

  /// Independent mute for the foreground volume track. Never affects 副音.
  Future<void> toggleFgMute() async {
    set(state.copyWith(fgMuted: !state.fgMuted));
    await save(state);
  }

  /// Independent mute for the 副音 volume track. Never affects the foreground.
  Future<void> toggleBgMute() async {
    set(state.copyWith(bgMuted: !state.bgMuted));
    await save(state);
  }

  /// User taps a queue row in the 副音 queue panel: start from [index] and
  /// autoplay. Only touches the background runtime; the foreground is never
  /// affected. [userInitiated] marks a MANUAL switch (see [step]).
  ///
  /// A row holding the foreground's own file is REFUSED ([BgJumpOutcome
  /// .refusedForegroundFile]) rather than opened on a second engine. It is
  /// still listed — it is the 音库 source for the next foreground — it simply
  /// cannot play at the same time as the video it came from. Lifting the guard
  /// is the user's call (`allowSameFgBgFile`).
  Future<BgJumpOutcome> jumpTo(int index, {bool userInitiated = false}) async {
    if (!state.enabled) return BgJumpOutcome.ignored;
    if (index < 0 || index >= state.queue.length) {
      return BgJumpOutcome.ignored;
    }
    final excluded = excludedForegroundKey();
    if (excluded != null && backgroundMediaKey(state.queue[index]) == excluded) {
      _log.i('jumpTo: refused — that file is the foreground right now');
      return BgJumpOutcome.refusedForegroundFile;
    }
    // Same abandon-latch as [step]: a jump during a mapped segment swaps the
    // 副音 track without a second advance on segment exit.
    if (state.mappedFile != null) _abandonMappedForUserStep();
    // Session-only fields — nothing persistent changed, so skip the write.
    set(state.copyWith(
      currentIndex: index,
      bgAutoPlay: true,
      bgStepSeq: state.bgStepSeq + 1,
      bgUserAlignSeq:
          userInitiated ? state.bgUserAlignSeq + 1 : state.bgUserAlignSeq,
      userBgSwitchSeq:
          userInitiated ? state.userBgSwitchSeq + 1 : state.userBgSwitchSeq,
      userBgSwitchIndex: userInitiated ? index : state.userBgSwitchIndex,
    ));
    return BgJumpOutcome.jumped;
  }

  /// Tiled entrance: selects the queue entry for a VM segment and queues a
  /// one-shot offset seek the scope lands once that file has opened (same
  /// shape as [requestLockTarget], but owned by the wholeVirtual tiled plan
  /// so the two never share a sequence). System-only: never raises the
  /// manual-switch signal.
  Future<void> requestTiledTarget({
    required int index,
    required int targetMs,
  }) async {
    if (!state.enabled) return;
    if (index < 0 || index >= state.queue.length) return;
    // Session-only fields — nothing persistent changed, so skip the write.
    // A tiled entrance is a SYSTEM seek: raise the system-seek seq so the
    // runtime observer re-anchors instead of mirroring it back onto the
    // foreground (which would move the video — the skip-episode report).
    set(state.copyWith(
      currentIndex: index,
      tiledTargetIndex: index,
      tiledSeekTargetMs: targetMs < 0 ? 0 : targetMs,
      tiledSeekSeq: state.tiledSeekSeq + 1,
      bgSystemSeekSeq: state.bgSystemSeekSeq + 1,
    ));
  }

  /// Notes a SYSTEM bg seek (alignment landing, replay) that the position
  /// mirror must swallow: the runtime observer re-anchors its offset on the
  /// next sample instead of driving the foreground. Session-only, no write.
  void noteSystemSeek() {
    if (!state.enabled) return;
    set(state.copyWith(bgSystemSeekSeq: state.bgSystemSeekSeq + 1));
  }

  /// Notes a SYSTEM foreground seek the bg-master mirror issues itself (the
  /// seek/roll that maps the 副音 timeline onto the video). The position mirror
  /// must swallow its landing instead of reading it as a user fg seek and
  /// rolling the bg queue back — the fg↔bg ping-pong. Symmetric to
  /// [noteSystemSeek]; session-only, no write.
  void noteFgSystemSeek() {
    if (!state.enabled) return;
    set(state.copyWith(fgSystemSeekSeq: state.fgSystemSeekSeq + 1));
  }

  /// Explicit "use bg for the current foreground": clears the old queue
  /// progress (back to the head), drops mapping leftovers and bumps [bgRunSeq]
  /// so the runtime observer restarts its per-run alignment chain (re-align).
  /// Session-only queue fields — the persisted prefs are untouched, so skip
  /// the write (same rule as [step]).
  void restartForCurrent() {
    if (!state.enabled) return;
    set(state.copyWith(
      currentIndex: state.queue.isEmpty ? -1 : 0,
      bgRunSeq: state.bgRunSeq + 1,
      bgExhausted: false,
      alignOffsetMs: null,
      mappedFile: null,
      mappedRate: null,
      mappedFgPercent: null,
      mappedBgPercent: null,
      mappedSilenceOn: false,
      mappedExitAdvanced: false,
    ));
  }

  /// Publishes the file-local bg seek WINDOW (仅当前 + 高同步 only; null =
  /// free). Written by the runtime observer every sample — session-only, no
  /// write; the shared-controls adapter clamps to it. The floor is the bg
  /// position mapped to fg 00:00; the ceiling the one mapped to fg 100%.
  void publishSeekWindow({int? floorLocalMs, int? ceilingLocalMs}) {
    if (state.bgSeekFloorLocalMs == floorLocalMs &&
        state.bgSeekCeilingLocalMs == ceilingLocalMs) {
      return;
    }
    set(state.copyWith(
      bgSeekFloorLocalMs: floorLocalMs,
      bgSeekCeilingLocalMs: ceilingLocalMs,
    ));
  }

  /// Sets the session alignment mode (see [BgAlignMode]). With [rerun] the
  /// per-run alignment chain restarts via [bgRunSeq], so the runtime observer
  /// re-applies the mapping immediately; pass false when the caller already
  /// applied the seek itself. Session-only: no persistence write (the
  /// "remember" preference is [alignDefault]/[alignPercent], set by the
  /// dialog's own toggle).
  void setAlignMode({
    required BgAlignMode mode,
    int? percent,
    bool rerun = true,
  }) {
    if (!state.enabled) return;
    set(state.copyWith(
      alignMode: mode,
      alignPercent: (percent ?? state.alignPercent).clamp(0, 100),
      bgRunSeq: rerun ? state.bgRunSeq + 1 : state.bgRunSeq,
    ));
  }

  /// Records the AUTHORITATIVE lock offset (`fgAnchor - bgAnchor`, ms) of a user
  /// alignment. The runtime observer then treats it as the pair's fixed offset
  /// and stops re-deriving one from position samples, so the user's alignment
  /// outranks the linkage level (see [BackgroundPlaybackState.alignOffsetMs]).
  /// Session-only, no write.
  void setAlignOffset(int? offsetMs) {
    if (!state.enabled) return;
    if (state.alignOffsetMs == offsetMs) return;
    set(state.copyWith(alignOffsetMs: offsetMs));
  }

  /// Requests a cross-file CONTINUATION under [BgExhaustedAction.nextBg]: the
  /// runtime observer locates the LOOPING 副音 timeline at the current
  /// foreground position and continues there, preserving [alignOffsetMs]. Set
  /// [fromAlign] when the request came from an alignment whose mapped position
  /// fell outside the current file (the「对齐后当前 fg 位置没有 bg」case), which
  /// makes the explanation dialog add its「if it had played naturally…」frame.
  /// Session-only, no write.
  void requestBgContinuation({required bool fromAlign}) {
    if (!state.enabled) return;
    set(state.copyWith(
      bgContinuationSeq: state.bgContinuationSeq + 1,
      bgContinuationFromAlign: fromAlign,
    ));
  }

  /// The scope landed the tiled offset seek: clear the one-shot without
  /// touching the queue position.
  void consumeTiledSeek() {
    if (state.tiledSeekSeq <= 0) return;
    set(state.copyWith(tiledSeekSeq: 0, tiledTargetIndex: -1));
  }

  /// The VM link consumed the manual-switch signal (asked or deliberately
  /// skipped): clear it without touching the queue position.
  void consumeUserBgSwitch() {
    if (state.userBgSwitchSeq <= 0) return;
    set(state.copyWith(userBgSwitchSeq: 0, userBgSwitchIndex: -1));
  }

  Future<void> cycleBgRepeat() async {
    final next = switch (state.bgRepeat) {
      Repeat.none => Repeat.all,
      Repeat.all => Repeat.one,
      Repeat.one => Repeat.none,
    };
    set(state.copyWith(bgRepeat: next));
    await save(state);
  }

  /// Toggles in-list shuffle, anchoring the current file at the head when
  /// turning shuffle ON so the jump never surprises the user.
  Future<void> toggleShuffle() async {
    final on = !state.shuffle;
    var queue = state.queue;
    var index = state.currentIndex;
    if (on) {
      final cur = currentFile;
      queue = BackgroundQueueLogic.reshuffleKeepingCurrent(
        state.queue,
        cur == null ? null : backgroundMediaKey(cur),
      );
      // The head moved under the cursor: follow it, otherwise the stale index
      // points at whatever song landed on the old slot (an instant skip).
      index = queue.isEmpty ? -1 : 0;
    }
    set(state.copyWith(shuffle: on, queue: queue, currentIndex: index));
    await save(state);
  }

  // ── Queue refresh (candidate sources may change while playing) ──

  /// Replaces the queue from a fresh candidate resolve. When the current file
  /// still exists (by media key) it stays current and keeps playing;
  /// otherwise playback restarts at the head of the new list.
  Future<void> replaceQueue(List<FileItem> candidates) async {
    if (!state.enabled) {
      _log.w('replaceQueue: not enabled — ignored');
      return;
    }
    if (candidates.isEmpty) {
      // A source refresh that finds nothing must not silently kill the whole
      // subsystem (and its queue); keep what is playing and let the caller
      // report "no candidates".
      _log.w('replaceQueue: empty candidate list — keeping the current queue');
      return;
    }
    final ordered = state.shuffle
        ? BackgroundQueueLogic.shuffled(candidates)
        : List<FileItem>.of(candidates);
    final cur = currentFile;
    // Keep playing what was playing; otherwise open something that is not the
    // foreground's own file (the pool legitimately contains it).
    final index = BackgroundQueueLogic.pickStartIndex(
      queue: ordered,
      preferredKey: cur == null ? null : backgroundMediaKey(cur),
      excludedKey: excludedForegroundKey(),
    );
    set(state.copyWith(queue: ordered, currentIndex: index));
    await save(state);
  }

  /// Appends the candidates a live run is missing, keeping everything already
  /// queued in place (see [BgQueueSyncMode.append]).
  ///
  /// The [BgQueueSyncMode.append] counterpart of [replaceQueue]: no reorder, no
  /// re-shuffle, and therefore no risk of moving the file that is playing. A
  /// resolve that adds nothing returns without touching the store, so an
  /// unrelated tag write costs no `set` and no persist.
  Future<void> appendCandidates(List<FileItem> candidates) async {
    if (!state.enabled) return;
    if (candidates.isEmpty) return;
    final next = appendedBgQueue(queue: state.queue, candidates: candidates);
    if (next.length == state.queue.length) return;
    set(state.copyWith(queue: next));
    await save(state);
  }

  /// How a live run folds a tag-membership change into its queue
  /// (`bg.queueSyncMode`).
  Future<void> setQueueSyncMode(BgQueueSyncMode value) async {
    if (state.queueSyncMode == value) return;
    set(state.copyWith(queueSyncMode: value));
    await _writeAux(_kAuxQueueSyncMode, value.name);
  }

  FileItem? get currentFile {
    final s = state;
    if (!s.enabled) return null;
    if (s.currentIndex < 0 || s.currentIndex >= s.queue.length) return null;
    return s.queue[s.currentIndex];
  }

  // ── Persistence ──

  /// AUX-row field names of the `bg.` domain (see [MetaSettingsModule.kBgRowPrefix]).
  static const String _kAuxKeepWarm = 'keepWarm';
  static const String _kAuxStartArmed = 'startArmed';
  static const String _kAuxGateStopBehavior = 'gateStopBehavior';
  static const String _kAuxReactivateMode = 'reactivateMode';
  static const String _kAuxAlignDefault = 'alignDefault';
  static const String _kAuxAlignPercent = 'alignPercent';
  static const String _kAuxApplyScope = 'applyScope';
  static const String _kAuxScopePersist = 'scopePersist';
  static const String _kAuxRatioEnabled = 'ratioEnabled';
  static const String _kAuxRatioExplicit = 'ratioExplicitSave';
  static const String _kAuxRatioScope = 'ratioScope';
  static const String _kAuxAutoFocus = 'autoFocusControl';
  static const String _kAuxSeekLink = 'seekLink';
  static const String _kAuxLockLevel = 'lockLevel';
  static const String _kAuxStepMode = 'stepMode';
  static const String _kAuxAlignAutoPauseSec = 'alignAutoPauseRemainSec';
  static const String _kAuxExhaustedAction = 'exhaustedAction';

  /// How a live run folds a tag-membership change into its running queue.
  static const String _kAuxQueueSyncMode = 'queueSyncMode';
  static const String _kAuxMinSegmentSpanMs = 'minSegmentSpanMs';
  static const String _kAuxPAlignKeepMaxLength = 'pAlignKeepMaxLength';
  static const String _kAuxStickyConsume = 'stickyConsume';
  static const String _kAuxFgWindowZoom = 'fgWindowZoom';
  static const String _kAuxFgWindowPushBg = 'fgWindowPushBg';
  static const String _kAuxSnapEnabled = 'snapEnabled';
  static const String _kAuxSnapReleaseLimit = 'snapReleaseLimit';

  /// 自动使用已保存的映射 (E 节 playback switch).
  static const String _kAuxUseSavedMapping = 'useSavedMapping';

  /// Old single-value 进度锁定 row, read once for migration then ignored.
  static const String _kAuxProgressLockLegacy = 'progressLock';
  static const String _kAuxItemSwitch = 'itemSwitch';
  static const String _kAuxSegmentSwitch = 'segmentSwitch';

  /// Old single-value 跨视频 rule, read once for migration then ignored.
  static const String _kAuxVmAlignRuleLegacy = 'vmAlignRule';
  static const String _kAuxVmScopeMode = 'vmScopeMode';
  static const String _kAuxQuickBar = 'quickBar';
  static const String _kAuxQuickBarAlign = 'quickBarAlign';
  static const String _kAuxRatioItemPrefix = 'ratioItem.';

  /// `dialring.` row holding the side-type align dial ring assignment.
  static const String _kAuxAlignRing = 'alignRingAssignment';

  @override
  Future<BackgroundPlaybackState?> load() async {
    try {
      final raw = await getKvStore().read(key: _key);
      final decoded = raw == null
          ? const BackgroundPlaybackState()
          : BackgroundPlaybackState.fromJson(json.decode(raw));
      final merged = await _mergeAuxRows(decoded);
      return normalizeLoaded(merged);
    } catch (e) {
      _log.e('Error loading BackgroundPlaybackState: $e');
      return null;
    }
  }

  /// Merges the `bg.*` AUX rows over the KV snapshot.
  ///
  /// The rows are the only persistence route for the fields they back (they
  /// are JsonKey-excluded from the KV JSON), so an absent row simply keeps the
  /// code default — never an error.
  static Future<BackgroundPlaybackState> _mergeAuxRows(
    BackgroundPlaybackState base,
  ) async {
    if (!MetaSettingsModule.ready) return base;
    final rows = await MetaSettingsModule.loadBgRows();
    final dialRows = await MetaSettingsModule.loadDialRingRows();
    if (rows.isEmpty && dialRows.isEmpty) return base;

    final perMedia = <String, MediaRatio>{};
    for (final e in rows.entries) {
      final key = e.key;
      if (key.startsWith(_kAuxRatioItemPrefix)) {
        final mediaKey = key.substring(_kAuxRatioItemPrefix.length);
        final json = ValueCodec.decodeJson(e.value);
        if (mediaKey.isEmpty || json is! Map) continue;
        try {
          perMedia[mediaKey] = MediaRatio.fromJson(
            {for (final k in json.keys) '$k': json[k]},
          );
        } catch (err) {
          _log.w('bg.ratioItem<$mediaKey> malformed: $err');
        }
      }
    }

    // 进度锁定 split: prefer the new two-axis rows; otherwise map the legacy
    // single value once (full → linked+high, playPauseOnly → linked+low,
    // independent → independent with the level default kept).
    var seekLink = BgSeekLink.values.asNameMap()[rows[_kAuxSeekLink]];
    var lockLevel = BgLockLevel.values.asNameMap()[rows[_kAuxLockLevel]];
    if (seekLink == null && lockLevel == null) {
      final migrated = migrateLegacyProgressLock(rows[_kAuxProgressLockLegacy]);
      if (migrated != null) {
        seekLink = migrated.link;
        lockLevel = migrated.level;
      }
    }

    // 跨视频 split: the legacy single value mapped both transitions at once, so
    // an explicit legacy row is expanded into the two switches.
    var itemSwitch = BgCrossAction.values.asNameMap()[rows[_kAuxItemSwitch]];
    var segmentSwitch =
        BgCrossAction.values.asNameMap()[rows[_kAuxSegmentSwitch]];
    if (itemSwitch == null && segmentSwitch == null) {
      switch (rows[_kAuxVmAlignRuleLegacy]) {
        case 'perSegment':
          itemSwitch = BgCrossAction.newBg;
          segmentSwitch = BgCrossAction.newBg;
        case 'tiled':
          itemSwitch = BgCrossAction.newBg;
          segmentSwitch = BgCrossAction.keepPlaying;
      }
    }

    return base.copyWith(
      seekLink: seekLink ?? base.seekLink,
      lockLevel: lockLevel ?? base.lockLevel,
      stepMode:
          BgStepMode.values.asNameMap()[rows[_kAuxStepMode]] ?? base.stepMode,
      alignAutoPauseRemainSec: clampAlignWarnRemainSec(
        ValueCodec.decodeInt(
          rows[_kAuxAlignAutoPauseSec],
          fallback: base.alignAutoPauseRemainSec,
        ),
      ),
      bgExhaustedAction:
          BgExhaustedAction.values.asNameMap()[rows[_kAuxExhaustedAction]] ??
              base.bgExhaustedAction,
      queueSyncMode:
          BgQueueSyncMode.values.asNameMap()[rows[_kAuxQueueSyncMode]] ??
              base.queueSyncMode,
      minSegmentSpanMs: ValueCodec.decodeInt(
        rows[_kAuxMinSegmentSpanMs],
        fallback: base.minSegmentSpanMs,
      ).clamp(kMinMinSegmentSpanMs, kMaxMinSegmentSpanMs),
      pAlignKeepMaxLength: ValueCodec.decodeBool(
        rows[_kAuxPAlignKeepMaxLength],
        fallback: base.pAlignKeepMaxLength,
      ),
      stickyConsume:
          BgStickyConsume.values.asNameMap()[rows[_kAuxStickyConsume]] ??
              base.stickyConsume,
      fgWindowZoom: ValueCodec.decodeDouble(
        rows[_kAuxFgWindowZoom],
        fallback: base.fgWindowZoom,
      ).clamp(FgDisplayWindowMath.kMinZoom, FgDisplayWindowMath.kMaxZoom),
      fgWindowPushBg: ValueCodec.decodeBool(
        rows[_kAuxFgWindowPushBg],
        fallback: base.fgWindowPushBg,
      ),
      snapEnabled: ValueCodec.decodeBool(
        rows[_kAuxSnapEnabled],
        fallback: base.snapEnabled,
      ),
      snapReleaseLimit: ValueCodec.decodeInt(
        rows[_kAuxSnapReleaseLimit],
        fallback: base.snapReleaseLimit,
      ).clamp(SegmentSnap.kMinReleaseLimit, SegmentSnap.kMaxReleaseLimit),
      alignRingAssignment:
          AlignRingAssignment.values.asNameMap()[dialRows[_kAuxAlignRing]] ??
              base.alignRingAssignment,
      keepWarmPlayer: ValueCodec.decodeBool(
        rows[_kAuxKeepWarm],
        fallback: base.keepWarmPlayer,
      ),
      startArmed: ValueCodec.decodeBool(
        rows[_kAuxStartArmed],
        fallback: base.startArmed,
      ),
      gateStopBehavior:
          BgGateStopBehavior.values.asNameMap()[rows[_kAuxGateStopBehavior]] ??
              base.gateStopBehavior,
      bgReactivateMode:
          BgReactivateMode.values.asNameMap()[rows[_kAuxReactivateMode]] ??
              base.bgReactivateMode,
      mappingEnabled: ValueCodec.decodeBool(
        rows[_kAuxUseSavedMapping],
        fallback: base.mappingEnabled,
      ),
      alignDefault:
          bgAlignDefaultFromName(rows[_kAuxAlignDefault]) ?? base.alignDefault,
      alignPercent: ValueCodec.decodeInt(
        rows[_kAuxAlignPercent],
        fallback: base.alignPercent,
      ).clamp(0, 100),
      applyScope: BgApplyScope.values.asNameMap()[rows[_kAuxApplyScope]] ??
          base.applyScope,
      scopePersist: ValueCodec.decodeBool(
        rows[_kAuxScopePersist],
        fallback: base.scopePersist,
      ),
      volumeRatioEnabled: ValueCodec.decodeBool(
        rows[_kAuxRatioEnabled],
        fallback: base.volumeRatioEnabled,
      ),
      ratioExplicitSave: ValueCodec.decodeBool(
        rows[_kAuxRatioExplicit],
        fallback: base.ratioExplicitSave,
      ),
      ratioScope: RatioScope.values.asNameMap()[rows[_kAuxRatioScope]] ??
          base.ratioScope,
      autoFocusControl: ValueCodec.decodeBool(
        rows[_kAuxAutoFocus],
        fallback: base.autoFocusControl,
      ),
      // 跨视频拆分成两个独立开关: prefer the new rows; otherwise map the legacy
      // single value once (perSegment → both newBg; tiled → item newBg +
      // segment keepPlaying). An absent legacy row keeps the code defaults.
      bgItemSwitch: itemSwitch ?? base.bgItemSwitch,
      bgSegmentSwitch: segmentSwitch ?? base.bgSegmentSwitch,
      bgVmScopeMode: BgVmScopeMode.values.asNameMap()[rows[_kAuxVmScopeMode]] ??
          base.bgVmScopeMode,
      quickBarEnabled: ValueCodec.decodeBool(
        rows[_kAuxQuickBar],
        fallback: base.quickBarEnabled,
      ),
      quickBarAlign:
          BgQuickBarAlign.values.asNameMap()[rows[_kAuxQuickBarAlign]] ??
              base.quickBarAlign,
      perMediaRatio: perMedia.isEmpty ? base.perMediaRatio : perMedia,
    );
  }

  static Future<void> _writeAux(String field, String? encoded) async {
    if (encoded == null) return;
    await MetaSettingsModule.saveBgRow(field, encoded);
  }

  @override
  Future<void> save(BackgroundPlaybackState s) async {
    try {
      await getKvStore().write(key: _key, value: json.encode(s.toJson()));
    } catch (e) {
      _log.e('Error saving BackgroundPlaybackState: $e');
    }
  }

  /// Removes an AUX row (empty-value tombstone). Used when a per-media ratio
  /// override is cleared so the media falls back to the global pair.
  static Future<void> _deleteAux(String field) =>
      MetaSettingsModule.saveBgRow(field, '');

  static BackgroundPlaybackState normalizeLoaded(BackgroundPlaybackState s) {
    // Loaded JSON never carries session fields; make that explicit and clamp
    // persisted prefs into sane ranges.
    final fg = s.fgVolumePercent.clamp(0, 100);
    final bg = s.bgVolumePercent.clamp(0, 100);
    final rate = s.rate <= 0 ? 1.0 : s.rate;
    return s.copyWith(
      // 开机状态: a cold launch arms the run (engine built) but never plays —
      // the gate stays CLOSED, so no scope/映射 auto-start may fire until the
      // user opens it from the quick bar. With startArmed off the subsystem
      // stays fully off.
      enabled: s.startArmed,
      gateOpen: false,
      controlTarget: ControlTarget.foreground,
      currentIndex: -1,
      bgAutoPlay: false,
      fgVolumePercent: fg,
      bgVolumePercent: bg,
      rate: rate,
      // Session-only state always starts clean.
      displayTarget: ControlTarget.foreground,
      openQuickPanel: BgQuickPanel.none,
      bgExhausted: false,
      vmScopeKeyOverride: null,
      vmSessionActive: false,
      vmAlignResetSeq: 0,
      vmTiledOverrides: const <String, VmTiledSlot>{},
      vmTiledSeq: 0,
      tiledSeekSeq: 0,
      tiledSeekTargetMs: -1,
      tiledTargetIndex: -1,
      userBgSwitchSeq: 0,
      userBgSwitchIndex: -1,
      bgUserAlignSeq: 0,
      // The 作用范围 preference survives only when the user asked it to.
      applyScope: s.scopePersist ? s.applyScope : BgApplyScope.currentOnly,
      scopeAnchorKey: null,
      bgOffMediaKeys: const <String>{},
      segmentEditMode: false,
      segmentEditDraft: null,
      segmentEditStageOnly: false,
    );
  }
}

BackgroundPlaybackStore useBackgroundPlaybackStore() =>
    create(() => BackgroundPlaybackStore());
