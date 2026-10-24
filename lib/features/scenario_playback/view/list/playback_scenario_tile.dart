import 'package:flutter/material.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/selection/selection_controller.dart';
import 'package:iris/features/app_instance/services/new_window_launcher.dart';
import 'package:iris/features/app_instance/services/new_window_requests.dart';
import 'package:iris/features/app_instance/view/new_window_dialogs.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_list_sort_by.dart';
import 'package:iris/features/scenario_playback/scan/commands/scenario_source_scan_command.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/coordinator/scenario_browser.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_override_confirm_dialog.dart';
import 'package:iris/features/scenario_playback/view/dialogs/show_version_changed_dialog.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';

/// A tile of the Playback Scenario list tab.
///
/// Mirrors [MediaLibTile]: long-press enters selection, the trailing shows a
/// Play Override button plus a more menu (Play Append / Preview queue / Rename
/// / Delete; hidden while selecting), and tapping opens the single-scenario
/// manager. The leading shows the play-queue-style sequence number ([index]),
/// highlighted when this scenario is the active one. Play Override replaces
/// the workspace, closes the popup (direct video) and starts playback from the
/// scenario's last position (else its first item) even when paused or stopped;
/// Play Append only merges the content and closes the popup without playing.
class PlaybackScenarioTile extends HookWidget {
  const PlaybackScenarioTile({
    super.key,
    required this.onLongPress,
    required this.scenario,
    required this.selection,
    required this.index,
  });

  final VoidCallback onLongPress;
  final Scenario scenario;
  final SelectionController<String> selection;

  /// 1-based position in the scenario tab list (system pinned = 1).
  final int index;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final store = usePlaybackScenarioStore();
    final sortBy = store.select(context, (s) => s.scenarioSortBy);
    final activeId = store.select(context, (s) => s.activeScenarioId);
    final isActive = scenario.id == activeId;

    return ListenableBuilder(
      listenable: selection,
      builder: (_, __) {
        final selected = selection.isSelected(scenario.id);
        final isSystem = scenario.type == ScenarioKind.systemPlaying;
        final isSelecting = !isSystem && selection.isSelecting;

        Widget? trailingMenu;
        if (!isSystem && !isSelecting) {
          trailingMenu = Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              IconButton(
                icon: const Icon(Icons.play_arrow_rounded),
                // Windows drops the payload (AXTree graft race, see
                // rowTooltip); other platforms keep the label.
                tooltip: rowTooltip(t.scn_play_override),
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                onPressed: () =>
                    _playIntoWorkspace(context, override: true),
              ),
              PopupMenuButton<String>(
                tooltip: rowTooltip(null),
                onSelected: (action) async {
                  switch (action) {
                    // Moved to the Play icon button.
                    // case 'playOverride':
                    //   await _playIntoWorkspace(context,
                    //       override: true, direction: popupDirection);
                    case 'playAppend':
                      await _playIntoWorkspace(context, override: false);
                    case 'newWindow':
                      await launchNewWindow(
                        context,
                        newWindowRequestForScenario(scenario.id),
                      );
                    case 'preview':
                      openScenarioPreview(context, scenarioId: scenario.id);
                    case 'scanSources':
                      await ScenarioSourceScanCommand.run(
                        context,
                        scenarioId: scenario.id,
                      );
                    case 'rename':
                      final newName =
                          await showRenameScenarioDialog(context, scenario.name);
                      if (newName != null &&
                          newName.isNotEmpty &&
                          newName != scenario.name) {
                        await store.renameScenario(scenario.id, newName);
                      }
                    case 'delete':
                      final confirmed = await showDeleteScenarioDialog(context);
                      if (confirmed) {
                        await store.deleteScenario(scenario.id);
                      }
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                      value: 'playAppend', child: Text(t.scn_play_append)),
                  if (NewWindowLauncher.isSupported)
                    PopupMenuItem(
                      value: 'newWindow',
                      child: Text(t.lib_play_in_new_window),
                    ),
                  PopupMenuItem(
                      value: 'preview', child: Text(t.scn_preview_queue)),
                  PopupMenuItem(
                    value: 'scanSources',
                    enabled: ScenarioSourceScanCommand.isEnabled(),
                    child: Text(t.scn_scan_sources),
                  ),
                  PopupMenuItem(value: 'rename', child: Text(t.scn_rename)),
                  PopupMenuItem(value: 'delete', child: Text(t.scn_delete)),
                ],
                padding: EdgeInsets.zero,
              ),
            ],
          );
        }

