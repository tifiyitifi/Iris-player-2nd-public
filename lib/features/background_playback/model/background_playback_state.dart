import 'package:freezed_annotation/freezed_annotation.dart';
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
import 'package:iris/features/background_playback/resolver/vm_tiled_plan.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;

part 'background_playback_state.freezed.dart';
part 'background_playback_state.g.dart';

/// Persistent state of the 副音播放 (background playback) subsystem.
///
/// Split persistence:
/// - Session-only (excluded from JSON): [enabled], [controlTarget],
///   [currentIndex], [bgAutoPlay], [bgPanelVisible] — the subsystem never
///   auto-starts on a cold launch; the user starts it from the More menu, and
///   its queue/preferences survive for the next session.
/// - Persisted: queue + two volume-ratio tracks (fg/bg percent, each with an
///   independent mute) + rate/shuffle/repeat + show-video + video layout.
@freezed
abstract class BackgroundPlaybackState with _$BackgroundPlaybackState {
  const BackgroundPlaybackState._();

  /// The global fg/bg ratio pair — the fallback every media without its own
  /// `bg.ratioItem.*` override resolves to (sub_media §5.5).
  MediaRatio get globalRatio =>
      MediaRatio(fgPercent: fgVolumePercent, bgPercent: bgVolumePercent);

  /// Whether the shared controls may address the 副音 runtime right now: the
  /// subsystem is on AND the user gate is open AND the target is bg. A closed
  /// gate always reads as foreground — even against a stale target flag — so a
  /// deactivation can never leave transport driving a dead bg.
  bool get bgOwnsControls =>
      enabled && gateOpen && controlTarget == ControlTarget.background;

  /// Whether the video surface may show the 副音 picture right now (same rule
  /// as [bgOwnsControls], over the display target).
  bool get bgOwnsDisplay =>
      enabled && gateOpen && displayTarget == ControlTarget.background;

