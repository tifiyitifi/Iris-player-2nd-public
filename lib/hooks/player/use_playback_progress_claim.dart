import 'dart:async';

import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/services/media_progress_claim.dart';
import 'package:iris/models/file.dart';

/// Grace period before a leaving file is handed to another window.
///
/// The player's switch/dispose cleanup saves the leaving file's final position
/// ASYNCHRONOUSLY (`persistPlaybackProgress`), and that call is made AFTER this
/// hook's cleanup, so a short grace gives it time to register. Once registered,
/// [MediaProgressClaim.release] waits for the write to finish, so correctness no
/// longer depends on this delay being longer than the DB write (a busy-timeout
/// retry used to outlast it).
const Duration _kHandoverDelay = Duration(milliseconds: 600);

/// Binds the player's currently open [file] to the multi-instance progress
/// claim.
///
/// WHY a hook and not a one-off call at open: the claim must follow the file
/// through its whole life. The first frame that opens a file claims it, and the
/// file this player leaves behind is released the moment a different file
/// replaces it (switch / stop / unmount). A denied instance never needs extra
/// bookkeeping — [MediaProgressClaim] keeps its position in memory instead.
///
/// MUST be called before the hook's open effect so ownership is decided before
/// the resume read (`readPlaybackProgress`) runs for the new file.
void usePlaybackProgressClaim(FileItem? file) {
  final claimedKey = useRef<String?>(null);

  useEffect(() {
    final String? key = file == null
        ? null
        : MediaProgressClaim.keyFor(
            storageId: file.storageId,
            path: file.path.join('/'),
          );
    if (key == claimedKey.value) return null;
    final String? previous = claimedKey.value;
    claimedKey.value = key;
    // Hand the file this player was showing over to another window before
    // taking the new one, so a switch never leaves a stale claim behind.
    if (previous != null) {
      _laterUntrack(previous);
    }
    if (file != null) {
      unawaited(MediaProgressClaim.instance.track(
        storageId: file.storageId,
        path: file.path.join('/'),
      ));
    }
    return null;
  }, [file]);

  // Player torn down (route popped / engine disposed): release immediately
  // instead of waiting for the process to exit.
  useEffect(() {
    return () {
      final String? key = claimedKey.value;
      if (key != null) {
        claimedKey.value = null;
        _laterUntrack(key);
      }
    };
  }, const []);
}

/// Untracks after the leaving file's final save had a chance to land.
///
/// Untracking is refcounted, so a quick switch BACK to the same file inside the
/// window nullifies the pending release (the new track re-incremented it).
void _laterUntrack(String key) {
  unawaited(
    Future<void>.delayed(_kHandoverDelay).then(
      (_) => MediaProgressClaim.instance.untrack(key),
    ),
  );
}
