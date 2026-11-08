import 'package:iris/models/file.dart';
import 'package:iris/utils/path_conv.dart' show isSafPath;

/// Why 简播 cannot run for the current media. `none` = available.
///
/// Each value maps to one localized explanation in the tab, so a blocked user
/// learns WHY instead of seeing a missing/disabled control with no reason.
///
/// Deliberately absent: Virtual Media and 副音 (background playback). Both used
/// to block the whole feature, which was wrong on two counts:
///  * 副音's `enabled` flag is ALSO true for a merely ARMED run (cold-launch
///    `startArmed`, gate closed, nothing loaded), so 简播 reported "cannot be
///    combined with background audio" while nothing was playing;
///  * the two features coexist by EXCLUSION instead: a file with a cut project
///    is skipped by the virtual-merge rules (`vm_fake_cut_exclusions.dart`) and
///    副音 suspends itself for the duration of the cut
///    (`fake_cut_background_scope.dart`). Neither needs a global block.
enum FakeCutBlockReason {
  none,

  /// fvp: the fake timeline is built on mpv's native EDL; fvp has no equivalent
  /// and would need its own seek/completed/loop adapter.
  backend,

  /// SAF / WebDAV / FTP: the `.llc` siblings are not readable through this path.
  unsupportedStorage,

  /// Audio / image / folder: no video timeline to cut.
  notVideo,
}

/// Availability rules for 简播.
///
/// Pure on purpose: every input is passed in, so the UI (and tests) can evaluate
/// the same rules the player hook enforces. The blocking conditions are PRODUCT
/// TRADEOFFS documented on [FakeCutBlockReason], not bugs to fix later.
abstract final class FakeCutPreflight {
  /// Whether [uri] is a plain absolute local path we can read siblings from.
  ///
  /// Deliberately platform-independent (no `path.isAbsolute`): the check must
  /// behave identically in unit tests on any host.
  static bool isLocalFilePath(String uri) {
    if (uri.isEmpty) return false;
    if (isSafPath(uri)) return false;
    // Any URI scheme (http/https/webdav/ftp/file/…) is not a plain path.
    if (uri.contains('://')) return false;
    final bool windowsDrive = RegExp(r'^[A-Za-z]:[\\/]').hasMatch(uri);
    final bool unc = uri.startsWith(r'\\');
    final bool posix = uri.startsWith('/');
    return windowsDrive || unc || posix;
  }

  static FakeCutBlockReason evaluate({
    required bool mediaKitBackend,
    required ContentType? contentType,
    required String uri,
  }) {
    if (!mediaKitBackend) return FakeCutBlockReason.backend;
    if (contentType != ContentType.video) return FakeCutBlockReason.notVideo;
    if (!isLocalFilePath(uri)) return FakeCutBlockReason.unsupportedStorage;
    return FakeCutBlockReason.none;
  }
}
