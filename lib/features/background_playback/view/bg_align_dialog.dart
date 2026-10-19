import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/engine/background_playback_engine.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/virtual_media/interaction/controller/foreground_window_resolver.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/utils/format_duration_to_minutes.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:provider/provider.dart';

/// Which half of the editor a tap on one of the three shared modes targets.
///
/// Local-only UI state (never persisted): `update` seeks the running pair right
/// now; `saveDefault` is read-only — the automatic rule owns the default.
enum _AlignScope { update, saveDefault }

/// The ONE 副音 alignment editor, shared by two shells:
///
/// - the modal ask flow ([showBgAlignModal]) raised by the mandatory
///   remaining-time threshold or the 副音 menu;
/// - the quick-bar 对齐 floating card (`BgQuickPanel.align`), which stays
///   non-modal so playback keeps running underneath.
///
/// 对齐设置 opens with a two-tab switch, mirroring the two things a user can
/// ask of an anchor:
/// - 「更新对齐」 re-aligns the RUNNING pair right now: the three [BgAlignMode]
///   anchors (00:00↔00:00, bg 00:00 at the current fg moment, bg percent at the
///   current fg moment) plus the read-only line for what the AUTOMATIC rule
///   applied. Nothing can be re-aligned until 副音 is mixing, so the modes then
///   stay listed (the card stays reachable for inspection) but render disabled;
/// - 「默认对齐」 is read-only: the default is decided AUTOMATICALLY from the two
///   real durations (`resolveAutoAlignAnchor`), so the tab only explains the
///   rule — there is no option to pick.
///
/// Below both tabs sits a decoupled percent slider (tune first, then pick the
/// percent mode; dragging never seeks), then 「其它设置」: the mandatory
/// remaining-time threshold (`alignAutoPauseRemainSec`) and the
/// [BgExhaustedAction] taken when the current 副音 file ends.
///
/// The anchoring note and the percent caption are dismissible forever (the X
/// persists into `AppState.suppressedWarnings`, restorable from Settings →
/// Warning dialogs).
///
/// The content reads NO `MediaQuery` and owns no text field (the threshold
/// is still picked through a slider dialog), so it is safe in both non-modal
/// and modal shells on a phone.
class BgAlignContent extends HookWidget {
  const BgAlignContent({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final store = useBackgroundPlaybackStore();
    final engine = context.read<BackgroundPlaybackEngine>();
    useListenable(engine);

    final mode = store.select(context, (s) => s.alignMode);
    // 副音 not active: this card is still reachable (a saved-preference surface),
    // so it stays inspectable — but there is no running pair to re-align.
    final gateOpen = store.select(context, (s) => s.gateOpen);
    // The tab switch is local-only (never persisted) and never forced: with the
    // gate shut the 更新对齐 modes are shown disabled instead of hidden.
    final scope = useState(_AlignScope.update);
    final _AlignScope effective = scope.value;
    // The live preview below needs a real 副音 duration; an unknown one has
    // nothing to map onto.
    final bool alignReady = engine.duration > Duration.zero;
    // The automatic rule compares against the foreground FILE duration (the 副音
    // side never virtualizes), so the tail anchor's skipped opening is only
    // computable with it. Duration-only on purpose: the per-tick position
    // subscription belongs to the leaves, not to this whole editor.
    final int fgDurMs = useForegroundDuration(context).durationMs;
    final percent = store.select(context, (s) => s.alignPercent);
    final warnSec = store.select(context, (s) => s.alignAutoPauseRemainSec);
    final exhausted = store.select(context, (s) => s.bgExhaustedAction);
    // Dismiss-forever memory of the percent caption (restorable from
    // Settings → Warning dialogs). The anchoring note is ALWAYS shown: it is the
    // whole 「默认对齐」 tab, and the tab itself is optional to open.
    final appStore = useAppStore();
    final suppressed = appStore.select(context, (s) => s.suppressedWarnings);
    final showPercentHint =
        shouldShowWarning(suppressed, kWarningBgAlignPercentHint);

    // The slider draft is local-only: dragging it rebuilds nothing outside this
    // content and writes nothing until the user commits (release the slider).
    final percentDraft = useState(percent);
    // Re-sync when the persisted share changes elsewhere (e.g. the settings
    // page); a no-op while dragging since the store only changes on release.
    useEffect(() {
      percentDraft.value = percent;
      return null;
    }, [percent]);

    /// Applies [m] to the running pair RIGHT NOW: seeks the 副音 engine from
    /// the current physical foreground moment and records the session mode
    /// (the mirror swallows the landing). Never touches the persisted
    /// default.
    void applyUpdate(BgAlignMode m) {
      final int fgPos = fgPhysicalPositionNow(context);
      final int bgDur = engine.duration.inMilliseconds;
      // The user's alignment is AUTHORITATIVE: publish the offset BEFORE the
      // seek so the mirror keeps the pair on it instead of re-deriving one from
      // the landing (which would silently drop a non-zero offset). The linkage
      // level only decides whether bg follows the fg from here on.
      final int offset = resolveAlignmentOffsetMs(
        mode: m,
        currentFgMs: fgPos,
        bgDurMs: bgDur,
        percent: percent,
        fgDurMs: fgDurMs,
      );
      store.setAlignOffset(offset);
      store.setAlignMode(mode: m, percent: percent, rerun: false);
      // A 00:00-mode alignment whose mapped position lies BEYOND the current
      // file leaves the current fg moment with no bg: under nextBg the runtime
      // observer continues on the looping timeline (and explains it), instead of
      // parking the file at its tail.
      if (store.state.bgExhaustedAction == BgExhaustedAction.nextBg &&
          bgDur > 0 &&
          fgPos - offset >= bgDur) {
        store.noteSystemSeek();
        store.requestBgContinuation(fromAlign: true);
        return;
      }
      final int target = bgAlignTargetMs(
        mode: m,
        fgPosMs: fgPos,
        bgDurMs: bgDur,
        percent: percent,
        fgDurMs: fgDurMs,
      );
      store.noteSystemSeek();
      unawaited(engine.seek(Duration(milliseconds: target)));
      store.clearBgExhausted();
    }

    void onModeTap(BgAlignMode m) => applyUpdate(m);

    // The running pair's current mode is the only highlight: there is no
    // persisted default anymore.
    bool modeSelected(BgAlignMode m) => mode == m;

    /// The LIVE "after aligning: video X → Sub Audio Y" line for one mode.
    ///
    /// The three modes only differ in WHICH 副音 moment maps to the video's
    /// current moment, and that is impossible to picture from a label — so the
    /// result is shown as numbers. A mapped position at/after the file's end is
    /// called out explicitly (it is the case users read as "对齐错了").
    String? previewFor(BgAlignMode m) {
      // Pre-configuration (no 副音 running): there is no live pair to preview.
      if (!gateOpen || !alignReady) return null;
      final int fgNow = fgPhysicalPositionNow(context);
      final int bgDur = engine.duration.inMilliseconds;
      final int target = bgAlignTargetMs(
        mode: m,
        fgPosMs: fgNow,
        bgDurMs: bgDur,
        percent: percentDraft.value,
        fgDurMs: fgDurMs,
      );
      final String bgText =
          formatDurationToMinutes(Duration(milliseconds: target));
      if (target >= bgDur) {
        return t.bg_align_preview_beyond(bgText);
      }
      return t.bg_align_preview(
        formatDurationToMinutes(Duration(milliseconds: fgNow)),
        bgText,
      );
    }

    /// Label of [m], carrying the numbers that make the answer concrete: the
    /// percent mode shows the chosen share, and 尾部锚定 shows how much of the
    /// 副音 opening is skipped to make both files end together.
    String modeLabel(BgAlignMode m) {
      switch (m) {
        case BgAlignMode.sameClock:
          return t.bg_align_mode_same_clock;
        case BgAlignMode.bgHeadAtFg:
          return t.bg_align_mode_bg_head;
        case BgAlignMode.bgPercent:
          return t.bg_align_mode_bg_percent_value(percentDraft.value);
        case BgAlignMode.tailAtFg:
          final int skip = bgAlignTargetMs(
            mode: BgAlignMode.tailAtFg,
            fgPosMs: fgPhysicalPositionNow(context),
            bgDurMs: engine.duration.inMilliseconds,
            percent: percentDraft.value,
            fgDurMs: fgDurMs,
          );
          return t.bg_align_mode_tail(
            formatDurationToMinutes(Duration(milliseconds: skip)),
          );
      }
    }

    Future<void> editWarn() async {
      final v = await _showIntSliderDialog(
        context,
        title: t.bg_align_auto_pause_label,
        value: warnSec,
        min: kMinAlignWarnRemainSec,
        max: kMaxAlignWarnRemainSec,
        suffix: t.bg_align_percent_suffix_short,
      );
      if (v == null) return;
      await store.setAlignAutoPauseRemainSec(v);
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _sectionTitle(context, t.bg_align_section_align),
          // Two tabs: 「更新对齐」 re-aligns the RUNNING pair right now;
          // 「默认对齐」 is read-only — the default is decided AUTOMATICALLY
          // (`resolveAutoAlignAnchor`), so the tab only explains the rule. The
          // switch stays visible even while 副音 is inactive: this card is a
          // saved-preference surface, kept reachable for pre-configuration and
          // inspection.
          SegmentedButton<_AlignScope>(
            segments: [
              ButtonSegment(
                value: _AlignScope.update,
                label: Text(t.bg_align_scope_update),
              ),
              ButtonSegment(
                value: _AlignScope.saveDefault,
                label: Text(t.bg_align_scope_default),
              ),
            ],
            selected: {scope.value},
            onSelectionChanged: (s) => scope.value = s.first,
          ),
          const SizedBox(height: 8),
          if (effective == _AlignScope.update) ...[
            // Nothing to re-align until 副音 is mixing: the three manual anchors
            // stay listed (stable structure) but render disabled.
            if (!gateOpen) ...[
              Text(
                t.bg_align_inactive_hint,
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 6),
            ],
            _radio(
              context,
              enabled: gateOpen,
              selected: modeSelected(BgAlignMode.sameClock),
              title: t.bg_align_mode_same_clock,
              subtitle: previewFor(BgAlignMode.sameClock),
              onTap: () => onModeTap(BgAlignMode.sameClock),
            ),
            const SizedBox(height: 4),
            _radio(
              context,
              enabled: gateOpen,
              selected: modeSelected(BgAlignMode.bgHeadAtFg),
              title: t.bg_align_mode_bg_head,
              subtitle: previewFor(BgAlignMode.bgHeadAtFg),
              onTap: () => onModeTap(BgAlignMode.bgHeadAtFg),
            ),
            const SizedBox(height: 4),
            _radio(
              context,
              enabled: gateOpen,
              selected: modeSelected(BgAlignMode.bgPercent),
              title: modeLabel(BgAlignMode.bgPercent),
              subtitle: previewFor(BgAlignMode.bgPercent),
              onTap: () => onModeTap(BgAlignMode.bgPercent),
            ),
            // What the AUTOMATIC rule decided for the running pair (see
            // `resolveAutoAlignAnchor`). 尾部锚定 has no manual radio, so
            // without this read-only line the applied anchor would be invisible
            // — and the user could not tell why the 副音 started mid-file.
            if (alignReady) ...[
              const SizedBox(height: 6),
              Text(
                t.bg_align_auto_applied(modeLabel(mode)),
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
            ],
          ] else ...[
            // Read-only: the default anchoring IS the automatic rule, so this
            // tab only explains it. Never dismissible — it is the tab's whole
            // content, and the tab itself is optional to open.
            _autoRuleHint(
              context,
              title: t.bg_align_auto_rule_title,
              body: t.bg_align_auto_rule,
            ),
          ],
          const Divider(height: 24),

          _PercentSlider(
            draft: percentDraft.value,
            showHint: showPercentHint,
            hideTooltip: t.bg_align_hint_hide_forever,
            onChanged: (v) =>
                percentDraft.value = v.round().clamp(0, 100),
            onCommit: (v) => unawaited(
              store.setAlignPercent(v.round().clamp(0, 100)),
            ),
            onHideHint: () => unawaited(
              appStore.suppressWarning(kWarningBgAlignPercentHint),
            ),
          ),
          // Semantic boundary: everything above is 对齐设置, everything below
          // is 其它设置.
          const Divider(height: 24),
          _sectionTitle(context, t.bg_align_section_other),
          ListTile(
            key: const ValueKey('bg_align_warn_row'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            leading: const Icon(Icons.timer_outlined, size: 20),
            title: Text(t.bg_align_auto_pause_label),
            subtitle: Text(t.bg_align_auto_pause_desc),
            trailing: Text(t.bg_align_auto_pause_seconds(warnSec)),
            onTap: () => unawaited(editWarn()),
          ),
          const Divider(height: 24),

          _sectionTitle(context, t.bg_exhausted_section),
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              t.bg_exhausted_section_note,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          _radio(
            context,
            selected: exhausted == BgExhaustedAction.nextBg,
            title: t.bg_exhausted_next_bg,
            onTap: () => unawaited(
                store.setBgExhaustedAction(BgExhaustedAction.nextBg)),
          ),
          const SizedBox(height: 4),
          _radio(
            context,
            selected: exhausted == BgExhaustedAction.stopRestoreFg,
            title: t.bg_exhausted_stop_restore,
            onTap: () => unawaited(
                store.setBgExhaustedAction(BgExhaustedAction.stopRestoreFg)),
          ),
        ],
      ),
    );
  }

  Widget _sectionTitle(BuildContext context, String text) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          text,
          style: Theme.of(context)
              .textTheme
              .labelLarge
              ?.copyWith(color: Theme.of(context).colorScheme.primary),
        ),
      );

  /// The default-anchoring note: a read-only explanation of the AUTOMATIC rule.
  /// Never dismissible — it is the whole 「默认对齐」 tab.
  Widget _autoRuleHint(
    BuildContext context, {
    required String title,
    required String body,
  }) {
    final theme = Theme.of(context);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            Icons.info_outline_rounded,
            size: 16,
            color: theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: theme.textTheme.labelMedium),
                const SizedBox(height: 2),
                Text(
                  body,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Compact 24px dismiss button used by the percent hint: tap hides it
  /// forever (persisted), long-press/hover explains where to bring it back.
  static Widget _hintHideButton({
    required Key key,
    required String tooltip,
    required VoidCallback onHide,
  }) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        key: key,
        onTap: onHide,
        borderRadius: BorderRadius.circular(12),
        child: const Padding(
          padding: EdgeInsets.all(4),
          child: Icon(Icons.close_rounded, size: 16),
        ),
      ),
    );
  }

  Widget _radio(
    BuildContext context, {
    required bool selected,
    required String title,
    String? subtitle,
    required VoidCallback onTap,
    VoidCallback? onLongPress,
    bool enabled = true,
  }) {
    final theme = Theme.of(context);
    final Color fg =
        enabled ? theme.colorScheme.primary : theme.disabledColor;
    return InkWell(
      onTap: enabled ? onTap : null,
      onLongPress: enabled ? onLongPress : null,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: fg,
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: enabled ? null : theme.disabledColor,
                    ),
                  ),
                  // The live mapping this mode would produce right now — the
                  // modes are otherwise indistinguishable from their labels.
                  if (subtitle != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(
                        subtitle,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// The decoupled percent tuner: dragging only moves the local [draft] (the
/// parent owns it, so ticks rebuild just this leaf), and the persisted
/// `alignPercent` is written once on release — Drift runs on the UI isolate,
/// so per-tick writes would jank phones. Picking the percent anchor mode
/// afterwards applies the committed share; the slider itself never seeks.
class _PercentSlider extends StatelessWidget {
  const _PercentSlider({
    required this.draft,
    required this.showHint,
    required this.hideTooltip,
    required this.onChanged,
    required this.onCommit,
    required this.onHideHint,
  });

  final int draft;
  final bool showHint;
  final String hideTooltip;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onCommit;
  final VoidCallback onHideHint;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const Icon(Icons.percent_rounded, size: 20),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                t.bg_align_percent_title,
                style: theme.textTheme.titleSmall,
              ),
            ),
            Text(
              '$draft${t.bg_align_percent_suffix_short}',
              style: theme.textTheme.labelLarge,
            ),
          ],
        ),
        Slider(
          key: const ValueKey('bg_align_percent_slider'),
          value: draft.clamp(0, 100).toDouble(),
          min: 0,
          max: 100,
          divisions: 100,
          label: '$draft${t.bg_align_percent_suffix_short}',
          onChanged: onChanged,
          onChangeEnd: onCommit,
        ),
        if (showHint)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  t.bg_align_percent_adjust_hint,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
              BgAlignContent._hintHideButton(
                key: const ValueKey('bg_align_percent_hint_hide'),
                tooltip: hideTooltip,
                onHide: onHideHint,
              ),
            ],
          ),
      ],
    );
  }
}

