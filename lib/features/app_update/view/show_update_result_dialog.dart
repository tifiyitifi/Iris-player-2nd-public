import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/github_release_source.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/url.dart';

/// Read-only outcome dialog: up to date, ahead of the public release, or a
/// failure report. "New version available" is a different dialog (it carries
/// actions) — see `show_update_release_dialog.dart`.
///
/// Every failure offers the same exits, because the usual cause is a network
/// the app cannot use: retry, copy the link for a browser that can, and open
/// the release page. Nothing here degrades to "no new version".
Future<void> showUpdateResultDialog(
  BuildContext context,
  UpdateCheckResult result, {
  Future<void> Function()? onRetry,
}) {
  return showDialog<void>(
    context: context,
    builder: (ctx) => buildUpdateResultDialog(ctx, result, onRetry: onRetry),
  );
}

/// The same dialog as a widget, for a caller that already owns a route.
///
/// A failure that lands while a progress surface is still up renders here and
/// takes that surface over, instead of popping one window and pushing another.
Widget buildUpdateResultDialog(
  BuildContext context,
  UpdateCheckResult result, {
  Future<void> Function()? onRetry,
}) =>
    _UpdateResultDialog(result: result, onRetry: onRetry);

class _UpdateResultDialog extends HookWidget {
  const _UpdateResultDialog({required this.result, this.onRetry});

  final UpdateCheckResult result;
  final Future<void> Function()? onRetry;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    // Stays inside the dialog instead of closing it, so the copy has a visible
    // confirmation without a second popup racing the first one's dismissal.
    final copied = useState(false);

    final title = switch (result) {
      UpToDate() => t.update_result_up_to_date_title,
      AheadOfPublic() => t.update_result_ahead_title,
      CheckFailed() => t.update_result_failed_title,
      UpdateAvailable() => t.checked_new_version,
    };
    final body = switch (result) {
      UpToDate(:final version) => t.update_result_up_to_date_body(version),
      AheadOfPublic(:final current, :final latest) =>
        t.update_result_ahead_body(current, latest),
      CheckFailed() => _failureText(t, result as CheckFailed),
      UpdateAvailable() => '',
    };

    final failed = result is CheckFailed;

    return AlertDialog(
      title: Text(title),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(body, style: Theme.of(context).textTheme.bodyMedium),
              if (copied.value) ...[
                const SizedBox(height: 12),
                Text(
                  t.update_link_copied,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
      ),
      actions: [
        if (failed)
          TextButton(
            onPressed: () async {
              await Clipboard.setData(
                const ClipboardData(text: UpdateSource.latestReleaseUrl),
              );
              copied.value = true;
            },
            child: Text(t.update_copy_link),
          ),
        if (onRetry != null)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              unawaited(onRetry!());
            },
            child: Text(t.update_retry),
          ),
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        if (failed || result is AheadOfPublic)
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              unawaited(launchURL(UpdateSource.latestReleaseUrl));
            },
            child: Text(t.releasePage),
          ),
      ],
    );
  }
}

String _failureText(AppLocalizations t, CheckFailed failure) =>
    switch (failure.reason) {
      UpdateFailure.network => t.update_failed_network,
      UpdateFailure.timeout => t.update_failed_timeout,
      UpdateFailure.http => _refusalText(t, failure.detail),
      // The detail is the address the redirect pointed at: a log record, and
      // nothing a reader can act on.
      UpdateFailure.unreadableReleasePage => t.update_failed_unreadable_page,
      UpdateFailure.malformedTag =>
        t.update_failed_malformed_tag(failure.detail ?? ''),
      UpdateFailure.noAsset => t.update_failed_no_asset,
      UpdateFailure.downloadInterrupted => t.update_download_interrupted,
      UpdateFailure.sizeMismatch => t.update_download_size_mismatch,
      UpdateFailure.hashMismatch => t.update_download_hash_mismatch,
      UpdateFailure.notWritable => t.update_download_not_writable,
      UpdateFailure.unsupportedPlatform => t.update_failed_unsupported,
    };

/// Picks the sentence for a refused request from the status it came back with.
///
/// A number means nothing to the reader, and the three refusals do not want the
/// same thing: being turned away is worth one more try, GitHub being broken is
/// worth none, and a queue is worth waiting out — retrying it sooner only
/// lengthens it, so that sentence has to say so.
String _refusalText(AppLocalizations t, String? detail) {
  // A detail that is not a status at all falls to the generic sentence, which is
  // why it takes a default rather than a nullable.
  final status = int.tryParse(detail ?? '') ?? 0;
  return switch (status) {
    403 => t.update_failed_forbidden,
    429 => t.update_failed_rate_limited,
    >= 500 && < 600 => t.update_failed_server_error,
    _ => t.update_failed_http,
  };
}
