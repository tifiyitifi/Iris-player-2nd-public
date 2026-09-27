/// Release-notes shaping.
///
/// The published release body is a single markdown document holding both
/// languages under sibling `###` headings (the changelog template writes
/// `### Changelog` followed by `### 更新日志`). Rendering it verbatim would show
/// every reader both languages, so the section matching the UI language is
/// extracted; when the body has no such split, the whole body is shown, which
/// keeps hand-written or single-language notes working unchanged.
library;

const String englishNotesHeading = '### Changelog';
const String chineseNotesHeading = '### 更新日志';

/// Which language the dialog is rendered in.
enum NotesLanguage { english, chinese }

NotesLanguage notesLanguageForLocale(String languageCode) =>
    languageCode.toLowerCase().startsWith('zh')
        ? NotesLanguage.chinese
        : NotesLanguage.english;

/// Returns the notes section for [language].
///
/// Selection is by heading, not by position: a body that only has one of the
/// two headings, or has neither, falls back to the full text. Returns an empty
/// string only when the body itself is empty, which the caller renders as
/// "no notes" rather than as a blank box.
String localizedReleaseNotes(String body, NotesLanguage language) {
  final trimmed = body.trim();
  if (trimmed.isEmpty) return '';

  final english = _sectionFor(trimmed, englishNotesHeading);
  final chinese = _sectionFor(trimmed, chineseNotesHeading);

  final wanted = switch (language) {
    NotesLanguage.english => english,
    NotesLanguage.chinese => chinese,
  };
  if (wanted != null && wanted.trim().isNotEmpty) return wanted.trim();

  // Only one language present: use it regardless of the requested one rather
  // than showing nothing.
  final onlyOne = english ?? chinese;
  if (onlyOne != null && onlyOne.trim().isNotEmpty) return onlyOne.trim();

  return trimmed;
}

/// The text under [heading], up to the next heading of the same or higher
/// level, with the heading line itself removed. Null when [heading] is absent.
String? _sectionFor(String body, String heading) {
  final lines = body.split('\n');
  final normalizedHeading = _normalizeHeading(heading);

  int? start;
  for (var i = 0; i < lines.length; i++) {
    if (_normalizeHeading(lines[i]) == normalizedHeading) {
      start = i + 1;
      break;
    }
  }
  if (start == null) return null;

  final buffer = <String>[];
  for (var i = start; i < lines.length; i++) {
    if (_isHeading(lines[i])) break;
    buffer.add(lines[i]);
  }
  return buffer.join('\n');
}

String _normalizeHeading(String line) {
  var text = line.trim();
  while (text.startsWith('#')) {
    text = text.substring(1).trim();
  }
  return text.toLowerCase();
}

bool _isHeading(String line) => line.trimLeft().startsWith('#');
