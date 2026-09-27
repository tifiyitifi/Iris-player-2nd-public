import 'package:device_info_plus/device_info_plus.dart';
import 'package:iris/features/app_update/model/release_info.dart';
import 'package:iris/utils/platform.dart';

/// Where an update would be installed. Decided from the running build, not
/// from the release, because the same release serves every platform.
enum UpdatePlatform { android, windows, unsupported }

/// Outcome of one update check.
///
/// Why four cases instead of "new release or null": the legacy check collapsed
/// "already up to date", "your build is newer than the public release" and
/// "the request failed" into a single `null`, so a blocked network was reported
/// to the user as "no new version". Each case now carries exactly what its
/// dialog needs, and no case can be mistaken for another.
sealed class UpdateCheckResult {
  const UpdateCheckResult();
}

/// [version] is the newest published version; the running build matches it.
final class UpToDate extends UpdateCheckResult {
  const UpToDate({required this.version, this.publishedAt});

  final String version;
  final DateTime? publishedAt;
}

/// The running build is strictly newer than anything published — a development
/// or pre-release install. This is NOT "no update available": telling such a
/// user to wait would be wrong, and reporting it as up-to-date would hide why
/// the check found nothing.
final class AheadOfPublic extends UpdateCheckResult {
  const AheadOfPublic({required this.current, required this.latest});

  final String current;
  final String latest;
}

final class UpdateAvailable extends UpdateCheckResult {
  const UpdateAvailable({
    required this.tag,
    required this.version,
    required this.pageUrl,
    required this.notes,
    required this.platform,
    required this.asset,
    this.universalAsset,
    this.publishedAt,
    this.portable = false,
  });

  /// Raw release tag, e.g. `v2.0.5`. Used to locate the published checksums.
  final String tag;

  /// Newest published version, without the leading `v`.
  final String version;

  /// Human-facing release page.
  final String pageUrl;

  /// Release notes, still in the repository's markdown shape (bilingual).
  final String notes;

  final UpdatePlatform platform;

  /// The package chosen for this build: ABI-specific on Android, ZIP for the
  /// portable Windows edition, installer otherwise. Resolved during the check
  /// so the view layer never re-derives a selection.
  final ReleaseAsset asset;

  /// Android only: the universal package, offered as an escape hatch when the
  /// ABI-specific build turns out not to install. Null on Windows, and null
  /// when [asset] already is the universal package.
  final ReleaseAsset? universalAsset;

  final DateTime? publishedAt;

  /// Windows only: the portable edition updates by overwriting its own folder,
  /// not by running an installer.
  final bool portable;
}

/// The check could not produce an answer. [reason] separates the cases a user
/// can act on from the ones they cannot.
final class CheckFailed extends UpdateCheckResult {
  const CheckFailed(this.reason, {this.detail});

  final UpdateFailure reason;

  /// What made the answer unusable: a status code, an offending tag, or the
  /// address a redirect pointed at. Written to the log and never shown — the
  /// wording the reader sees is the plain sentence each reason maps to.
  final String? detail;
}

/// Why a check could not produce an answer.
///
/// Every member carries two lines, because three different people read it: the
/// person fixing a bug reads the first, the person who wrote the wording reads
/// the second, and the reader never sees either.
///
/// The second line is a constraint, not a comment. A single sentence that has
/// to cover two different causes is the defect that produced this enum's worst
/// bug: one `null` meant both "nothing was ever published" and "I could not
/// find out", so a blocked network was reported to the user as "you are up to
/// date". When two causes need different words, they need different members.
enum UpdateFailure {
  /// Professional: nothing left the device — no route, DNS failure, a refused
  /// connection, or a rejected TLS handshake. No answer was ever requested.
  /// [CheckFailed.detail] is null.
  /// Plain: the app never got as far as asking.
  network,

  /// Professional: the connection was established but the response did not
  /// arrive inside the read deadline, so the request was abandoned.
  /// Plain: it asked, nobody answered in time, and it gave up.
  timeout,

  /// Professional: a final answer that carried no usable payload — for a check,
  /// one that is neither a tag redirect nor a 404; for a transfer, any status
  /// that is not the 200 carrying the bytes. 403 (the anonymous request was
  /// refused, typically as a bot challenge), 429 (the anonymous rate limit), 5xx
  /// (GitHub or its gateway is down), a 404 for an asset the release no longer
  /// publishes, or a proxy's own error page. [CheckFailed.detail] carries the
  /// status, and it is what picks the sentence.
  /// Plain: it reached GitHub and was turned away, made to wait its turn, or
  /// found GitHub broken.
  http,

  /// Professional: an answer that carried no version at all — a 200 with no
  /// redirect target (the page served directly, or something on the network
  /// answering in its place), or a redirect to something that is not
  /// `/releases/tag/<tag>` (a sign-in challenge, the repository root).
  /// [CheckFailed.detail] carries the address, for the log only.
  /// Plain: it got an answer, but the answer was not a list of versions.
  unreadableReleasePage,

  /// Professional: the newest published tag is not a version number. A leftover
  /// local-build tag such as `2.0.0.local` is neither draft nor prerelease, so
  /// GitHub reports it as the latest release. [CheckFailed.detail] carries the
  /// tag.
  /// Plain: the newest release is named something that is not a version, so
  /// there is nothing to compare against.
  malformedTag,

  /// Professional: the release exists but ships no package matching this
  /// platform, ABI list and portable flag.
  /// Plain: the new version is out, but there is nothing to install here.
  noAsset,

  /// Professional: the transfer ended before the byte count the release
  /// advertised.
  /// Plain: the download stopped before it finished.
  downloadInterrupted,

  /// Professional: the file on disk is not the size the release advertised.
  /// Plain: the file that arrived is the wrong size, so it was thrown away.
  sizeMismatch,

  /// Professional: the file's digest does not match the published checksum.
  /// Plain: the file that arrived is not the one that was published, so it was
  /// thrown away.
  hashMismatch,

  /// Professional: the package could not be written to the device — no space
  /// left, or a directory the app is not allowed to write to.
  /// [CheckFailed.detail] carries the file-system error, for the log only.
  /// Plain: there is no room for the update package, and trying again will not
  /// make more.
  notWritable,

  /// Professional: the running build is neither Android nor Windows, so there
  /// is no package selection to make.
  /// Plain: the app cannot update itself on this system.
  unsupportedPlatform,
}

/// Which platform the running build is, for the update flow.
UpdatePlatform currentUpdatePlatform() {
  if (isAndroid) return UpdatePlatform.android;
  if (isWindows) return UpdatePlatform.windows;
  return UpdatePlatform.unsupported;
}

/// The device-reported ABI list, best-first. Empty off Android, and empty when
/// the plugin fails — both make the picker fall through to the universal APK,
/// which is the safe answer rather than refusing to update at all.
Future<List<String>> resolveSupportedAbis() async {
  if (!isAndroid) return const <String>[];
  try {
    final info = await DeviceInfoPlugin().androidInfo;
    return List<String>.unmodifiable(info.supportedAbis);
  } catch (_) {
    return const <String>[];
  }
}