  const factory BackgroundPlaybackState({
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool enabled,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(ControlTarget.foreground)
    ControlTarget controlTarget,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int currentIndex,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool bgAutoPlay,

    /// Whether the user-level gate permits 副音 to play against the current
    /// foreground. Opened by a gate press or a fresh armed launch; closed by an
    /// explicit stop (quick-bar gate OFF / the bg stop button). While closed the
    /// scope observer never auto-resumes or auto-starts 副音 — across every
    /// scope — until the user opens the gate again. Distinct from [bgAutoPlay],
    /// which a scope pause or the play/pause transport may toggle without
    /// touching the user's stop intent. Session-only.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool gateOpen,

    /// Float-panel collapse state (pill). Session-only: hidden ≠ closed —
    /// the subsystem keeps playing; the pill / panel is restored via the More
    /// menu or a control-bar show.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool bgPanelVisible,

    /// Layout of the 副音 video surface (fullscreen implemented; pip/split
    /// are persisted placeholders with no behavior yet).
    @Default(BgVideoLayout.fullscreen) BgVideoLayout bgVideoLayout,

    /// Foreground ↔ 副音 linkage (D 节): when the foreground switches media,
    /// re-resolve the mapping of the NEW foreground file at its current
    /// position (default OFF — 副音 plays on untouched; it never stops or
    /// restarts because of a foreground change).
    @Default(false) bool bgFollowsFgSwitch,

    /// Locks the natural-playback rate of 副音 to the foreground app rate
    /// (default ON). Mapped segments override the rate with their own
    /// alignment math regardless of this flag.
    @Default(true) bool bgRateLock,

    /// Allows the same physical file to play in both runtimes at once
    /// (default OFF = double-play guard ON). Code-level skip in launch/step;
    /// exposed as a meta row only.
    @Default(false) bool allowSameFgBgFile,

    /// Ordered, toggleable candidate-source rules live in the
    /// `bg_source_rules` Drift table (see `BgSourceRuleRepository`), NOT here.

    /// Mapping timeline switches (E 节).
    ///
    /// [mappingEnabled]: use the current foreground file's saved timeline
    /// ("自动使用已保存的映射"). Defaults ON: a media with a saved timeline
    /// auto-applies it. Turning it off makes 副音 ignore every saved timeline
    /// and play naturally. Persisted as the `bg.useSavedMapping` AUX row.
    /// [ignoreNoBg]: treat `silence` segments as gaps (natural 副音) instead.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool mappingEnabled,
    @Default(false) bool ignoreNoBg,

    /// ── A-中心-B 段编辑器 (session-only) ──
    ///
    /// While [segmentEditMode] is on, the A-B editor owns the current fg/bg
    /// pair: transport is frozen (prev/next blocked, end-of-media pauses
    /// instead of advancing) and [segmentEditDraft] carries the span being
    /// adjusted. Neither field is persisted — the editor is a live session.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool segmentEditMode,
    @JsonKey(includeToJson: false, includeFromJson: false)
    SegmentEditDraft? segmentEditDraft,

    /// Session: the A-B editor was opened from the mapping manager, so its
    /// Save writes into the session staging draft instead of the database
    /// (the manager's explicit Apply commits it later). Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool segmentEditStageOnly,

    /// Session: active mapped-file override (non-null while a playMedia
    /// segment is driving 副音 instead of the natural queue).
    @JsonKey(includeToJson: false, includeFromJson: false) FileItem? mappedFile,

    /// Session: natural-next advance latch (see [mappedExitAdvanced]).
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool mappedExitAdvanced,

    /// Session: a `silence` mapping segment is holding 副音 paused (distinct
    /// from the user pausing the engine manually).
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool mappedSilenceOn,

    /// Session: one-shot engine seek request while a mapped segment is
    /// active (proportional reposition). [mappedSeekTargetMs] carries the
    /// target; bumping [mappedSeekSeq] re-fires the scope effect.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int mappedSeekSeq,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int mappedSeekTargetMs,

    /// Session: rate while a mapped segment is active (overrides lock).
    @JsonKey(includeToJson: false, includeFromJson: false) double? mappedRate,

    /// Session: per-segment volume split of the ACTIVE mapped segment (v27).
    /// Null pair = fall back to the per-media / global ratio.
    @JsonKey(includeToJson: false, includeFromJson: false) int? mappedFgPercent,
    @JsonKey(includeToJson: false, includeFromJson: false) int? mappedBgPercent,

    /// ── 进度锁定 mapping (fg-driven) ──
    ///
    /// One-shot 副音 queue jump requested by the lock mapping when a foreground
    /// seek maps to a DIFFERENT 副音 file. [lockTargetIndex] selects the queue
    /// entry; bumping [lockSeekSeq] re-fires the scope's seek effect, which
    /// lands [lockSeekTargetMs] once that file has opened. Same-file targets
    /// never come through here — the scope seeks the engine directly.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int lockSeekSeq,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int lockSeekTargetMs,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int lockTargetIndex,

    /// ── Startup preload (sub_media §1) ──
    ///
    /// Keeps the secondary engine constructed (no file loaded, stopped) from
    /// launch so enabling 副音 reuses it instead of paying the
    /// Player/VideoController construction — that construction is what paints
    /// the black flash. Persisted via the `bg.` AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool keepWarmPlayer,

    /// Whether the 副音 feature is armed (enabled, stopped) when the app
    /// launches. Independent of [keepWarmPlayer]: arming builds the run and
    /// leaves it stopped (no file, [gateOpen] on), while keepWarmPlayer only
    /// holds an idle engine while the run is OFF. Persisted as the
    /// `bg.startArmed` AUX row; a runtime change takes effect on the NEXT
    /// launch (never mid-session).
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool startArmed,

    /// What the quick-bar gate / bg stop button does when it closes the gate:
    /// keep the media loaded paused ([BgGateStopBehavior.pause]) or unload the
    /// decoder/file handle ([BgGateStopBehavior.unload]). The run and the warm
    /// native instance always survive either way. Persisted as the
    /// `bg.gateStopBehavior` AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgGateStopBehavior.pause)
    BgGateStopBehavior gateStopBehavior,

    /// ── 作用范围 (activation scope) ──
    ///
    /// Which foreground media a 副音 run applies to: only the current one, the
    /// "smart" saved-pairing rule ("已保存副音 fg 自动播放"), or every media.
    /// Persisted as the `bg.applyScope` AUX row; it survives a restart only
    /// while [scopePersist] is on.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgApplyScope.currentOnly)
    BgApplyScope applyScope,

    /// Whether [applyScope] survives a restart ("跨重启保存"). When false the
    /// cold load resets the scope to [BgApplyScope.currentOnly].
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool scopePersist,

    /// What a「仅当前」re-activation lands on when the gate reopens (same bg /
    /// next bg). Persisted as the `bg.reactivateMode` AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgReactivateMode.nextBg)
    BgReactivateMode bgReactivateMode,

    /// The media the current 副音 run is anchored to
    /// ([BgApplyScope.currentOnly]): leaving it pauses 副音, returning resumes.
    @JsonKey(includeToJson: false, includeFromJson: false)
    String? scopeAnchorKey,

    /// ── 对齐默认方案 ──
    ///
    /// The persisted default alignment applied whenever a 副音 file is
    /// (re)aligned; mirrors [BgAlignMode]. Persisted as the `bg.alignDefault`
    /// AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgAlignDefault.fgHead)
    BgAlignDefault alignDefault,

    /// Media the user explicitly closed 副音 for, keyed by media key.
    ///
    /// Independent of [applyScope]: closing "对当前" silences THIS media only
    /// and leaves every other media untouched. Session state — it never
    /// survives a restart.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(<String>{})
    Set<String> bgOffMediaKeys,

    /// Whether starting 副音 hands the shared controls to it (第 3 轮追加需求).
    /// Turning this off leaves the controls on the foreground when 副音 starts.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool autoFocusControl,

    /// ── 进度联动 (第 3 轮问题 3，拆成两轴) ──
    ///
    /// [seekLink] decides whether a foreground seek moves 副音 with it;
    /// [lockLevel] how much of the shared transport mirrors (high = seek
    /// forward/back step + play/pause, low = play/pause only). Fully
    /// independent overrides the level. Both persisted as `bg.*` AUX rows.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgSeekLink.linked)
    BgSeekLink seekLink,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgLockLevel.high)
    BgLockLevel lockLevel,

    /// ── 换集行为 (bg 上下集) ──
    ///
    /// Whether a user step on 副音 also moves the foreground (see
    /// [BgStepMode]). Persisted as the `bg.stepMode` AUX row; defaults to
    /// [BgStepMode.swapOnly] — most of the time the user only wants to swap the
    /// 副音 track and keep the video where it is.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgStepMode.swapOnly)
    BgStepMode stepMode,

    /// Session: bumped by every discrete 副音 step/jump so the runtime observer
    /// can tell a STEP apart from a slider seek — in [BgStepMode.swapOnly] a
    /// step must never be mirrored onto the foreground.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int bgStepSeq,

    /// Session: bumped ONLY by a USER-initiated switch (`step`/`jumpTo` with
    /// `userInitiated`) — the runtime observer re-applies the alignment mode on
    /// the newly opened file so a manual switch lands where the setting says
    /// (e.g. `fromFgHead` → `bgPos = fgPos`). System moves ([bgStepSeq],
    /// completion chains) never raise it. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int bgUserAlignSeq,

    /// ── 对齐编辑侧环归属 ──
    ///
    /// Which physical ring hosts the FOREGROUND media in the align editor's
    /// dual-ring dial (side type). Persisted as the
    /// `dialring.alignRingAssignment` AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(AlignRingAssignment.fgOuter)
    AlignRingAssignment alignRingAssignment,

    /// ── 跨视频切换 (sub_media §cross-video, two independent switches) ──
    ///
    /// What the 副音 queue does when the FOREGROUND moves to a new LIST ITEM —
    /// a real media file, or a whole virtual-merged item. Default [newBg]:
    /// each new item starts a new 副音 track. Persisted as `bg.itemSwitch`.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgCrossAction.newBg)
    BgCrossAction bgItemSwitch,

    /// What the 副音 queue does when a VIRTUAL video switches to a different
    /// physical SEGMENT (the segment switch really loads another file).
    /// Default [keepPlaying]: 副音 tiles across the virtual file, so different
    /// bg files fill it and the 副音 list keeps looping continuously.
    /// Persisted as `bg.segmentSwitch`.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgCrossAction.keepPlaying)
    BgCrossAction bgSegmentSwitch,

    /// Session: a Virtual Media session is active. Published by the VM link so
    /// the bg side can tell a VM block switch (owned by [bgSegmentSwitch]) from
    /// a real list-item change (owned by [bgItemSwitch]) without importing any
    /// VM type itself.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool vmSessionActive,

    /// How the 作用范围「仅当前」rule reads a Virtual Media foreground (see
    /// [BgVmScopeMode]). Persisted as the `bg.vmScopeMode` AUX row; default is
    /// per-block (independent block matching).
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgVmScopeMode.perBlock)
    BgVmScopeMode bgVmScopeMode,

