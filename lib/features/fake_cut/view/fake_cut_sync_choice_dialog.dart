import 'package:flutter/material.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_timeline.dart';
import 'package:iris/utils/format_duration_hms.dart';
import 'package:iris/utils/get_localizations.dart';

/// Asks which virtual sync point to resume at when the saved SOURCE position
/// falls inside several ranges of the cut (overlap / repeated ranges).
///
/// Returns the chosen virtual millisecond, or null when the user cancels — the
/// caller then starts from the beginning rather than guessing.
Future<int?> showFakeCutSyncChoiceDialog(
  BuildContext context, {
  required String savedPosition,
  required List<FakeCutSourceHit> candidates,
}) {
  return showDialog<int>(
    context: context,
    builder: (BuildContext dialogCtx) {
      final t = getLocalizations(dialogCtx);
      return AlertDialog(
        title: Text(t.fake_cut_sync_title),
        content: SizedBox(
          width: 420,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(t.fake_cut_sync_body(savedPosition)),
                const SizedBox(height: 8),
                for (final FakeCutSourceHit hit in candidates)
                  ListTile(
                    dense: true,
                    leading: const Icon(Icons.link_rounded),
                    title: Text(t.fake_cut_sync_candidate(
                      hit.segmentIndex + 1,
                      formatDurationHms(
                          Duration(milliseconds: hit.fakeMs)),
                    )),
                    subtitle: Text(
                      formatDurationHms(Duration(milliseconds: hit.fakeMs)),
                    ),
                    onTap: () => Navigator.of(dialogCtx).pop(hit.fakeMs),
                  ),
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: Text(t.cancel),
          ),
        ],
      );
    },
  );
}
