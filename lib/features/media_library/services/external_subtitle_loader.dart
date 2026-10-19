import 'dart:async';

import 'package:iris/utils/logger.dart';
import 'package:media_kit/media_kit.dart';

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// How long to watch the engine error stream after issuing a `sub-add`.
///
/// mpv reports a broken external subtitle asynchronously (long after the
/// command returns), so the window has to be generous enough to catch a failing
/// remote fetch without holding the UI open.
const Duration kExternalSubtitleErrorWindow = Duration(seconds: 5);

/// Ownership of the engine error STREAM between external-subtitle attempts.
///
/// The stream is shared by every attempt and the failure wording may carry no
/// address ("Can not open external file."), so an attempt must stop consuming
/// errors the moment a NEWER one starts: otherwise a call for a file the user
/// has already left completes on the new file's error and reports a failure for
/// the wrong subtitle. `begin` hands out the ownership token, `owns` answers
/// whether a token is still the newest.
///
/// The counter is monotonic and process-wide on purpose: two openings of the
/// same URI are still two attempts, and the older one has nothing to say.
class ExternalSubtitleOpenAttempts {
  int _generation = 0;

  /// Starts a new attempt and supersedes every earlier one.
  int begin() => ++_generation;

  /// Whether [generation] is still the attempt that owns the stream.
  bool owns(int generation) => generation == _generation;

  /// Test seam: forget every attempt.
  void reset() => _generation = 0;
}

/// The process-wide attempt registry (see [ExternalSubtitleOpenAttempts]).
final ExternalSubtitleOpenAttempts externalSubtitleAttempts =
    ExternalSubtitleOpenAttempts();

/// Hands an external subtitle [uri] to a media_kit [player] and reports whether
/// the engine accepted it.
///
/// `Player.setSubtitleTrack` returns successfully even when mpv cannot open a
/// remote subtitle: the failure only surfaces later on `player.stream.error`
/// (`Failed to open <uri>` / `Can not open external file <uri>`). Historically
/// that was invisible — the track panel simply closed, so a dead subtitle URL
/// read as a dead button. Watch the error stream for
/// [kExternalSubtitleErrorWindow] and report the outcome so the caller can
/// explain it (house rule: a Dialog, never a SnackBar).
///
/// Returns `true` when no failure was observed (the subtitle is loading / has
/// loaded), `false` when the engine reported the open failure or the command
/// itself threw. A call superseded by a newer one also returns `true`: it must
/// not report a failure for a file the user has already left (the newer attempt
/// owns the outcome).
Future<bool> tryLoadExternalSubtitle(
  Player player, {
  required String uri,
  required String title,
}) =>
    loadExternalSubtitleOnEngine(
      attempts: externalSubtitleAttempts,
      open: () => player.setSubtitleTrack(SubtitleTrack.uri(uri, title: title)),
      errors: player.stream.error,
      uri: uri,
    );

/// The engine-facing core of [tryLoadExternalSubtitle].
///
/// Split out on purpose: the supersede / throw / timing contract below is the
/// whole point of the loader, and it must be testable without a native player
/// (a `Player` cannot be constructed in a unit test).
///
/// [open] is the `sub-add` command, [errors] the engine's (SHARED) error
/// stream, [attempts] the process-wide ownership registry. [errorWindow] is a
/// seam for tests only — production uses [kExternalSubtitleErrorWindow].
Future<bool> loadExternalSubtitleOnEngine({
  required ExternalSubtitleOpenAttempts attempts,
  required Future<void> Function() open,
  required Stream<String> errors,
  required String uri,
  Duration errorWindow = kExternalSubtitleErrorWindow,
}) async {
  final attempt = attempts.begin();
  final failed = Completer<bool>();
  final sub = errors.listen((e) {
    // Errors arriving after a newer attempt started belong to that attempt.
    if (!attempts.owns(attempt)) return;
    if (!failed.isCompleted && isExternalSubtitleOpenFailure(e, uri)) {
      failed.complete(true);
    }
  });
  try {
    await open();
    if (!attempts.owns(attempt)) return true;
    final didFail = await failed.future.timeout(
      errorWindow,
      onTimeout: () => false,
    );
    if (!attempts.owns(attempt)) return true;
    if (didFail) _log.w('External subtitle failed to open: $uri');
    return !didFail;
  } catch (e) {
    _log.e('setSubtitleTrack threw for $uri', e);
    // A THROWN command is an attempt OUTCOME like any other, so it owes the
    // same supersede check as the awaited path above: returning `false` for an
    // attempt the user has already left raises the failure dialog for the
    // WRONG subtitle (a slow link failing exactly as the next one is opened).
    return !attempts.owns(attempt);
  } finally {
    await sub.cancel();
  }
}

