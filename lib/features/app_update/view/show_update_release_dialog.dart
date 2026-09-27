import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/release_notes.dart';
import 'package:iris/utils/file_size_convert.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/url.dart';

/// Release notes plus the actions available for this build.
///
/// The notes are shown in the UI language only: the published body carries both
/// languages under sibling headings, and rendering it whole would show every
/// reader a document in two languages at once.
///
/// The chosen package is named explicitly, because on Android it is either a
/// ~72 MB ABI-specific build or a ~186 MB universal one and the difference is
/// worth knowing before the transfer starts. When an ABI-specific package was
/// picked, the universal one is offered as a fallback action rather than as the
/// default — it is the escape hatch for a device whose reported ABI list turns
/// out not to match the package.
Future<void> showUpdateReleaseDialog(
  BuildContext context,
  UpdateAvailable result, {
  required Future<void> Function(ReleaseAsset asset) onInstall,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => _UpdateReleaseDialog(result: result, onInstall: onInstall),
  );
}

class _UpdateReleaseDialog extends HookWidget {
  const _UpdateReleaseDialog({required this.result, required this.onInstall});

  final UpdateAvailable result;
  final Future<void> Function(ReleaseAsset asset) onInstall;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);

    final notes = localizedReleaseNotes(
      result.notes,
      notesLanguageForLocale(Localizations.localeOf(context).languageCode),
    );

    return AlertDialog(
      title: Text('${t.checked_new_version}: v${result.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (notes.isEmpty)
                Text(
                  t.update_result_up_to_date_title,
                  style: theme.textTheme.bodyMedium,
                )
              else
                MarkdownBody(data: notes, shrinkWrap: true),
              const SizedBox(height: 12),
              Text(
                t.update_will_download(
                  result.asset.name,
                  formatFileSize(result.asset.size),
                ),
                style: theme.textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(launchURL(result.pageUrl));
          },
          child: Text(t.releasePage),
        ),
        if (result.universalAsset != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              unawaited(onInstall(result.universalAsset!));
            },
            child: Text(
              t.update_use_universal(
                formatFileSize(result.universalAsset!.size),
              ),
            ),
          ),
        FilledButton(
          onPressed: () {
            Navigator.pop(context);
            unawaited(onInstall(result.asset));
          },
          child: Text(
            '${t.download_and_update} (${formatFileSize(result.asset.size)})',
          ),
        ),
      ],
    );
  }
}
