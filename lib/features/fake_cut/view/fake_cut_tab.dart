import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/fake_cut/core/fake_cut_preflight.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/services/fake_cut_discovery.dart';
import 'package:iris/features/fake_cut/services/fake_cut_project_index.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';
import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';
import 'package:iris/features/fake_cut/view/fake_cut_texts.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/format_duration_hms.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/widgets/dialogs/show_copyable_error_dialog.dart';
import 'package:provider/provider.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyUi);

/// The third track-panel tab: pick a LosslessCut `.llc` project and play its
/// cut+merge result through a fake timeline.
///
/// UX rules:
///  * the tab is ALWAYS present on the media_kit backend (hiding it would hide
///    the feature); when the environment cannot support it, the REASON is shown
///    instead of an empty list;
///  * plans are discovered when the tab opens and can be refreshed by hand (an
///    externally created `.llc` must not require reopening the video);
///  * activating a plan reopens the media with the generated EDL — audio /
///    subtitle track selection is therefore reset (accepted tradeoff).
class FakeCutTab extends HookWidget {
  const FakeCutTab({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final player = context.watch<MediaPlayer>();
    final PlayQueueItem? item = _currentItem(context);
    final FileItem? file = item?.file;
    final FakeCutStore store = useFakeCutStore();
    final String? fileKey = file == null ? null : fakeCutFileKey(file);

    final List<FakeCutPlanSource> sources = store.select(
      context,
      (FakeCutStoreState s) => fileKey == null
          ? const <FakeCutPlanSource>[]
          : s.plansByFile[fileKey] ?? const <FakeCutPlanSource>[],
    );
    // One list per video: the projects bound to THIS file, and (collapsed) the
    // directory's projects that belong to NO video — a folder is only a
    // container, a project is never shared between videos.
    final List<FakeCutPlanSource> ownPlans = useMemoized(
      () => <FakeCutPlanSource>[
        for (final FakeCutPlanSource source in sources)
          if (source.bound) source,
      ],
      <Object?>[sources],
    );
    final List<FakeCutPlanSource> unmatchedPlans = useMemoized(
      () => <FakeCutPlanSource>[
        for (final FakeCutPlanSource source in sources)
          if (!source.bound) source,
      ],
      <Object?>[sources],
    );
    final ValueNotifier<bool> showUnmatched = useState<bool>(false);
    final String? activePath = store.select(
      context,
      (FakeCutStoreState s) =>
          fileKey == null ? null : s.activePaths[fileKey],
    );
    final bool discovering = store.select(
      context,
      (FakeCutStoreState s) =>
          fileKey == null ? false : s.discovering[fileKey] ?? false,
    );
    // 简播 owns the picture only once the media's OPEN adopted the EDL. A plan
    // that is merely remembered (or whose preparation failed) is not playing,
    // so 副音 must not be reported as suspended for it. Same signal the
    // background suspension reads, so the two can never disagree.
    final bool cutPlaying = store.select(
      context,
      (FakeCutStoreState s) => fileKey != null && s.playingKey == fileKey,
    );

    useEffect(() {
      if (file != null) {
        // Fire-and-forget: the list renders from the store once the scan lands.
        store.discover(file);
      }
      return null;
    }, <Object?>[fileKey, file?.durationMs]);

    final bool backgroundEnabled = useBackgroundPlaybackStore()
        .select(context, (BackgroundPlaybackState s) => s.enabled);
    final bool backgroundSounding = useBackgroundPlaybackStore()
        .select(context, (BackgroundPlaybackState s) => s.bgAutoPlay);
    final FakeCutBlockReason block = FakeCutPreflight.evaluate(
      mediaKitBackend: player is MediaKitPlayer,
      contentType: file?.type,
      uri: file?.uri ?? '',
    );

    if (file == null) return const SizedBox.shrink();
    if (block != FakeCutBlockReason.none) {
      return _MessageView(
        message: fakeCutBlockedText(t, block),
        icon: Icons.info_outline_rounded,
      );
    }

    final FakeCutPlan? activePlan =
        fileKey == null ? null : store.activePlanFor(fileKey);
    // 简播 does not block anything any more — it just needs the user to know
    // WHEN it applies: 副音 pauses here (and resumes on leaving), and a merged
    // session ignores the cut until the file plays on its own. [cutPlaying] is
    // the PLAYING truth (the EDL really opened), not "a plan is remembered".
    final bool backgroundWouldPause =
        backgroundEnabled && backgroundSounding && !cutPlaying;
    final bool inVirtualMerge = VirtualMediaController.instance.isActive;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 4, 4, 0),
          child: Row(
            children: <Widget>[
              Expanded(
                child: Text(
                  t.fake_cut,
                  style: Theme.of(context).textTheme.titleSmall,
                ),
              ),
              IconButton(
                tooltip: t.refresh,
                icon: const Icon(Icons.refresh_rounded),
                onPressed: () => _refresh(context, store, file),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
          child: Text(
            t.fake_cut_hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        if (inVirtualMerge)
          _NoticeLine(
            icon: Icons.merge_type_rounded,
            text: t.fake_cut_vm_merged_notice,
          ),
        if (backgroundWouldPause)
          _NoticeLine(
            icon: Icons.multitrack_audio_rounded,
            text: t.fake_cut_bg_pause_notice,
          ),
        const Divider(height: 1),
        Expanded(
          child: discovering && sources.isEmpty
              ? const Center(child: CircularProgressIndicator())
              : ListView(
                  children: <Widget>[
                    _offTile(
                      context,
                      t,
                      file: file,
                      store: store,
                      active: activePath == null,
                      activeName:
                          activePath == null ? null : activePlan?.displayName,
                    ),
                    for (final FakeCutPlanSource source in ownPlans)
                      _planTile(
                        context,
                        t,
                        file: file,
                        store: store,
                        source: source,
                        active: source.path == activePath,
                      ),
                    if (ownPlans.isEmpty)
                      _MessageView(
                        icon: Icons.content_cut_rounded,
                        message: t.fake_cut_empty,
                        compact: true,
                      ),
                    if (unmatchedPlans.isNotEmpty) ...<Widget>[
                      const Divider(height: 1),
                      ListTile(
                        leading: Icon(
                          Icons.help_outline_rounded,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        title: Text(
                          t.fake_cut_unmatched_section(unmatchedPlans.length),
                          style: TextStyle(
                            color:
                                Theme.of(context).colorScheme.onSurfaceVariant,
                          ),
                        ),
                        trailing: Icon(
                          showUnmatched.value
                              ? Icons.expand_less_rounded
                              : Icons.expand_more_rounded,
                        ),
                        onTap: () =>
                            showUnmatched.value = !showUnmatched.value,
                      ),
                      if (showUnmatched.value) ...<Widget>[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
                          child: Text(
                            t.fake_cut_unmatched_hint,
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(
                                  color: Theme.of(context)
                                      .colorScheme
                                      .onSurfaceVariant,
                                ),
                          ),
                        ),
                        for (final FakeCutPlanSource source in unmatchedPlans)
                          _planTile(
                            context,
                            t,
                            file: file,
                            store: store,
                            source: source,
                            active: false,
                            selectable: false,
                          ),
                      ],
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  /// Re-scans the folder AND lets the rest of the app act on what changed.
  ///
  /// A new `.llc` is not just a new plan list entry: the video must also stop
  /// joining a Virtual Media merge (the group pipeline excludes it), and the
  /// answer of "does this folder have projects" is cached. The refresh is the
  /// documented way to apply a project created while the app was running —
  /// [FakeCutProjectIndex.invalidate] drops the filesystem cache and
  /// [VirtualMediaService.notifyRulesChanged] re-derives the open lists, which
  /// is exactly the "刷新后才实用" contract.
  static Future<void> _refresh(
    BuildContext context,
    FakeCutStore store,
    FileItem file,
  ) async {
    FakeCutProjectIndex.instance.invalidate();
    await store.discover(file, force: true);
    await VirtualMediaService.instance.notifyRulesChanged();
  }

  static PlayQueueItem? _currentItem(BuildContext context) {
    final List<PlayQueueItem> playQueue = usePlayQueueStore()
        .select(context, (PlayQueueState s) => s.playQueue);
    final int currentIndex =
        usePlayQueueStore().select(context, (PlayQueueState s) => s.currentIndex);
    final int index =
        playQueue.indexWhere((PlayQueueItem e) => e.index == currentIndex);
    if (playQueue.isEmpty || index < 0) return null;
    return playQueue[index];
  }

  static Widget _offTile(
    BuildContext context,
    AppLocalizations t, {
    required FileItem file,
    required FakeCutStore store,
    required bool active,
    String? activeName,
  }) {
    return ListTile(
      selected: active,
      leading: active
          ? Icon(Icons.check_circle,
              color: Theme.of(context).colorScheme.primary)
          : null,
      title: Text(
        t.fake_cut_off,
        style: active
            ? TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              )
            : null,
      ),
      subtitle: activeName == null ? null : Text(activeName),
      // Tapping "source" while it is already active would reopen the media for
      // nothing; the user is already watching the uncut file.
      onTap: active
          ? null
          : () async {
              areaKeyLog.i('fake cut: switch back to source');
              await store.deactivate(file);
              if (context.mounted) Navigator.of(context).pop();
            },
    );
  }

  /// One plan row.
  ///
  /// Selection and styling mirror the subtitle list: a single SELECTED row
  /// (`ListTile.selected` + bold primary title, no leading icon otherwise),
  /// tapping applies immediately and closes the panel — there is no separate
  /// "apply" button. Unmatched rows ([selectable] false) render the same way but
  /// cannot be applied.
  static Widget _planTile(
    BuildContext context,
    AppLocalizations t, {
    required FileItem file,
    required FakeCutStore store,
    required FakeCutPlanSource source,
    required bool active,
    bool selectable = true,
  }) {
    final FakeCutPlan? plan = source.plan;
    final List<FakeCutNoticeLine> warnings = <FakeCutNoticeLine>[
      if (source.parseFailure != null)
        FakeCutNoticeLine(
          source.parseFailure == LlcParseFailure.unsupportedVersion
              ? t.fake_cut_unsupported_version
              : t.fake_cut_parse_failed(source.displayName),
          isWarning: true,
        )
      else if (plan != null) ...<FakeCutNoticeLine>[
        ...fakeCutNoticeLines(t, plan),
        if (plan.isEmpty)
          FakeCutNoticeLine(t.fake_cut_no_playable_segment, isWarning: true),
      ],
    ];
    return ListTile(
      enabled: source.usable && selectable,
      selected: active,
      leading: active
          ? Icon(Icons.check_circle,
              color: Theme.of(context).colorScheme.primary)
          : null,
      title: Text(
        source.displayName,
        style: active
            ? TextStyle(
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.primary,
              )
            : null,
      ),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (plan != null) ...<Widget>[
            Text(t.fake_cut_segments(plan.segments.length)),
            Text(t.fake_cut_duration(
                formatDurationHms(Duration(milliseconds: plan.totalMs)))),
          ],
          for (final FakeCutNoticeLine line in warnings)
            Text(
              line.text,
              style: TextStyle(
                color: line.isWarning
                    ? Theme.of(context).colorScheme.error
                    : Theme.of(context).colorScheme.onSurfaceVariant,
                fontSize: 12,
              ),
            ),
        ],
      ),
      onTap: !source.usable || !selectable
          ? null
          : active
              // Already playing this plan: reopening would only reset the
              // tracks. Close the panel instead.
              ? () => Navigator.of(context).pop()
              : () async {
                  final bool started = await store.activate(file, source);
                  if (!context.mounted) return;
                  if (started) {
                    Navigator.of(context).pop();
                    return;
                  }
                  await showCopyableErrorDialog(
                    context,
                    message: t.fake_cut_activate_failed,
                  );
                },
    );
  }
}

/// One informational line above the plan list (简播 + 副音 / virtual merge).
/// Explains how the two features interact HERE instead of blocking anything.
class _NoticeLine extends StatelessWidget {
  const _NoticeLine({required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final Color color = Theme.of(context).colorScheme.onSurfaceVariant;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 16, color: color),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              text,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Neutral message block used for blocked states and the empty plan list.
/// Informational text only — never a SnackBar (house rule).
class _MessageView extends StatelessWidget {
  const _MessageView({
    required this.message,
    required this.icon,
    this.compact = false,
  });

  final String message;
  final IconData icon;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final Widget content = Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(
          icon,
          size: 40,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        const SizedBox(height: 8),
        Text(
          message,
          textAlign: TextAlign.center,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      ],
    );
    return compact
        ? Padding(padding: const EdgeInsets.all(24), child: content)
        : Center(
            child: Padding(padding: const EdgeInsets.all(24), child: content),
          );
  }
}