    /// Session: the 作用范围 identity to use INSTEAD of the physical file key
    /// while a Virtual Media session is active in [BgVmScopeMode.wholeVirtual]
    /// ("将虚拟视频视作完整视频匹配"). Published by the VM-side link
    /// (`VmSubAudioLinkScope`) so the 副音 feature stays VM-agnostic; null =
    /// ordinary physical-file identity (and always null under `perBlock`).
    @JsonKey(includeToJson: false, includeFromJson: false)
    String? vmScopeKeyOverride,

    /// Session: bumped when a Virtual Media block carrying a SAVED mapping is
    /// left. The runtime observer then restarts its per-run alignment chain so
    /// the following blocks re-align from 00:00 ("后续块会重新0000对齐").
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int vmAlignResetSeq,

    /// Session: per-segment overrides of the wholeVirtual tiled plan, keyed
    /// by the physical segment's `mediaKey`. A user adjustment on one inner
    /// segment (align-dialog pick, mapping-editor save, dialog-confirmed
    /// manual bg switch) lands here for THIS app launch only; every other
    /// segment keeps the precomputed tiling. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(<String, VmTiledSlot>{})
    Map<String, VmTiledSlot> vmTiledOverrides,

    /// Session: bumped by every tiled-plan/override change so the VM link
    /// re-resolves the entrance target. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int vmTiledSeq,

