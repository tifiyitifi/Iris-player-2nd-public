import 'package:flutter/material.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';

/// One known-issue block of the known-issues dialog.
typedef KnownIssueSection = ({String header, String body});

/// All known issues are intentionally visible on every platform.
///
/// Platform scope belongs in each entry's localized header/body so users can
/// tell where an issue applies without hiding potentially relevant context.
List<KnownIssueSection> knownIssueSections({
  required AppLocalizations t,
}) =>
    [
      (
        header: t.dlg_known_issues_fullscreen_header,
        body: t.dlg_known_issues_fullscreen_body,
      ),
      (
        header: t.dlg_known_issues_thread_header,
        body: t.dlg_known_issues_thread_body,
      ),
      (
        header: t.dlg_known_issues_vm_delete_header,
        body: t.dlg_known_issues_vm_delete_body,
      ),
      (
        header: t.dlg_known_issues_mediakit_header,
        body: t.dlg_known_issues_mediakit_body,
      ),
      (
        header: t.dlg_known_issues_window_close_header,
        body: t.dlg_known_issues_window_close_body,
      ),
      (
        header: t.dlg_known_issues_vm_scale_header,
        body: t.dlg_known_issues_vm_scale_body,
      ),
      (
        header: t.dlg_known_issues_vm_scale_fix_header,
        body: t.dlg_known_issues_vm_scale_fix_body,
      ),
      (
        header: t.dlg_known_issues_vm_multiselect_header,
        body: t.dlg_known_issues_vm_multiselect_body,
      ),
      (
        header: t.dlg_known_issues_scenario_sort_header,
        body: t.dlg_known_issues_scenario_sort_body,
      ),
      (
        header: t.dlg_known_issues_bg_anchor_header,
        body: t.dlg_known_issues_bg_anchor_body,
      ),
      (
        header: t.dlg_known_issues_bg_anchor_vm_header,
        body: t.dlg_known_issues_bg_anchor_vm_body,
      ),
      (
        header: t.dlg_known_issues_seek_step_header,
        body: t.dlg_known_issues_seek_step_body,
      ),
    ];

/// Read-only explainer listing the project's known issues and workarounds.
Future<void> showKnownIssuesDialog(BuildContext context) {
  final sections = knownIssueSections(t: getLocalizations(context));

  return showDialog<void>(
    context: context,
    builder: (ctx) {
      final colorScheme = Theme.of(ctx).colorScheme;
      final textTheme = Theme.of(ctx).textTheme;
      final t = getLocalizations(ctx);

      Widget section(KnownIssueSection s) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(s.header, style: textTheme.titleSmall),
                const SizedBox(height: 4),
                Text(s.body, style: textTheme.bodyMedium),
              ],
            ),
          );

      return AlertDialog(
        icon: Icon(Icons.bug_report_rounded, color: colorScheme.primary),
        title: Text(t.dlg_known_issues_title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final s in sections) section(s),
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: Text(t.dlg_known_issues_got_it),
          ),
        ],
      );
    },
  );
}
