import 'package:flutter/material.dart';
import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';

/// What a remote connect is doing right now, as shown by the progress surface.
///
/// A wildcard resolve is unbounded (cached hosts → SSDP → a bounded subnet
/// scan) and is followed by a live-root listing, so an opaque spinner would be
/// indistinguishable from a hang. The stage exists to say which of those is
/// happening — and to stop naming a host that is no longer being tried.
sealed class WebdavConnectStage {
  const WebdavConnectStage();
}

/// Still hunting for a host to talk to. [candidate] is null until the first
/// probe starts.
class WebdavResolving extends WebdavConnectStage {
  const WebdavResolving(this.candidate);

  final DiscoveryCandidate? candidate;
}

/// A host answered; the live root is being listed (bounded, but slow enough on
/// a stalled NAS to need explaining).
class WebdavListing extends WebdavConnectStage {
  const WebdavListing();
}

/// The progress surface of a remote connect.
///
/// Dismissible on purpose: an unbounded scan must stay escapable. The host
/// treats the dismissal as "stop waiting" and drops the result — it must not
/// then navigate or report a failure.
Widget buildWebdavConnectingContent(
  BuildContext context, {
  required String endpoint,
  required WebdavConnectStage stage,
  required VoidCallback onCancel,
}) {
  final t = getLocalizations(context);
  final candidate = stage is WebdavResolving ? stage.candidate : null;
  final status = candidate == null
      ? t.storage_connecting(endpoint)
      : t.webdav_testing_host(
          candidate.host,
          candidate.index,
          candidate.total,
        );
  return AlertDialog(
    content: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            const SizedBox(
              width: 20,
              height: 20,
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Text(
                status,
                style: const TextStyle(fontSize: 14),
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        Text(
          _stageLine(stage, t),
          style: Theme.of(context)
              .textTheme
              .bodySmall
              ?.copyWith(color: Theme.of(context).colorScheme.onSurfaceVariant),
        ),
      ],
    ),
    actions: [
      TextButton(onPressed: onCancel, child: Text(t.cancel)),
    ],
  );
}

String _stageLine(WebdavConnectStage stage, AppLocalizations t) =>
    switch (stage) {
      WebdavResolving(candidate: final candidate) => switch (candidate?.stage) {
          DiscoveryStage.cached => t.storage_connecting_stage_cached,
          DiscoveryStage.ssdp => t.storage_connecting_stage_ssdp,
          DiscoveryStage.scan => t.storage_connecting_stage_scan,
          // Before the first probe the coordinator is still opening its first
          // tier, so describe the search rather than a tier that never ran.
          null => t.storage_connecting_stage_ssdp,
        },
      WebdavListing() => t.storage_connecting_listing,
    };