    /// Session: one-shot tiled entrance target (wholeVirtual + tiled plan).
    /// Mirrors the lock-mapping rollover shape: [tiledTargetIndex] selects
    /// the queue entry, bumping [tiledSeekSeq] lands [tiledSeekTargetMs]
    /// once that file has opened, then the scope consumes it. Never
    /// persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int tiledSeekSeq,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int tiledSeekTargetMs,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int tiledTargetIndex,

    /// Session: one-shot manual-switch signal. User-initiated queue moves
    /// (`step`/`jumpTo` with `userInitiated`) bump [userBgSwitchSeq] and
    /// record the landed [userBgSwitchIndex]; the VM link consumes it to
    /// ask (dialog) how the current segment should remember this switch
    /// for the rest of the launch. System moves never raise it. Never
    /// persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int userBgSwitchSeq,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(-1)
    int userBgSwitchIndex,

    /// Session: bumped by SYSTEM bg seeks (tiled entrances, alignment landing
    /// seeks, replay) that must never be mirrored back onto the foreground.
    /// The runtime observer consumes it like [bgStepSeq] but unconditionally
    /// re-anchors, independent of stepMode. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int bgSystemSeekSeq,

    /// Session: bumped by SYSTEM foreground seeks (the bg-master mirror's own
    /// seek/roll) that must never be mirrored back onto the 副音 queue.
    /// Symmetric to [bgSystemSeekSeq]: without it the mirror's own fg landing
    /// is read as a user fg seek, rolls the bg queue and ping-pongs the two
    /// timelines. The runtime observer re-anchors on the landing. Never
    /// persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int fgSystemSeekSeq,

    /// Session: bumped by `restartForCurrent` (explicit "use bg for the
    /// current foreground"): the runtime observer restarts its per-run
    /// alignment chain (cleared queue progress, re-align). Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int bgRunSeq,

    /// Session: file-local ms ceiling for bg seeks under 仅当前 + 高同步
    /// (the mapped foreground position must stay within the fg file's
    /// 0–100%), published by the runtime observer; null = free seek. Never
    /// persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    int? bgSeekCeilingLocalMs,

