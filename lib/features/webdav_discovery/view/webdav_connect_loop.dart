import 'package:iris/features/webdav_discovery/view/gated_webdav_connect.dart';
import 'package:iris/features/webdav_discovery/view/webdav_connect_error_dialog.dart';
import 'package:iris/models/enums/storage_list_error.dart';

/// One attempt at reaching a remote storage, in a shape that does not care
/// whether the far end was reached by discovery (a tile tap) or by a scan
/// preflight.
///
/// A [failed] attempt hands its [gate] over UNDISPOSED: the loop turns that
/// same window into the failure dialog, so the user never sees a spinner close
/// and a dialog open. [connected] and [abandoned] have already disposed theirs.
class ConnectAttempt<T> {
  /// The far end answered. [value] carries whatever the caller needs to go on
  /// with (the resolved entry, typically).
  const ConnectAttempt.connected(this.value)
      : state = ConnectAttemptState.connected,
        gate = null,
        endpoint = null,
        errorKind = null,
        errorDetail = null;

  /// Nothing answered, or it refused us. [errorKind] is the classified reason
  /// the caller already holds; the loop only forwards it, never re-guesses.
  const ConnectAttempt.failed({
    required this.errorKind,
    this.errorDetail,
    required GatedWebDavConnect this.gate,
    this.endpoint,
  })  : state = ConnectAttemptState.failed,
        value = null;

  /// The caller gave up (dismissed the progress surface). Nothing is known
  /// about the far end, so this is not a failure and must not be explained.
  const ConnectAttempt.abandoned()
      : state = ConnectAttemptState.abandoned,
        value = null,
        gate = null,
        endpoint = null,
        errorKind = null,
        errorDetail = null;

  final ConnectAttemptState state;

  /// Success payload; null unless [state] is [ConnectAttemptState.connected].
  final T? value;

  final GatedWebDavConnect? gate;

  /// The address that was actually dialled, when it differs from the pattern
  /// the progress surface was armed with.
  final String? endpoint;

  final StorageListErrorKind? errorKind;
  final String? errorDetail;
}

enum ConnectAttemptState { connected, failed, abandoned }

/// How a [runRemoteConnectLoop] ended.
enum ConnectLoopState {
  /// An attempt answered; [ConnectLoopResult.value] is the payload.
  connected,

  /// The user dismissed the progress surface. Nothing is known about the far
  /// end, so the caller must neither report a failure nor go on.
  abandoned,

  /// The user chose cancel or edit. The entry keeps the state it had.
  settled,
}

class ConnectLoopResult<T> {
  const ConnectLoopResult.connected(this.value)
      : state = ConnectLoopState.connected;
  ConnectLoopResult.abandoned()
      : state = ConnectLoopState.abandoned,
        value = null;
  ConnectLoopResult.settled()
      : state = ConnectLoopState.settled,
        value = null;

  final ConnectLoopState state;
  final T? value;

  bool get connected => state == ConnectLoopState.connected;
}

/// Runs "try to reach this storage, and if that fails let the user decide",
/// for as long as the user keeps choosing retry.
///
/// One place, because the shape was previously written out per call site and
/// the copies drifted: each one re-entered its own lock-guarded entry function
/// to retry, so the retry inherited whatever lock that entry held and could
/// return without doing anything. A loop has no re-entry to inherit, so the
/// attempt that runs is always the one the user asked for.
///
/// [onRunningChanged] reports whether an attempt is in flight. It must be
/// released before the failure dialog is raised: a modal dialog already blocks
/// the surface the lock guards, and holding it across the dialog is what made
/// a retry unreachable.
Future<ConnectLoopResult<T>> runRemoteConnectLoop<T>({
  required Future<ConnectAttempt<T>> Function(int attemptIndex) attempt,
  required Future<void> Function() onEdit,
  required void Function(bool running) onRunningChanged,
}) async {
  for (var index = 0;; index++) {
    onRunningChanged(true);
    final result = await attempt(index);

    switch (result.state) {
      case ConnectAttemptState.connected:
        onRunningChanged(false);
        return ConnectLoopResult<T>.connected(result.value as T);
      case ConnectAttemptState.abandoned:
        onRunningChanged(false);
        return ConnectLoopResult<T>.abandoned();
      case ConnectAttemptState.failed:
        break;
    }

    final gate = result.gate!;
    // The attempt is over the moment its failure is known; the dialog it turns
    // into is the user deciding, not work in flight. Holding the lock across it
    // is what made the retry that follows unreachable.
    onRunningChanged(false);
    final action = await gate.fail(
      endpoint: result.endpoint,
      errorKind: result.errorKind,
      errorDetail: result.errorDetail,
    );
    gate.dispose();

    switch (action) {
      case WebdavConnectAction.retry:
        continue;
      case WebdavConnectAction.edit:
        await onEdit();
        return ConnectLoopResult<T>.settled();
      case WebdavConnectAction.cancel:
        return ConnectLoopResult<T>.settled();
    }
  }
}
