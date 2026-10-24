import 'package:flutter/material.dart';
import 'package:iris/features/scenario_playback/scan/model/scenario_source_refresh_state.dart';
import 'package:iris/utils/get_localizations.dart';

/// Completion summary for a scenario-source refresh run.
///
/// A dialog, never a SnackBar (house rule). Reports what was scanned, what was
/// skipped as unreachable (and therefore NOT cleaned), and the tidy results.
Future<void> showScenarioSourceRefreshSummaryDialog(
  BuildContext context,
  ScenarioSourceRefreshState state,
) {
  final t = getLocalizations(context);
  return showDialog<void>(
    context: context,
    builder: (dialogCtx) {
      final tt = getLocalizations(dialogCtx);
      final stopped = state.phase == ScenarioSourceRefreshPhase.stopped;
      final lines = <String>[
        tt.scn_scan_summary_scanned(state.scannedStorages),
        if (state.skippedStorages > 0)
          tt.scn_scan_summary_skipped(state.skippedStorages),
        if (state.dedupedSources > 0)
          tt.scn_scan_summary_deduped(state.dedupedSources),
        if (state.missingExplicitFiles > 0)
          tt.scn_scan_summary_missing(state.missingExplicitFiles),
        if (state.probedExplicitFiles > 0)
          tt.scn_scan_summary_explicit_refreshed(state.probedExplicitFiles),
      ];
      return AlertDialog(
        title: Text(stopped ? tt.scn_scan_summary_title_stopped : tt.scn_scan_summary_title),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final line in lines)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Text(line),
                ),
              if (state.skippedStorages > 0) ...[
                const SizedBox(height: 8),
                Text(
                  tt.scn_scan_summary_skipped_note,
                  style: Theme.of(dialogCtx).textTheme.bodySmall,
                ),
              ],
            ],
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(t.close),
          ),
        ],
      );
    },
  );
}
