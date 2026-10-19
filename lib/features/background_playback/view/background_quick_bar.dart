import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/actions/background_playback_actions.dart';
import 'package:iris/features/background_playback/engine/background_scope_logic.dart';
import 'package:iris/features/background_playback/hooks/use_foreground_scope_key.dart';
import 'package:iris/features/background_playback/model/enum/bg_seek_link.dart';
import 'package:iris/features/background_playback/model/enum/bg_step_mode.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_mapping_editor.dart';
import 'package:iris/features/background_playback/view/background_quick_bar_grid.dart';
import 'package:iris/features/background_playback/view/background_scope_dialog.dart';
import 'package:iris/features/background_playback/view/bg_alignment_panel.dart';
import 'package:iris/features/background_playback/view/control_target_indicator.dart';
import 'package:iris/features/background_playback/view/media_ratio_dialog.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:iris/widgets/controls/balanced_button_wrap.dart';

/// 副音 quick-control surface.
///
/// Carries ONLY the intents the main bar does not already offer — transport and
/// shuffle/repeat live on the bottom bar and in the scenario queue page, so
/// they are deliberately absent here. Rendered as a column grid beside the side
/// panel or as a row inside the linear bars; [axis] picks the arrangement.
///
/// The bar is shown whenever the user turned it on (independent of whether 副音
/// currently runs); only the master switch and the "对当前" toggle stay
/// interactive while 副音 is off — every other button is greyed rather than
/// hidden.
///
/// Buttons are ordered by USAGE FREQUENCY (T0 master/route/picture → T1 live
/// tuning → T2 one-off preferences), so when a short one-handed panel can only
/// show one column, the primary reach stays on screen and the rarest actions
/// are the ones pushed to the second column / overflow.
class BackgroundQuickBar extends HookWidget {
  const BackgroundQuickBar({
    super.key,
    this.axis = Axis.horizontal,
    this.alignment = MainAxisAlignment.end,
    this.width,
    this.color,
    this.overlayColor,
    this.mirrorColumns = false,
    this.forceVisible = false,
    this.trailingAction,
  });

  /// [Axis.vertical] = the side-panel column grid; [Axis.horizontal] = the
  /// linear-bar row.
  final Axis axis;
  final MainAxisAlignment alignment;

  /// Maximum cross-axis extent for the vertical grid (it shrink-wraps to the
  /// columns it actually needs, so a tall panel stays narrow).
  final double? width;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  /// Vertical grid only: flips the column order so the primary (highest
  /// frequency) column always sits on the side facing the panel/thumb.
  final bool mirrorColumns;

  /// When true the bar renders even while the standalone-quick-bar switch is
  /// OFF. Used by the bottom control-group toggle, which owns its own group
  /// visibility and must not depend on that switch.
  final bool forceVisible;

  /// Extra action appended AFTER the standard buttons — the 副音 menu ("the
  /// counterpart of More on the playback row"). Phone group 2 passes the menu
  /// button here; the button itself belongs to the page layer, so it is handed
  /// in rather than imported.
  ///
  /// The VERTICAL side-panel strip must leave it null: its width budget is
  /// derived from [kQuickBarVerticalActionCount] without measuring the grid, so
  /// an extra action there would under-reserve the strip.
  final Widget? trailingAction;

