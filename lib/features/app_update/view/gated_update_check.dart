import 'package:flutter/material.dart';
import 'package:iris/features/app_update/model/update_check_result.dart';
import 'package:iris/features/app_update/services/update_check_service.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/dialogs/delayed_progress_gate.dart';

/// [checkForUpdate] behind a seam, so the window contract below is exercisable
/// without a network.
typedef UpdateChecker = Future<UpdateCheckResult> Function({
  required String currentVersion,
});

/// One update check, with the window that reports it.
///
/// The same contract as a gated download, and for the same reason: a window
/// nothing can pop is a window that never goes away. This one used to be
/// awaited with no way to close it, so the whole flow — including "already up to
/// date" — stopped on a spinner the moment the answer was in.
///
/// A check that answers inside the gate's delay never opens a window at all, and
/// a dismissed one drops its answer: the work behind it is a read whose result
/// nobody is waiting for any more.
class GatedUpdateCheck {
  GatedUpdateCheck({
    required this.currentVersion,
    this.check = checkForUpdate,
  });

  final String currentVersion;
  final UpdateChecker check;

  final DelayedProgressGate _gate = DelayedProgressGate();

  /// Runs the check behind its window and closes that window the moment the
  /// answer is in — including when the check throws.
  ///
  /// Returns null when the user dismissed the window: the answer is then
  /// reported to nobody. [navigator] must be the ROOT navigator, captured
  /// before the caller's first await.
  Future<UpdateCheckResult?> run({required NavigatorState navigator}) async {
    _gate.arm(navigator: navigator, builder: _buildChecking);
    try {
      final result = await check(currentVersion: currentVersion);
      // Dismissed while waiting: the answer is reported to nobody, and no
      // window comes back for it either.
      return _gate.cancelled ? null : result;
    } finally {
      // Whatever the check answered, the window goes first: nothing else can
      // close it, and this await is the only thing standing between the answer
      // and the dialog that is meant to report it.
      await _gate.succeed();
      _gate.dispose();
    }
  }

  Widget _buildChecking(BuildContext dialogCtx) {
    final t = getLocalizations(dialogCtx);
    return AlertDialog(
      title: Text(t.check_update),
      content: Row(
        children: [
          const SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          const SizedBox(width: 16),
          Expanded(child: Text(t.update_checking)),
        ],
      ),
    );
  }
}
