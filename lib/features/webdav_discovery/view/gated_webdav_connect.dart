import 'package:flutter/material.dart';
import 'package:iris/features/webdav_discovery/model/discovery_models.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connect_error_dialog.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connecting_content.dart';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/widgets/dialogs/delayed_progress_gate.dart';

/// A remote connect the user is waiting on, with its progress surface.
///
/// Owns the whole "slow work must not look like a hang, fast work must not
/// flash a window" contract in one place so the storagedb tap and the scan
/// preflight cannot drift apart:
///
///  * a connect answered inside the delay is completely silent;
///  * a slower one names the host being tried, and stays dismissible;
///  * a failure takes over that same surface (one window, no close/open
///    flicker) instead of stacking a dialog on top of it;
///  * a run the caller abandons closes that surface too — [dispose] on its own
///    would leave it standing, and an abandoned connect is the one outcome that
///    would otherwise leak a window.
///
/// [endpoint] is what the progress surface says it is contacting — the address
/// pattern being searched. [fail] takes the concrete address that was dialled,
/// which is what a failure should be reported against.
class GatedWebDavConnect {
  GatedWebDavConnect({
    required this.endpoint,
    Duration delay = const Duration(milliseconds: 400),
  }) : _gate = DelayedProgressGate(delay: delay);

  /// Address pattern shown while connecting.
  final String endpoint;

  final DelayedProgressGate _gate;
  WebdavConnectStage _stage = const WebdavResolving(null);

  /// True once the user dismissed the progress surface. Nothing is known about
  /// the far end, so the caller must neither navigate nor report a failure.
  bool get cancelled => _gate.cancelled;

  /// Starts the delay. Nothing appears until it elapses.
  ///
  /// [navigator] must be the ROOT navigator, captured before the caller's first
  /// await: the surface has to sit above the popup route that hosts the caller.
  void arm({required NavigatorState navigator}) {
    _gate.arm(
      navigator: navigator,
      builder: (dialogCtx) => buildWebdavConnectingContent(
        dialogCtx,
        endpoint: endpoint,
        stage: _stage,
        onCancel: () => Navigator.of(dialogCtx).pop(),
      ),
    );
  }

  /// A connect event: [candidate] is the host being tried, or null once
  /// resolution is over and the live root is being listed.
  ///
  /// Wired straight into the coordinator / preflight progress callbacks, so
  /// the user watches the actual search instead of a bare spinner.
  void report(DiscoveryCandidate? candidate) {
    _stage =
        candidate == null ? const WebdavListing() : WebdavResolving(candidate);
    _gate.update();
  }

  /// The connect worked. Returns true when the user gave up first, in which
  /// case the caller must drop the result instead of acting on it.
  Future<bool> succeed() async {
    await _gate.succeed();
    return _gate.cancelled;
  }

  /// The connect failed. Returns what the user chose.
  ///
  /// Goes through the gate even when nothing was ever shown: that is what
  /// cancels the pending progress surface, so a fast failure can never have the
  /// spinner pop up on top of it a moment later.
  Future<WebdavConnectAction> fail({
    String? endpoint,
    StorageListErrorKind? errorKind,
    String? errorDetail,
  }) async {
    final action = await _gate.fail<WebdavConnectAction>(
      failureBuilder: (dialogCtx) => buildWebdavConnectFailure(
        dialogCtx,
        endpoint: endpoint ?? this.endpoint,
        errorKind: errorKind,
        errorDetail: errorDetail,
        onAction: (a) => Navigator.pop(dialogCtx, a),
      ),
    );
    // Dismissed without choosing is the same as an explicit cancel.
    return action ?? WebdavConnectAction.cancel;
  }
  /// The caller gave up: neither navigate nor report, and no window is left
  /// behind. Goes through the gate so a still-visible surface is taken down —
  /// [dispose] alone would leave it standing on the root navigator, where
  /// nothing else can pop it.
  Future<void> cancel() => _gate.cancel();

  /// Releases the gate. Only legal after [succeed] / [fail] / [cancel].
  void dispose() => _gate.dispose();
}