  @override
  Widget build(BuildContext context) {
    // The feature gate arrives through its OWN subscription, never off
    // `useAppStore().state`: every ancestor of this bar (ControlsOverlay ->
    // ControlBar -> CircleSliderLayout) subscribes to `useMetadataSettings`
    // but NOT to `useLegacyStoragePersistence`, which
    // `toggleUseLegacyStoragePersistence()` writes on its own. The gate needs
    // BOTH, so a bare read survived a live legacy-storage flip — the bar stayed
    // on screen, draggable and tappable, for a subsystem just switched off,
    // and nothing clears `quickBarEnabled`
    // (`EffectsRegistry.legacyStorageBackend` only swaps the storage /
    // play-queue backends). Same shape as the other gate readers
    // (bg_quick_panel_host.dart, player.dart, more_menu_button.dart,
    // tag_play_controller.dart).
    final bool gateEnabled = useAppStore().select(
      context,
      (AppState s) => !s.useLegacyStoragePersistence && s.useMetadataSettings,
    );
    if (!gateEnabled) return const SizedBox.shrink();

    final t = getLocalizations(context);
    final bg = useBackgroundPlaybackStore();
    final enabled = bg.select(context, (s) => s.enabled);
    final gateOpen = bg.select(context, (s) => s.gateOpen);
    final visible = bg.select(context, (s) => s.quickBarEnabled);
    final displayTarget = bg.select(context, (s) => s.displayTarget);
    final controlTarget = bg.select(context, (s) => s.controlTarget);
    final seekLink = bg.select(context, (s) => s.seekLink);
    final lockLevel = bg.select(context, (s) => s.lockLevel);
    final stepMode = bg.select(context, (s) => s.stepMode);
    final mappingEnabled = bg.select(context, (s) => s.mappingEnabled);
    final applyScope = bg.select(context, (s) => s.applyScope);
    final anchorKey = bg.select(context, (s) => s.scopeAnchorKey);
    final offMediaKeys = bg.select(context, (s) => s.bgOffMediaKeys);

    if (!visible && !forceVisible) return const SizedBox.shrink();

    // bg 未激活不提供 apb 功能 — but only for the rows that address the runtime:
    // control/picture routing, and the timeline editor (which must see bg on the
    // air). Saved preferences (作用范围/对齐方式/同步方式/联动等级/换集行为/音量
    // 比例) stay reachable so they can be pre-configured and applied by the next
    // activation.
    //
    // 「作用于当前视频」 belongs to that definition: under 仅当前 the run is
    // anchored to ONE media, so on any other media 副音 is simply not in play —
    // the runtime rows grey out and the gate reads as inactive (its press then
    // ACTIVATES here, see `toggleGateForCurrent`) rather than offering to latch
    // the whole run closed over a media switch the user never touched.
    final bool scopeApplied = resolveApplyToCurrent(
      enabled: enabled,
      applyScope: applyScope,
      anchorKey: anchorKey,
      offMediaKeys: offMediaKeys,
      fgKey: useForegroundScopeKey(context),
    );
    final bool live = enabled && gateOpen && scopeApplied;
    final bool bgIsControl =
        live && controlTarget == ControlTarget.background;
    final bool bgIsDisplayed =
        live && displayTarget == ControlTarget.background;
    // The gate reads the ACTIVATION (gateOpen + this media being in scope),
    // never the transport: a user pause does not cancel it, so the button
    // keeps its active/stop state while bg sits paused — and the next press
    // deactivates (it never resumes; resuming is the transport's job).
    final bool gateActive = live;

    // Frequency order: T0 (master switch, control/picture routing) → T1 (live
    // tuning) → T2 (one-off preferences / advanced). See the class doc.
    final buttons = <Widget>[
      // T0 — The GATE: a pure play/stop permission for the media playing now.
      // Pressing it while playing stops 副音 (like the stop button) and latches
      // it closed across every scope; pressing it again opens the gate (arming
      // the feature on demand). Enabling/disabling the FEATURE and releasing
      // the warm engine live in the 副音 menu — never here.
      _QuickButton(
        tooltip: gateActive ? t.bg_gate_stop : t.bg_gate_play,
        icon: gateActive
            ? Icons.stop_circle_rounded
            : Icons.play_circle_rounded,
        active: gateActive,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => BackgroundPlaybackActions.toggleGateForCurrent(context),
      ),
      // T0 — Control target fg/bg: the reason this bar exists at all.
      _QuickButton(
        tooltip: bgIsControl ? t.bg_control_to_fg : t.bg_control_to_bg,
        icon: bgIsControl
            ? Icons.settings_remote_rounded
            : Icons.settings_input_component_rounded,
        active: bgIsControl,
        enabled: live,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => bg.cycleTarget(),
      ),
      // T0 — Which picture is shown (independent of the controls).
      _QuickButton(
        tooltip: bgIsDisplayed ? t.bg_display_to_fg : t.bg_display_to_bg,
        icon: bgIsDisplayed
            ? Icons.smart_display_rounded
            : Icons.smart_display_outlined,
        active: bgIsDisplayed,
        enabled: live,
        color: color,
        overlayColor: overlayColor,
        onPressed: () {
          bg.setShowBgVideo(true);
          bg.cycleDisplayTarget();
        },
      ),
      // T1 — 联动 (A) — active while linked. Pressing it while inactive
      // switches to linked; pressing it while ALREADY active cycles the
      // sub-mode: full (progress + play/pause + step) ↔ play/pause only.
      _QuickButton(
        tooltip: seekLink != BgSeekLink.linked
            ? t.bg_seek_linked
            : (lockLevel == BgLockLevel.high
                ? t.bg_lock_level_high
                : t.bg_lock_level_low),
        icon: (seekLink == BgSeekLink.linked && lockLevel == BgLockLevel.low)
            ? Icons.pause_circle_outline_rounded
            : Icons.sync_rounded,
        active: seekLink == BgSeekLink.linked,
        color: color,
        overlayColor: overlayColor,
        onPressed: () {
          if (seekLink != BgSeekLink.linked) {
            bg.setSeekLink(BgSeekLink.linked);
          } else {
            bg.setLockLevel(
              lockLevel == BgLockLevel.high
                  ? BgLockLevel.low
                  : BgLockLevel.high,
            );
          }
        },
      ),
      // 完全独立 (B) moved to the 副音 menu: it is a rarely-used terminal mode
      // that does not belong on the always-visible quick bar. The quick bar keeps
      // only the 联动 toggle (high/low cycle above).
      // T1 — 作用范围 picker: a saved preference that is retargeted often, so it
      // takes the slot the low-frequency 音量比例 used to occupy (作用范围 is the
      // more frequent of the promoted pair).
      _QuickButton(
        tooltip: t.bg_scope_button,
        icon: Icons.rule_rounded,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => showBackgroundScopeDialog(context),
      ),
      // T1 — 对齐方式 — always-reachable editor of the running pair's anchor.
      _QuickButton(
        tooltip: t.bg_align_button,
        icon: Icons.align_vertical_center_rounded,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => showBgAlignmentPanel(context),
      ),
      // T2 — 换集行为 (bg 上下集): swapOnly steps only the 副音 track and leaves
      // the video where it is; followLink also moves the video (subject to the
      // link). Independent of 联动/解锁, which govern continuous seeking.
      _QuickButton(
        tooltip: stepMode == BgStepMode.swapOnly
            ? t.bg_step_swap_only
            : t.bg_step_follow_link,
        icon: stepMode == BgStepMode.swapOnly
            ? Icons.swap_horiz_rounded
            : Icons.link_rounded,
        active: stepMode == BgStepMode.followLink,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => bg.setStepMode(
          stepMode == BgStepMode.swapOnly
              ? BgStepMode.followLink
              : BgStepMode.swapOnly,
        ),
      ),
      // T2 — Timeline mapping (advanced, set once). Lit while a saved-mapping
      // segment actually drives 副音 — not merely because the auto-use
      // preference is on (which is the default).
      _QuickButton(
        tooltip: t.bg_mapping_button,
        icon: Icons.timeline_rounded,
        active:
            bg.select(context, (s) => s.mappedFile != null || s.mappedSilenceOn),
        enabled: live,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => showBackgroundMappingEditor(context),
      ),
      // T2 — Mix level: adjusted while watching, like the volume itself, but the
      // least-used action — demoted to the second-to-last slot.
      _QuickButton(
        tooltip: t.bg_volume_ratio,
        icon: Icons.tune_rounded,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => showMediaRatioDialog(context),
      ),
      // T2 — 忽略已保存: bypass the current video's saved Sub Audio A–B timeline.
      // A saved mapping normally OUTRANKS natural 副音 (作用范围 decides WHICH
      // fg need bg), so this is the escape hatch when the user wants the plain
      // loop instead. Persisted (the `bg.useSavedMapping` row) — lit while
      // ignoring.
      _QuickButton(
        tooltip: t.bg_ignore_saved_mapping,
        icon: mappingEnabled
            ? Icons.visibility_off_outlined
            : Icons.visibility_outlined,
        active: !mappingEnabled,
        color: color,
        overlayColor: overlayColor,
        onPressed: () => bg.setMappingEnabled(!mappingEnabled),
      ),
    ];

    if (axis == Axis.vertical) {
      // The side-panel footprint is computed from this count (see
      // `sidewayQuickColumnWidth`), so the two must not drift.
      assert(buttons.length == kQuickBarVerticalActionCount,
          '副音 quick strip action count drifted from '
          'kQuickBarVerticalActionCount');
      assert(trailingAction == null,
          'the vertical 副音 strip must not carry a trailing action: its '
          'width budget is derived from kQuickBarVerticalActionCount');
      // Adaptive grid: the fewest columns (1..kQuickMaxColumns) that fit the
      // panel's current height, so a tall panel stays a single column and a
      // short one widens to two. Still taller than two columns? Fall back to
      // the reverse scroll (last resort), never a RenderFlex overflow.
      return ConstrainedBox(
        constraints: BoxConstraints(maxWidth: width ?? double.infinity),
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final QuickBarGrid grid = resolveQuickBarGrid(
              buttonCount: buttons.length,
              availableHeight: constraints.maxHeight,
              availableWidth: constraints.maxWidth,
            );
            final List<List<Widget>> chunks = _chunkByRows(buttons, grid.rows);
            final List<List<Widget>> ordered =
                mirrorColumns ? chunks.reversed.toList() : chunks;
            final Widget columnsRow = Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                for (int i = 0; i < ordered.length; i++) ...[
                  if (i > 0) const SizedBox(width: kQuickSpacing),
                  Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      for (final Widget b in ordered[i])
                        Padding(
                          padding: const EdgeInsets.symmetric(vertical: 1),
                          child: b,
                        ),
                    ],
                  ),
                ],
              ],
            );
            return SizedBox(
              key: const ValueKey('bg_quick_bar'),
              width: grid.width,
              height: constraints.maxHeight.isFinite
                  ? constraints.maxHeight
                  : null,
              child: grid.fits
                  ? Align(
                      alignment: Alignment.bottomCenter,
                      child: columnsRow,
                    )
                  : SingleChildScrollView(
                      reverse: true,
                      child: columnsRow,
                    ),
            );
          },
        ),
      );
    }
    // Balanced (not greedy) wrapping: on a narrow phone seven buttons can
    // exceed the bar width, and the side panel wants the block balanced with
    // the extra buttons on the bottom rows — the same rule the playback group
    // uses, so the two groups read as one grid whichever one the switch
    // selects. Spacing mirrors that playback group too.
    return BalancedButtonWrap(
      key: const ValueKey('bg_quick_bar'),
      alignment: switch (alignment) {
        MainAxisAlignment.start => WrapAlignment.start,
        MainAxisAlignment.end => WrapAlignment.end,
        MainAxisAlignment.center => WrapAlignment.center,
        _ => WrapAlignment.start,
      },
      spacing: 8,
      runSpacing: 6,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        for (final b in buttons) b,
        if (trailingAction != null) trailingAction!,
      ],
    );
  }
}