        return ListTile(
          selected: selected,
          leading: isSelecting
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => selection.toggle(scenario.id),
                  visualDensity: VisualDensity.compact,
                )
              : ConstrainedBox(
                  constraints: const BoxConstraints(minWidth: 16),
                  child: Text(
                    '$index',
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight:
                          isActive ? FontWeight.bold : FontWeight.normal,
                      color: isActive
                          ? Theme.of(context).colorScheme.primary
                          : null,
                    ),
                  ),
                ),
          title: Text(
            scenario.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle:
              _getSubtitle(sortBy) != null ? Text(_getSubtitle(sortBy)!) : null,
          trailing: trailingMenu,
          onTap: () {
            if (isSelecting) {
              selection.toggle(scenario.id);
            } else {
              _openManager(context);
            }
          },
          onLongPress: onLongPress,
        );
      },
    );
  }

  Future<void> _openManager(BuildContext context) async {
    await openScenarioManager(context, scenarioId: scenario.id);
  }

  /// Plays this scenario by Override (replace) or Append (merge) into the
  /// SystemPlaying workspace (D2/E1/F2). Both close the popup so the video is
  /// visible directly; Override additionally starts playback (resuming the
  /// scenario's last position, else its first item) even when previously
  /// paused or stopped.
  Future<void> _playIntoWorkspace(
    BuildContext context, {
    required bool override,
  }) async {
    // Capture before any await so the override dialog can use the stable
    // navigator (guarded by navigator.mounted internally).
    final navigator = Navigator.of(context);
    final store = usePlaybackScenarioStore();
    final sys = await ensurePlaybackWorkspace();

    // P5: warn when the scenario changed since its last import (E4 version).
    final wsState = await store.getState(sys.id);
    final importVersion = wsState?.importVersion;
    if (importVersion != null && importVersion < (scenario.version ?? 0)) {
      if (!context.mounted) return;
      final proceed =
          await showVersionChangedDialog(context, scenarioName: scenario.name);
      if (!proceed) return;
    }

    if (override) {
      final ok = await showOverrideConfirmDialog(navigator,
          sourceScenarioName: scenario.name);
      if (!ok) return;
      await store.overrideWorkspace(workspace: sys, source: scenario);
    } else {
      await store.appendWorkspace(workspace: sys, source: scenario);
    }
    await store.bumpPlaybackVersion();

    await store.setActiveScenario(sys.id);
    if (!context.mounted) return;
    // Close the current popup entirely (direct video), then — for Override —
    // start playback even if previously paused or stopped.
    Navigator.of(context).pop();
    if (override) {
      await ScenarioPlaybackActions.playCurrentWorkspace();
    }
  }

  String? _getSubtitle(ScenarioListSortBy sortBy) {
    switch (sortBy) {
      case ScenarioListSortBy.createdAt:
        return 'Created: ${_formatDate(scenario.createdAt)}';
      case ScenarioListSortBy.updatedAt:
        return 'Updated: ${_formatDate(scenario.updatedAt)}';
      default:
        return null;
    }
  }

  String _formatDate(DateTime? date) {
    if (date == null) return '-';
    return '${date.year}-${date.month.toString().padLeft(2, '0')}'
        '-${date.day.toString().padLeft(2, '0')}'
        '-${date.hour.toString().padLeft(2, '0')}'
        ':${date.minute.toString().padLeft(2, '0')}';
  }
}

Future<String?> showRenameScenarioDialog(
  BuildContext context,
  String currentName,
) {
  final t = getLocalizations(context);
  return showKeyboardTextPrompt(
    context: context,
    title: t.scn_rename_title,
    initialValue: currentName,
    hint: t.scn_name_hint,
    confirmLabel: t.scn_save,
    cancelLabel: t.scn_cancel,
  );
}

Future<bool> showDeleteScenarioDialog(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) {
      final t = getLocalizations(ctx);
      return AlertDialog(
        title: Text(t.scn_delete_title),
        content: Text(t.scn_delete_body),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.scn_cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.scn_delete),
          ),
        ],
      );
    },
  );
  return confirmed == true;
}
