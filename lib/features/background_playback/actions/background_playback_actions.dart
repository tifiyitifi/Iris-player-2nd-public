import 'package:flutter/material.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/services/background_candidate_cache.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_reactivate_mode.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/dialogs/show_confirm_suppressible_dialog.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:provider/provider.dart';

/// Launch / refresh / stop entry points of 副音播放 (control-bar menu + float
/// panel + the auto-enable observer).
abstract final class BackgroundPlaybackActions {
  /// The COMPLETE candidate pool, including the foreground's own file.
  ///
  /// This is what a bg QUEUE holds. The foreground's file is a legitimate
  /// member: the point of the 音库 is that a video the user just watched and
  /// liked can be tagged as a 副音 source for the videos that come AFTER it —
  /// 「看完 A 觉得不错, 顺手打上音库, 之后 B/C/D 就用 A 的音频当副音」. Dropping
  /// A from the list at the moment it is tagged would make that gesture
  /// permanently invisible, and the tag would only take effect on some later
  /// re-resolve.
  ///
  /// The same-file guard therefore does NOT belong here. It is a rule about
  /// WHICH file may play RIGHT NOW, and it lives in the selection paths
  /// ([BackgroundQueueLogic.pickStartIndex], `step`, `advanceOnCompleted`,
  /// `jumpTo`) — never in the listing.
  ///
  /// The raw pool comes from the session candidate cache (resolved once per
  /// source-rules revision). When there is NO active source rule the built-in
  /// library pure-tag source (the reserved 「副音备选」tag) is used — the
  /// zero-active fallback. Cross-rule dedupe is applied inside the resolver.
  static Future<List<FileItem>> resolveCandidatePool() async =>
      List<FileItem>.of(await BackgroundCandidateCache.shared.pool());

  /// Candidates that can be handed to a queue AND played right now, or null
  /// when nothing qualifies.
  ///
  /// The start-time contract: a launch needs at least one candidate that is not
  /// the foreground's own file, otherwise the "no candidates" message is the
  /// honest answer. The returned LIST is still the full pool, so the queue the
  /// launch builds keeps A for the next foreground — only the null case is
  /// filtered.
  static Future<List<FileItem>?> resolveCandidates() async {
    final candidates = await resolveCandidatePool();
    if (candidates.isEmpty) return null;
    if (!hasPlayableCandidate(candidates)) return null;
    return candidates;
  }

  /// Whether at least one entry of [candidates] may play against the current
  /// foreground (the same-file guard, honouring `allowSameFgBgFile`).
  static bool hasPlayableCandidate(List<FileItem> candidates) {
    final fgKey = excludedForegroundKey();
    if (fgKey == null) return candidates.isNotEmpty;
    for (final f in candidates) {
      if (backgroundMediaKey(f) != fgKey) return true;
    }
    return false;
  }

  /// Starts 副音 from a resolved candidate list.
  ///
  /// [applyScope] records the 作用范围 of this run; [anchorKey] is the media a
  /// non-`all` run applies to. [focusControl] is left null so
  /// [BackgroundPlaybackState.autoFocusControl] decides; pass an explicit value
  /// only to override that preference for one call site. [autoplay] is the
  /// foreground's live transport for auto-start callers, so a paused video is
  /// never force-resumed by 副音.
  static Future<void> startWithCandidates(
    List<FileItem> candidates, {
    required bool replace,
    BgApplyScope? applyScope,
    String? anchorKey,
    bool? focusControl,
    bool autoplay = true,
  }) async {
    final store = useBackgroundPlaybackStore();
    if (replace) {
      await store.replaceQueue(candidates);
      // A refresh (no explicit scope/anchor) must NOT drop the run's 仅当前
      // anchor: 作用范围 decides WHICH fg the run applies to, and silently
      // clearing it turned the quick-bar「对当前」off and let 副音 keep playing
      // across a media switch. Only an explicit scope change re-anchors.
      if (applyScope != null) {
        await store.setApplyScope(applyScope);
        store.setScopeAnchor(
          applyScope == BgApplyScope.all ? null : anchorKey,
        );
      }
      return;
    }
    await store.enableWithQueue(
      candidates,
      applyScope: applyScope,
      anchorKey: anchorKey,
      // Forward null so the store applies its `autoFocusControl` preference —
      // passing `false` here silently disabled the whole auto-switch.
      focusControl: focusControl,
      autoplay: autoplay,
    );
  }

