import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/utils/get_localizations.dart';

/// Settings editor for suppressible warning dialogs (capability_matrix §6).
///
/// Switch ON = the warning shows (default). Only recoverable warnings appear;
/// a fixed footer explains why destructive/error dialogs are absent — they
/// can never be turned off.
Future<void> showWarningDialogPrefsEditor(BuildContext context) =>
    showDialog<void>(
      context: context,
      builder: (_) => const WarningDialogPrefsEditorDialog(),
    );

class WarningDialogPrefsEditorDialog extends HookWidget {
  const WarningDialogPrefsEditorDialog({super.key});

  static Map<String, (String, String)> descriptions(AppLocalizations t) => {
        kWarningPhysicalDeleteRecycle: (
          t.dlg_warn_physical_delete_title,
          t.dlg_warn_physical_delete_desc,
        ),
        kWarningForceAppendNoMedia: (
          t.dlg_warn_force_append_title,
          t.dlg_warn_force_append_desc,
        ),
        kWarningGestureEditCancel: (
          t.dlg_warn_gesture_cancel_title,
          t.dlg_warn_gesture_cancel_desc,
        ),
        kWarningGestureEditReset: (
          t.dlg_warn_gesture_reset_title,
          t.dlg_warn_gesture_reset_desc,
        ),
        kWarningGestureEditConfirm: (
          t.dlg_warn_gesture_confirm_title,
          t.dlg_warn_gesture_confirm_desc,
        ),
        kWarningBgAutoControl: (
          t.dlg_warn_bg_auto_control_title,
          t.dlg_warn_bg_auto_control_desc,
        ),
        kWarningBgAlignExitDiscard: (
          t.dlg_warn_bg_align_exit_title,
          t.dlg_warn_bg_align_exit_desc,
        ),
        kWarningBgAlignSilenceNoFile: (
          t.dlg_warn_bg_align_silence_title,
          t.dlg_warn_bg_align_silence_desc,
        ),
        kWarningBgAlignMovePointHint: (
          t.dlg_warn_bg_align_move_title,
          t.dlg_warn_bg_align_move_desc,
        ),
        kWarningBgAlignPercentHint: (
          t.dlg_warn_bg_align_percent_hint_title,
          t.dlg_warn_bg_align_percent_hint_desc,
        ),
        kWarningBgAlignSnapGuide: (
          t.dlg_warn_bg_align_snap_title,
          t.dlg_warn_bg_align_snap_desc,
        ),
        kWarningBgAlignSnapNone: (
          t.dlg_warn_bg_align_snap_none_title,
          t.dlg_warn_bg_align_snap_none_desc,
        ),
        kWarningBgAlignForceSeek: (
          t.dlg_warn_bg_align_force_seek_title,
          t.dlg_warn_bg_align_force_seek_desc,
        ),
        kWarningBgContinuation: (
          t.dlg_warn_bg_continuation_title,
          t.dlg_warn_bg_continuation_desc,
        ),
        kWarningWebdavSharedHost: (
          t.webdav_shared_host_prompt_title,
          t.webdav_shared_host_prompt_desc,
        ),
        kWarningDragDropScopeRestricted: (
          t.dlg_warn_dragdrop_scope_title,
          t.dlg_warn_dragdrop_scope_desc,
        ),
        kWarningScenarioWorkspace: (
          t.dlg_warn_scenario_workspace_title,
          t.dlg_warn_scenario_workspace_desc,
        ),
        kWarningScenarioBrowsePlayOverride: (
          t.dlg_warn_scenario_browse_play_title,
          t.dlg_warn_scenario_browse_play_desc,
        ),
        kWarningTagCommandGrammar: (
          t.dlg_warn_tag_grammar_title,
          t.dlg_warn_tag_grammar_desc,
        ),
        kWarningVmMergeConcept: (
          t.dlg_warn_vm_concept_title,
          t.dlg_warn_vm_concept_desc,
        ),
        kWarningAppOverview: (
          t.dlg_warn_app_overview_title,
          t.dlg_warn_app_overview_desc,
        ),
      };

  @override
  Widget build(BuildContext context) {
    final store = useAppStore();
    final t = getLocalizations(context);
    final descriptions = WarningDialogPrefsEditorDialog.descriptions(t);
    final suppressed =
        store.select(context, (s) => s.suppressedWarnings);

    return AlertDialog(
      title: Text(t.dlg_warning_title),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              for (final id in kSuppressibleWarningIds)
                SwitchListTile(
                  value: !suppressed.contains(id),
                  onChanged: (show) => show
                      ? store.resetWarning(id)
                      : store.suppressWarning(id),
                  title: Text(descriptions[id]!.$1),
                  subtitle: Text(descriptions[id]!.$2),
                ),
              const SizedBox(height: 8),
              Text(
                t.dlg_warn_footer,
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: suppressed.isEmpty
              ? null
              : () => store.resetSuppressedWarnings(),
          child: Text(t.dlg_restore_all_warnings),
        ),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: Text(t.dlg_done),
        ),
      ],
    );
  }
}