    /// Session: file-local ms floor for bg seeks under 仅当前 + 高同步 (the bg
    /// position mapped to fg 00:00 — before it, 副音 does not exist). Paired
    /// with [bgSeekCeilingLocalMs]; null = free floor. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    int? bgSeekFloorLocalMs,

    /// ── 快速控制栏 (第 3 轮问题 5) ──
    ///
    /// [quickBarEnabled] shows the 副音 quick-control surface (a column beside
    /// the side panel, a row inside the linear bars). [quickBarAlign] is where
    /// that row sits in the linear layouts; the side layout ignores it.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool quickBarEnabled,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgQuickBarAlign.right)
    BgQuickBarAlign quickBarAlign,

    /// ── 快速栏浮窗 (第 4 轮问题 3/4) ──
    ///
    /// Which quick 副音 floating card is open. Session-only — the cards are
    /// non-modal, mounted in the player Stack, draggable and never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgQuickPanel.none)
    BgQuickPanel openQuickPanel,

    /// ── Display target (sub_media §5.3) ──
    ///
    /// Which engine's picture the video surface shows. Deliberately separate
    /// from [controlTarget]: showing 副音's picture does not retarget the
    /// controls, and vice versa.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(ControlTarget.foreground)
    ControlTarget displayTarget,

    /// ── Volume ratio (sub_media §5.5) ──
    ///
    /// [volumeRatioEnabled] false = the saved ratio is ignored and both sides
    /// run at the master volume. [ratioExplicitSave] is the meta switch
    /// (default ON = the dialog commits only on Save; OFF = live drag,
    /// committed on release). The GLOBAL pair stays the KV-backed
    /// [fgVolumePercent]/[bgVolumePercent] below (the float panel's two tracks
    /// edit the same pair); per-media overrides persist via `bg.ratioItem.*`
    /// AUX rows and are empty by default, so a media with no override falls
    /// back to the global pair.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool volumeRatioEnabled,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool ratioExplicitSave,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(RatioScope.global)
    RatioScope ratioScope,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(<String, MediaRatio>{})
    Map<String, MediaRatio> perMediaRatio,

    /// Remembered "start at this share" for the alignment popup, in percent of
    /// the 副音 file (default 30). Persisted as the `bg.alignPercent` AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(30)
    int alignPercent,

    /// Session: the running pair's alignment anchor mode (see [BgAlignMode]).
    /// Never persisted — the default lives in [alignDefault] and [alignPercent].
    /// Every (re-)alignment derives its anchor from the live foreground moment;
    /// there is no stored anchor.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgAlignMode.fromFgHead)
    BgAlignMode alignMode,

    /// Session: the AUTHORITATIVE lock offset (`fgAnchor - bgAnchor`, ms) set by
    /// a user alignment — the alignment dialog's mode tap (「更新到当前」/
    /// 「00:00↔00:00」/ percent) and the runtime's first-open / user-switch
    /// alignment. While non-null the runtime observer uses it as the lock offset
    /// instead of re-deriving one from position samples, so a user alignment
    /// outranks the linkage level and is never silently overwritten by the sync
    /// mirror. Cleared on a run restart / gate close. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    int? alignOffsetMs,

    /// Session: one-shot cross-file CONTINUATION request under
    /// [BgExhaustedAction.nextBg]. Bumped by a natural 副音 completion
    /// (`bgContinuationFromAlign` false) or by an alignment whose mapped bg
    /// position falls outside the CURRENT file (`true` — the「对齐后当前 fg 位置
    /// 没有 bg」case). The runtime observer locates the LOOPING 副音 timeline at
    /// the current foreground position and continues there, preserving
    /// [alignOffsetMs]; while its explanation dialog is up both runtimes stay
    /// paused. Never persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(0)
    int bgContinuationSeq,
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool bgContinuationFromAlign,

    /// MANDATORY remaining-副音 threshold, in seconds (default 5; clamped to
    /// 1..120 — it can never be disabled). When the aligned 副音 has less than
    /// this much left (`bgDur - bgPos`), the alignment popup is raised. Persisted
    /// as the `bg.alignAutoPauseRemainSec` AUX row.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(kDefaultAlignWarnRemainSec)
    int alignAutoPauseRemainSec,