  /// The foreground player's live transport, or `true` when unavailable.
  ///
  /// Activation paths seed `bgAutoPlay` from this: the gate is a permission,
  /// not a play command, so a paused foreground must stay paused.
  static bool _foregroundPlaying(BuildContext context) {
    if (!context.mounted) return true;
    try {
      return context.read<MediaPlayer>().isPlaying;
    } catch (_) {
      return true;
    }
  }

  /// Starts 副音 under [scope], explaining what to do when there are no
  /// candidates yet. When 副音 already runs this only re-anchors the run.
  static Future<void> startForScope(
    BuildContext context,
    BgApplyScope scope,
  ) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!BackgroundPlaybackGate.enabled) {
      final t = getLocalizations(context);
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_gate_meta_body,
        type: MessageDialogType.info,
      );
      return;
    }
    final store = useBackgroundPlaybackStore();
    // Scope anchor: the 作用范围 identity (whole virtual video under
    // wholeVirtual), never a bare physical block — otherwise the anchor and the
    // scope observer would disagree on every VM block switch.
    final anchor =
        scope == BgApplyScope.all ? null : currentScopeKey();
    if (store.state.enabled) {
      // Already running: the scope switch only re-anchors the run — EXCEPT
      // when it (re-)applies to the CURRENT foreground ("对当前视频使用副音"):
      // that is an explicit "start bg for THIS fg", so clear the old queue
      // progress and re-align instead of continuing mid-queue.
      await store.setApplyScope(scope);
      store.setScopeAnchor(anchor);
      if (scope != BgApplyScope.all && anchor != null) {
        store.restartForCurrent();
      }
      return;
    }
    final t = getLocalizations(context);
    // Capture the live transport BEFORE the async candidate resolve (a context
    // read across an async gap is forbidden; a mid-resolve fg change is
    // reconciled by the transport mirror anyway).
    final bool fgPlaying = _foregroundPlaying(context);
    final filtered = await resolveCandidates();
    if (filtered == null) {
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_no_candidates_body,
        type: MessageDialogType.info,
      );
      return;
    }
    await startWithCandidates(
      filtered,
      replace: false,
      applyScope: scope,
      anchorKey: anchor,
      // Explicit start still respects the live transport: a paused video is
      // never force-resumed by 副音.
      autoplay: fgPlaying,
    );
    // First explicit activation: explain that the controls (and the blue frame)
    // now belong to 副音. Suppressible from the warning settings.
    if (!context.mounted) return;
    await _notifyAutoControl(context);
  }

  /// Starts 副音 under the persisted 作用范围 (quick-bar power switch ON).
  static Future<void> startForCurrentScope(BuildContext context) =>
      startForScope(context, useBackgroundPlaybackStore().state.applyScope);

  /// Quick-bar gate — the activation switch of 副音 for the media playing now.
  ///
  /// The ACTIVATION ([BackgroundPlaybackState.gateOpen]) is independent of the
  /// transport (`bgAutoPlay`): a user pause never cancels it, so the gate keeps
  /// its active state while bg sits paused — and the next press deactivates
  /// instead of resuming.
  /// - activated → **explicit deactivation** ([BackgroundPlaybackStore.stopGate]):
  ///   bg stops, the gate latches closed (no scope auto-resume/auto-start until
  ///   reopened), the fg↔bg pair runs as fully independent, and the shared
  ///   controls + the picture return to the FOREGROUND. The queue, anchor and
  ///   the warm engine all survive.
  /// - deactivated → opens the gate for the current foreground: arms the run
  ///   when the feature was off, resolves candidates when the queue is empty,
  ///   then honors [BgReactivateMode] under 「仅当前」 (same bg / next bg).
  ///
  /// The gate is scoped to the media playing NOW, so 「仅当前」 decides what a
  /// press means: for a media the run does not apply to, a press ACTIVATES
  /// (anchors here) instead of latching the whole run closed — otherwise a
  /// mere media switch would leave the button offering to kill a run the user
  /// never touched.
  ///
  /// This is deliberately NOT the subsystem power switch: turning it off never
  /// disables the feature or releases the engine — that lives in the 副音 menu
  /// ([setFeatureEnabled] / [releaseResources]).
  static Future<void> toggleGateForCurrent(BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final t = getLocalizations(context);
    if (!BackgroundPlaybackGate.enabled) {
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_gate_meta_body,
        type: MessageDialogType.info,
      );
      return;
    }
    final store = useBackgroundPlaybackStore();
    final fgKey = currentScopeKey();
    if (fgKey == null || fgKey.isEmpty) {
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_no_current_media_body,
        type: MessageDialogType.info,
      );
      return;
    }
    // Capture the live transport BEFORE any async gap: the gate seeds
    // bgAutoPlay from it, and a context read after an await is forbidden (the
    // transport mirror reconciles any change during the resolve).
    final bool fgPlaying = _foregroundPlaying(context);
    // Activated FOR THIS MEDIA → explicit deactivation (the same intent as the
    // bg stop button), even when bg is user-paused: a pause never cancels the
    // activation, so a second press always means "turn it off".
    if (store.state.enabled &&
        store.state.gateOpen &&
        resolveApplyToCurrent(
          enabled: store.state.enabled,
          applyScope: store.state.applyScope,
          anchorKey: store.state.scopeAnchorKey,
          offMediaKeys: store.state.bgOffMediaKeys,
          fgKey: fgKey,
        )) {
      store.stopGate();
      return;
    }
    // The re-activation mode only advances an ALREADY LOADED track; a fresh
    // open (no current file) must land on the queue head, never skip it.
    final bool hadCurrent = store.state.currentIndex >= 0;
    List<FileItem>? fresh;
    if (store.state.queue.isEmpty || !hadCurrent) {
      fresh = await resolveCandidates();
      if (fresh == null) {
        await showMessageDialog(
          navigator,
          title: t.menu_background_playback,
          message: t.bg_no_candidates_body,
          type: MessageDialogType.info,
        );
        return;
      }
    }
    // Arm ONLY once activation can actually proceed: a failed resolve above
    // must not silently turn the feature on as a side effect.
    if (!store.state.enabled) {
      store.armRunStopped();
    }
    if (fresh != null) {
      await store.replaceQueue(fresh);
    }
    final bool stepForward = hadCurrent &&
        store.state.applyScope == BgApplyScope.currentOnly &&
        store.state.bgReactivateMode == BgReactivateMode.nextBg;
    // The gate is a PERMISSION, not a play command: seed the transport from the
    // foreground's live state, so activating while the video is paused opens
    // the gate but never force-resumes the pair (the transport mirror owns the
    // later resume when the user plays the video).
    store.openGate(
      mediaKey: fgKey,
      stepForward: stepForward,
      autoplay: fgPlaying,
    );
    if (!context.mounted) return;
    await _notifyAutoControl(context);
  }

  /// 副音-menu feature switch: ON arms the run (enabled, stopped — no auto-play
  /// until a gate press or a scope transition), OFF fully disables it. Distinct
  /// from the quick-bar gate and from [releaseResources] (which drops the warm
  /// engine too).
  static Future<void> setFeatureEnabled(bool enabled) async {
    if (!BackgroundPlaybackGate.enabled) return;
    final store = useBackgroundPlaybackStore();
    if (enabled) {
      store.armRunStopped();
    } else {
      await store.disable();
    }
  }

  /// 副音-menu "彻底关闭后台": stop the run AND drop the warm secondary engine so
  /// its native resources are released. Re-arm with [reenableSupport].
  static Future<void> releaseResources() async {
    final store = useBackgroundPlaybackStore();
    await store.disable();
    await store.setKeepWarmPlayer(false);
  }

  /// 副音-menu "重新开启副音支持": rebuild the warm engine WITHOUT playing
  /// anything — the next enable is instant and the current media is untouched.
  static Future<void> reenableSupport() async {
    await useBackgroundPlaybackStore().setKeepWarmPlayer(true);
  }

  /// Smart-scope auto-start: the foreground media has a saved 副音 pairing, so
  /// 副音 starts for it without the user asking. Never steals the controls
  /// (that is reserved for explicit activation).
  ///
  /// [autoplay] is the foreground's live transport from the scope observer: an
  /// auto-start while the video is paused opens 副音 paused instead of
  /// force-resuming the pair.
  static Future<void> startForSavedMapping({bool autoplay = true}) async {
    if (!BackgroundPlaybackGate.enabled) return;
    final store = useBackgroundPlaybackStore();
    // An explicit gate stop must never be undone by a saved-pairing auto-start.
    if (!store.state.gateOpen) return;
    if (store.state.enabled) {
      // Already running: re-anchor to the media that owns the saved mapping and
      // restart its alignment. Without this the smart scope's [startBg] landed
      // here and returned, so "已保存副音自动播放" never actually switched 副音.
      store.applyToCurrent(currentScopeKey(), autoplay: autoplay);
      return;
    }
    final filtered = await resolveCandidates();
    if (filtered == null) return;
    await startWithCandidates(
      filtered,
      replace: false,
      applyScope: BgApplyScope.smart,
      anchorKey: currentScopeKey(),
      focusControl: false,
      autoplay: autoplay,
    );
  }

  /// Shows the "controls moved to 副音" notice once (第 3 轮追加需求).
  static Future<void> _notifyAutoControl(BuildContext context) async {
    final store = useBackgroundPlaybackStore();
    if (!store.state.autoFocusControl) return;
    if (store.state.controlTarget != ControlTarget.background) return;
    final t = getLocalizations(context);
    await showInfoSuppressibleDialog(
      context,
      warningId: kWarningBgAutoControl,
      title: t.bg_auto_control_title,
      message: t.bg_auto_control_body,
      // One-time notice: start with "don't show again" ticked. Restorable from
      // Settings → Warning dialogs.
      defaultDontAsk: true,
    );
  }

  /// Legacy More-menu entry (sealed behind
  /// [BackgroundPlaybackGate.legacyMoreMenuEntryEnabled] — sub_media §2).
  static Future<void> open(BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    if (!BackgroundPlaybackGate.enabled) {
      final t = getLocalizations(context);
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_gate_meta_body,
        type: MessageDialogType.info,
      );
      return;
    }
    final store = useBackgroundPlaybackStore();
    if (store.state.enabled) return; // already running — panel is visible
    await _startFromCandidates(navigator, replace: false);
  }

  /// Drops the session 副音 candidate pool so the next read re-resolves.
  ///
  /// NOTE: the pool also re-resolves BY ITSELF whenever the rule fingerprint
  /// changes (id/enabled/kind/pinned/paths/...), so this is a safety net, not a
  /// requirement for the staged manager's edits — it matters for the rare edit
  /// the fingerprint does not cover (name/description only) and for callers
  /// that want to force a rebuild regardless. Never touches a running session.
  static void invalidateSourceRules() {
    if (!BackgroundPlaybackGate.enabled) return;
    BackgroundCandidateCache.shared.invalidate();
  }

  /// Float-panel / manager refresh: re-resolves candidates while playing,
  /// keeping the current file by key when it still exists.
  ///
  /// The pool is ALWAYS dropped so the next start resolves the latest rules;
  /// only a RUNNING session can be re-resolved for playback right now. When 副音
  /// is idle the press used to return silently (a dead button) — it now says so.
  static Future<void> refresh(BuildContext context) async {
    if (!BackgroundPlaybackGate.enabled) return;
    final store = useBackgroundPlaybackStore();
    final navigator = Navigator.of(context, rootNavigator: true);
    invalidateSourceRules();
    if (!store.state.enabled) {
      final t = getLocalizations(context);
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_src_refresh_idle_body,
        type: MessageDialogType.info,
      );
      return;
    }
    await _startFromCandidates(navigator, replace: true);
  }

  static Future<void> _startFromCandidates(
    NavigatorState navigator, {
    required bool replace,
  }) async {
    // Localize BEFORE any await (dialog survives async gaps).
    final t = getLocalizations(navigator.context);
    final filtered = await resolveCandidates();
    if (filtered == null) {
      await showMessageDialog(
        navigator,
        title: t.menu_background_playback,
        message: t.bg_no_candidates_body,
        type: MessageDialogType.info,
      );
      return;
    }
    await startWithCandidates(filtered, replace: replace);
  }
}