/// True when [error] looks like the engine failing to open the external
/// subtitle at [uri].
///
/// mpv echoes the address verbatim, so a substring test against the requested
/// URI is exact, and a percent-normalizing echo is covered by also matching the
/// decoded form (and the decoded `path=` tail of a proxy address).
///
/// When the engine DROPS the address ("Can not open external file.") that
/// generic wording is the LAST resort — mpv uses it for ANY external file it
/// cannot open (an external audio track, cover art), so it is accepted ONLY when
/// the line names no OTHER address. Two shapes follow the wording:
///  * nothing (`external file.`), or
///  * the subsystem's reason (`external file. No such file or directory`),
/// while a decoy names a different file (`external file cover-art.jpg`).
/// A path separator in the tail proves a different address; otherwise the wording
/// is accepted only when the tail reads as a known failure REASON.
bool isExternalSubtitleOpenFailure(String error, String uri) {
  for (final form in _subtitleAddressForms(uri)) {
    if (form.isNotEmpty && error.contains(form)) return true;
  }
  final match =
      RegExp('external file', caseSensitive: false).firstMatch(error);
  if (match == null) return false;
  final tail = error.substring(match.end);
  // Address-less means nothing but punctuation/space follows the wording.
  if (!RegExp('[A-Za-z0-9]').hasMatch(tail)) return true;
  // A recognized failure REASON outranks the separator heuristic: mpv's errno
  // wording can itself carry a slash ("I/O error", "input/output error"), which
  // the address test would otherwise read as "another path is named". Strip the
  // reason wordings first, so a tail that ALSO names a real address still loses.
  if (_kAddresslessReasons.any((re) => re.hasMatch(tail))) {
    var rest = tail;
    for (final re in _kAddresslessReasons) {
      rest = rest.replaceAll(re, ' ');
    }
    // A reason never names a real address. After stripping the reason wording,
    // any leftover path separator or filename-looking token (`cover-art.jpg`)
    // proves a DIFFERENT address: a decoy file whose own open failed, not this
    // subtitle's failure (the same bare-address rule the no-reason branch uses).
    return !RegExp(r'[/\\]|://|[A-Za-z]:').hasMatch(rest) &&
        !_kBareAddressToken.hasMatch(rest);
  }
  // No recognized reason: a separator proves another address, and an unexplained
  // bare token is a decoy — neither is this subtitle's failure.
  return false;
}

/// The reasons mpv appends after the address-less external-file wording. A bare
/// filename (`cover-art.jpg`) matches none of them, so it stays a decoy.
final List<RegExp> _kAddresslessReasons = [
  RegExp(r'no such file', caseSensitive: false),
  RegExp(r'or directory', caseSensitive: false),
  RegExp(r'\(errno \d+\)', caseSensitive: false),
  RegExp(r'errno \d+', caseSensitive: false),
  RegExp(r'not found', caseSensitive: false),
  RegExp(r'permission denied', caseSensitive: false),
  RegExp(r'access denied', caseSensitive: false),
  RegExp(r'operation not permitted', caseSensitive: false),
  RegExp(r'i/o error', caseSensitive: false),
  RegExp(r'input/output error', caseSensitive: false),
  RegExp(r'no such device', caseSensitive: false),
  RegExp(r'invalid argument', caseSensitive: false),
  RegExp(r'resource temporarily unavailable', caseSensitive: false),
  RegExp(r'connection (refused|reset|closed|timed ?out|timeout)',
      caseSensitive: false),
  RegExp(r'timed ?out', caseSensitive: false),
  RegExp(r'failed to', caseSensitive: false),
];

/// A token that looks like a bare external file ADDRESS (a filename with an
/// extension, e.g. `cover-art.jpg`): a decoy error names one of these, so a
/// reason-stripped tail that still carries one is NOT the subtitle's failure.
final RegExp _kBareAddressToken =
    RegExp(r'[A-Za-z0-9_\-]+\.[A-Za-z0-9]{1,6}\b');

/// The forms [uri] may appear as in the engine's error line.
///
/// Beyond the raw string: up to two percent-decoded forms (mpv echoes a
/// normalized address, and a proxy layer can normalize twice), the decoded
/// `path=` tail of an FTP proxy address, and the fragment of a `#`-suffixed
/// address. A malformed escape (`%`) is skipped, never thrown.
Iterable<String> _subtitleAddressForms(String uri) sync* {
  if (uri.isEmpty) return;
  yield uri;
  var decoded = uri;
  for (var i = 0; i < 2; i++) {
    try {
      final next = Uri.decodeFull(decoded);
      if (next == decoded) break;
      decoded = next;
      yield decoded;
    } on FormatException {
      break;
    } on ArgumentError {
      break;
    }
  }
  try {
    final parsed = Uri.tryParse(uri);
    if (parsed == null) return;
    // The `path=` target of a proxy address, in BOTH the encoded form the
    // address carries and the decoded form the query accessor returns: the
    // engine echoes whichever it dialled.
    final rawPath =
        RegExp(r'(?:^|&)path=([^&]*)').firstMatch(parsed.query)?.group(1);
    if (rawPath != null && rawPath.isNotEmpty) yield rawPath;
    final path = parsed.queryParameters['path'];
    if (path != null && path.isNotEmpty) yield path;
    if (parsed.hasFragment && parsed.fragment.isNotEmpty) {
      yield parsed.fragment;
    }
  } on FormatException {
    // A bare `%`/truncated escape makes the lazy query accessors throw: the raw
    // forms above already covered everything parseable.
  }
}
