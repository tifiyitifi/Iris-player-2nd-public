import 'package:path/path.dart' as path;

/// Dot-separated name tokens of a file, lowercased for a case-insensitive
/// comparison (Windows/NTFS and SMB are case-insensitive).
///
/// Shared by every "which sibling file belongs to this video" rule — external
/// subtitles ([getSubtitleMap]) and LosslessCut `.llc` projects (简播) — so the
/// two cannot drift into different answers for the same folder.
List<String> nameTokens(String fileName) =>
    path.basenameWithoutExtension(fileName).toLowerCase().split('.');

/// Number of leading tokens [a] and [b] share.
int leadingTokenMatch(List<String> a, List<String> b) {
  final max = a.length < b.length ? a.length : b.length;
  var n = 0;
  while (n < max && a[n] == b[n]) {
    n++;
  }
  return n;
}