    /// What happens when the current 副音 file finishes while the video keeps
    /// playing (see [BgExhaustedAction]). Persisted as the `bg.exhaustedAction`
    /// AUX row. Default [BgExhaustedAction.nextBg].
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgExhaustedAction.nextBg)
    BgExhaustedAction bgExhaustedAction,

    /// Session: the run reached its terminal "副音 exhausted" state under
    /// [BgExhaustedAction.stopRestoreFg]. While set, the foreground volume is
    /// no longer ducked (it plays at the master volume again) even though the
    /// subsystem stays [enabled]. Cleared on disable/re-enable/restart. Never
    /// persisted.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool bgExhausted,

    /// Physical minimum length of an A–B mapping segment, in milliseconds
    /// (default 500; clamped to 100..5000). Persisted as the
    /// `bg.minSegmentSpanMs` AUX row. Threaded into every `SegmentSpanMath`
    /// clamp so a handle can never collapse a segment below this.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(500)
    int minSegmentSpanMs,

    /// Whether a P (alignment) pull-away respects the sealed user pile
    /// (`bg.pAlignKeepMaxLength` AUX row). True (default) seals the pile the
    /// user bundled in the air: a pull-away off a boundary spends only the
    /// new pile above the seal, never the seal itself. False treats both
    /// seals as 0, so the pile may be consumed down to nothing.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool pAlignKeepMaxLength,

    /// Which handles spend a bundled pile before translating
    /// (`bg.stickyConsume` AUX row). Orthogonal to [pAlignKeepMaxLength]: this
    /// axis decides WHETHER a drag spends a pile at all, that one decides HOW
    /// FAR it may spend (down to the sealed pile, or all the way to zero).
    /// Default [BgStickyConsume.all] = both P and A/B spend piles.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgStickyConsume.all)
    BgStickyConsume stickyConsume,

    /// APB foreground zoom window multiplier (`bg.fgWindowZoom` AUX row):
    /// when `fgDur > zoom × bgDur`, the align editor shows only that much
    /// foreground time so the A–B mapping does not collapse to a near-point.
    /// Clamped to 1.0..10.0; 1.0 disables the zoom.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(2.0)
    double fgWindowZoom,

    /// Whether the q handle's pan PUSHES the mapping once A/B reach 12/11
    /// o'clock (`bg.fgWindowPushBg` AUX row). False (default) clamps the pan at
    /// the boundary; true slides the alignment over the fixed bg window so the
    /// pan may continue.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool fgWindowPushBg,

    /// Snap-to-saved-boundary (卡值） mode (`bg.snapEnabled` AUX row): A / P / B
    /// stop exactly at saved segment boundaries like at the 0% / 100% ends.
    /// False (default) keeps the handles free.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(false)
    bool snapEnabled,

    /// How many recently released snap walls stay passable
    /// (`bg.snapReleaseLimit` AUX row). Clamped to 1..10000; default 1 = only
    /// the most recent release survives, an older one blocks again.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(1)
    int snapReleaseLimit,
    @Default(false) bool showBgVideo,
    @Default(30) int fgVolumePercent,
    @Default(false) bool fgMuted,
    @Default(100) int bgVolumePercent,
    @Default(false) bool bgMuted,
    @Default(1.0) double rate,
    @Default(true) bool shuffle,
    @Default(Repeat.all) Repeat bgRepeat,
    @Default(<FileItem>[]) List<FileItem> queue,

    /// How a live run absorbs a membership change of a tag its sources read
    /// from (`bg.queueSyncMode` AUX row). [queue] is a snapshot resolved at
    /// start time, so a newly tagged media only reaches the open queue panel
    /// once something reconciles it; this picks HOW the running queue is
    /// rewritten — [BgQueueSyncMode.rebuild] re-resolves and keeps the playing
    /// file, [BgQueueSyncMode.append] only adds what is missing. Default
    /// [BgQueueSyncMode.rebuild].
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(BgQueueSyncMode.rebuild)
    BgQueueSyncMode queueSyncMode,
  }) = _BackgroundPlaybackState;

  factory BackgroundPlaybackState.fromJson(Map<String, dynamic> json) =>
      _$BackgroundPlaybackStateFromJson(json);
}
