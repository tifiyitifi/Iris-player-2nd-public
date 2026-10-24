import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/platform.dart';
import 'package:path/path.dart' as p;
import 'package:win32/win32.dart';

final _log = AreaKeyLog(LogKeys.legacyUtil);

/// Test seam: drives the package-identity decision on non-Windows hosts.
bool? debugIsPackagedBuildOverride;

/// `GetCurrentPackageFullName`'s "the process has a package, but the buffer is
/// too small" result — which is exactly the probe this file uses.
const int _errorInsufficientBuffer = 122;

/// Why a new window could not be opened. The caller needs the distinction to
/// show the right explanation (unsupported build vs. an oversized selection vs.
/// a real spawn failure).
enum NewWindowLaunchResult {
  launched,
  unsupported,

  /// The `--open-request` payload would exceed the OS command-line limit.
  payloadTooLong,
  failed,
}

/// Spawns a second IRIS process that opens [request] — mpv's model: every window
/// is a full, independent instance, and the OS owns its lifetime.
///
/// Availability is deliberately explicit instead of "try and see": an MSIX
/// (Microsoft Store) build is registered as a single-instance package, so
/// launching its executable directly would produce a process WITHOUT package
/// identity — a different data directory, and therefore a second "library". The
/// entries are hidden there rather than silently misbehaving.
abstract final class NewWindowLauncher {
  /// True when this build can start a real second window.
  static bool get isSupported => isDesktop && !isPackagedBuild;

  /// True when this build has Windows package identity (Store/MSIX).
  ///
  /// WHY not a path check: the install location is not contractual. `WindowsApps`
  /// happens to be today's default, but a side-loaded or external-location
  /// package can live elsewhere — and a false NEGATIVE spawns an identity-less
  /// process with a different data directory (a second "library"), which is the
  /// exact failure the entries are hidden to avoid.
  static bool get isPackagedBuild =>
      debugIsPackagedBuildOverride ?? _hasPackageIdentity();

  static bool _hasPackageIdentity() {
    if (!isWindows) return false;
    final length = calloc<Uint32>();
    try {
      // A null buffer asks only for the required length: a packaged process
      // answers ERROR_INSUFFICIENT_BUFFER (122); an unpackaged one returns
      // APPMODEL_ERROR_NO_PACKAGE (15700).
      return GetCurrentPackageFullName(length, nullptr) ==
          _errorInsufficientBuffer;
    } catch (e) {
      // A broken probe must not enable spawning into a duplicate data root.
      _log.w('package identity probe failed; assuming packaged: $e');
      return true;
    } finally {
      calloc.free(length);
    }
  }

  /// Windows accepts at most 32767 UTF-16 units on a CreateProcess command
  /// line. The payload is ONE base64 argument inside it; keep headroom for the
  /// executable path and quoting so a large selection fails with a clear
  /// message instead of `Process.start` throwing.
  @visibleForTesting
  static const int maxCommandLineChars = 30000;

  /// Approximate command line CreateProcess would receive for [request].
  ///
  /// +3 per argument covers a separator and the surrounding quotes; the exact
  /// quoting rules are not worth reproducing — the threshold has headroom.
  @visibleForTesting
  static int commandLineLength(
    NewWindowRequest request, {
    String? executable,
  }) {
    final int exe = (executable ?? Platform.resolvedExecutable).length;
    return exe +
        request
            .toArguments()
            .fold<int>(0, (total, arg) => total + arg.length + 3);
  }

  /// Starts the new window. The result tells the caller exactly what to say;
  /// never a silent no-op.
  static Future<NewWindowLaunchResult> launch(NewWindowRequest request) async {
    if (!isSupported) return NewWindowLaunchResult.unsupported;
    try {
      final String exe = Platform.resolvedExecutable;
      final int commandLength = commandLineLength(request, executable: exe);
      if (commandLength > maxCommandLineChars) {
        _log.w('new-window payload too long for the command line '
            '($commandLength > $maxCommandLineChars chars)');
        return NewWindowLaunchResult.payloadTooLong;
      }
      await Process.start(
        exe,
        request.toArguments(),
        // The child must find `portable.flag` beside the exe, exactly like a
        // launch from Explorer.
        workingDirectory: p.dirname(exe),
        // DETACHED_PROCESS: no inherited console/stdio pipes. This is a GUI
        // subsystem executable, so nothing is lost, and the child can never
        // block on a pipe nobody drains.
        mode: ProcessStartMode.detached,
      );
      _log.i('spawned new window: ${request.describe()}');
      return NewWindowLaunchResult.launched;
    } catch (e) {
      _log.e('new window spawn failed: $e');
      return NewWindowLaunchResult.failed;
    }
  }

  /// Exposed for tests: the exact argument vector a child receives.
  static List<String> argumentsFor(NewWindowRequest request) =>
      request.toArguments();
}