/// Splits a column-major strip into per-column chunks of at most [rows].
List<List<Widget>> _chunkByRows(List<Widget> items, int rows) {
  if (rows <= 0) return const <List<Widget>>[];
  final List<List<Widget>> out = <List<Widget>>[];
  for (int i = 0; i < items.length; i += rows) {
    final int end = i + rows <= items.length ? i + rows : items.length;
    out.add(items.sublist(i, end));
  }
  return out;
}

/// One quick-bar button: the SAME footprint as a bottom-bar button — a 48px
/// `IconButton` target carrying the small (secondary) icon the normal playback
/// row uses — plus an accent tint while its state is active.
class _QuickButton extends StatelessWidget {
  const _QuickButton({
    required this.tooltip,
    required this.icon,
    required this.onPressed,
    this.active = false,
    this.enabled = true,
    this.color,
    this.overlayColor,
  });

  final String tooltip;
  final IconData icon;
  final VoidCallback onPressed;
  final bool active;
  final bool enabled;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final Color? tint = !enabled
        ? color?.withValues(alpha: 0.35)
        : active
            ? kBackgroundTargetColor
            : color;
    // NO VisualDensity.compact: the compact capsule is 40px, which read as a
    // smaller group than the playback row beside it (and shrank the tap target).
    return a11yTooltipIconButton(
      context: context,
      tooltip: tooltip,
      icon: Icon(icon, size: kIconSizeSecondary, color: tint),
      onPressed: enabled ? onPressed : null,
      style: ButtonStyle(overlayColor: overlayColor),
    );
  }
}