/// Opens the alignment editor as a MODAL ask, pausing both runtimes for the
/// duration and restoring the previous transport on close.
Future<void> showBgAlignModal(
  BuildContext context, {
  required BackgroundPlaybackEngine engine,
  required MediaPlayer fgPlayer,
}) async {
  final store = useBackgroundPlaybackStore();
  final bool fgWasPlaying = fgPlayer.isPlaying;
  final bool bgWasPlaying = engine.isPlaying;
  // The file open under the prompt: natural completion may advance the queue
  // behind the dialog (the runtime observer stands down while it is up), in
  // which case the newcomer needs one alignment on close (see below).
  final String? entryKey =
      engine.file == null ? null : backgroundMediaKey(engine.file!);
  await engine.pause();
  await fgPlayer.pause();
  store.setPlaying(false);
  if (!context.mounted) {
    await _restoreModal(store, engine, fgPlayer,
        fgWasPlaying: fgWasPlaying, bgWasPlaying: bgWasPlaying);
    return;
  }
  final t = getLocalizations(context);
  // Beats any late open/autoplay that landed behind the dialog; cancelled when
  // it closes so it can never re-pause an already-restored pair.
  final pauseHold = Timer(const Duration(milliseconds: 150), () {
    unawaited(engine.pause());
    unawaited(fgPlayer.pause());
  });
  try {
    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        final w = MediaQuery.sizeOf(dialogContext).width;
        final h = MediaQuery.sizeOf(dialogContext).height;
        return Dialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (w - 24).clamp(0.0, 560.0),
              maxHeight: h * 0.9,
            ),
            // The content is provider-driven (engine + foreground player are
            // captured above and re-provided here, since the dialog's context
            // sits above the player subtree).
            child: Provider<MediaPlayer>.value(
              value: fgPlayer,
              child: ChangeNotifierProvider<BackgroundPlaybackEngine>.value(
                value: engine,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 16, 8, 0),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              t.bg_align_title,
                              style: Theme.of(dialogContext).textTheme.titleMedium,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Flexible(child: BgAlignContent()),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: TextButton(
                          onPressed: () =>
                              Navigator.of(dialogContext).pop(),
                          child: Text(t.ok),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  } finally {
    pauseHold.cancel();
  }
  await _restoreModal(store, engine, fgPlayer,
      fgWasPlaying: fgWasPlaying, bgWasPlaying: bgWasPlaying);
  // A completion behind the dialog leaves the new file unaligned (the runtime
  // observer was stood down): align it once now, with the current mode.
  final String? exitKey =
      engine.file == null ? null : backgroundMediaKey(engine.file!);
  if (context.mounted &&
      modalCloseNeedsRealign(
        entryKey: entryKey,
        exitKey: exitKey,
        enabled: store.state.enabled,
        bgExhausted: store.state.bgExhausted,
      )) {
    final int target = modalCloseRealignTargetMs(
      mode: store.state.alignMode,
      fgPosMs: fgPhysicalPositionNow(context),
      // The FILE duration, not null: 尾部锚定's anchor is `fgDur ↔ bgDur`, and a
      // missing one degraded it to 同刻度 on close only.
      fgDurMs: fgPhysicalDurationNow(context),
      bgDurMs: engine.duration.inMilliseconds,
      percent: store.state.alignPercent,
    );
    if (target > 0) {
      store.noteSystemSeek();
      unawaited(engine.seek(Duration(milliseconds: target)));
    }
    store.clearBgExhausted();
  }
}

Future<void> _restoreModal(
  BackgroundPlaybackStore store,
  BackgroundPlaybackEngine engine,
  MediaPlayer fgPlayer, {
  required bool fgWasPlaying,
  required bool bgWasPlaying,
}) async {
  if (fgWasPlaying) await fgPlayer.play();
  if (shouldRestoreBgAfterModal(
    bgWasPlaying: bgWasPlaying,
    bgExhausted: store.state.bgExhausted,
    gateOpen: store.state.gateOpen,
  )) {
    store.setPlaying(true);
    await engine.play();
  }
}

/// A phone-safe integer slider dialog (no text field, no IME). Returns the
/// picked value, or null when cancelled.
Future<int?> _showIntSliderDialog(
  BuildContext context, {
  required String title,
  required int value,
  required int min,
  required int max,
  required String suffix,
}) {
  final t = getLocalizations(context);
  var draft = value.clamp(min, max);
  return showDialog<int>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (dialogContext, setLocal) {
        final w = MediaQuery.sizeOf(dialogContext).width;
        final h = MediaQuery.sizeOf(dialogContext).height;
        return AlertDialog(
          insetPadding:
              const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
          title: Text(title),
          content: ConstrainedBox(
            constraints: BoxConstraints(
              maxWidth: (w - 24).clamp(0.0, 560.0),
              maxHeight: h * 0.9,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text('$draft$suffix'),
                  Slider(
                    value: draft.toDouble(),
                    min: min.toDouble(),
                    max: max.toDouble(),
                    divisions: (max - min) <= 0 ? null : (max - min),
                    label: '$draft$suffix',
                    onChanged: (v) =>
                        setLocal(() => draft = v.round().clamp(min, max)),
                  ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: Text(t.cancel),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(draft),
              child: Text(t.ok),
            ),
          ],
        );
      },
    ),
  );
}
