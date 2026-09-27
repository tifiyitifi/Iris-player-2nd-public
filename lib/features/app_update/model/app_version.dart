/// Semantic-version comparison for the update check.
///
/// Why a dedicated parser: release tags are third-party input. A repository
/// can carry a non-version tag (`2.0.0.local`, a leftover from a local build)
/// that is neither a draft nor a prerelease, so GitHub may hand it back as the
/// "latest release". Blindly `int.parse`-ing every dot segment used to throw
/// and the whole check reported "no new version" — indistinguishable from a
/// successful up-to-date answer.
///
/// So parsing is total: [parseVersion] returns `null` instead of throwing, and
/// [compareVersions] propagates that as `null`. Callers must treat `null` as
/// "cannot tell", never as "up to date".
library;

/// Parses `v2.0.4`, `2.0.4`, `2.0.4+10` into `[2, 0, 4]`.
/// Build metadata (`+10`) is dropped: the release tag is the contract, and a
/// build bump without a tag bump is deliberately not an update.
/// Returns `null` when any segment is not a plain non-negative integer, so
/// `2.0.0.local` and `nightly` are rejected rather than coerced.
List<int>? parseVersion(String raw) {
  var text = raw.trim();
  if (text.isEmpty) return null;
  if (text.startsWith('v') || text.startsWith('V')) {
    text = text.substring(1);
  }
  final plus = text.indexOf('+');
  if (plus >= 0) text = text.substring(0, plus);

  final segments = text.split('.');
  if (segments.isEmpty) return null;
  final parts = <int>[];
  for (final segment in segments) {
    if (segment.isEmpty) return null;
    final value = int.tryParse(segment);
    if (value == null || value < 0) return null;
    parts.add(value);
  }
  return parts;
}

/// Three-way comparison of two dotted versions.
///
/// Returns a negative number when [a] is older, `0` when equal, a positive
/// number when [a] is newer. Missing trailing segments count as `0`, so
/// `2.0` and `2.0.0` are equal. `null` when either side is unparseable.
int? compareVersions(String a, String b) {
  final left = parseVersion(a);
  final right = parseVersion(b);
  if (left == null || right == null) return null;
  final length = left.length > right.length ? left.length : right.length;
  for (var i = 0; i < length; i++) {
    final l = i < left.length ? left[i] : 0;
    final r = i < right.length ? right[i] : 0;
    if (l != r) return l - r;
  }
  return 0;
}
