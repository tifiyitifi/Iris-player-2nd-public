import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/services/release_notes.dart';

/// The shape `CHANGELOG.md` produces: one `##` section per version holding an
/// English and a Chinese `###` block.
const String bilingualBody = '''
## v2.0.4

### Changelog

* Desktop control bar rebuilt
* Scan reliability

### 更新日志

* 桌面控制栏重构
* 扫描可靠性
''';

void main() {
  group('localizedReleaseNotes', () {
    test('shows only the requested language', () {
      expect(
        localizedReleaseNotes(bilingualBody, NotesLanguage.english),
        '* Desktop control bar rebuilt\n* Scan reliability',
      );
      expect(
        localizedReleaseNotes(bilingualBody, NotesLanguage.chinese),
        '* 桌面控制栏重构\n* 扫描可靠性',
      );
    });

    test('never shows the other language alongside', () {
      final english = localizedReleaseNotes(bilingualBody, NotesLanguage.english);
      expect(english, isNot(contains('更新日志')));
      final chinese = localizedReleaseNotes(bilingualBody, NotesLanguage.chinese);
      expect(chinese, isNot(contains('Changelog')));
    });

    test('falls back to whichever language exists', () {
      const englishOnly = '### Changelog\n\n* only english';
      expect(
        localizedReleaseNotes(englishOnly, NotesLanguage.chinese),
        '* only english',
      );
    });

    test('shows the whole body when it has no language split', () {
      const plain = 'Fixed a crash on startup.';
      expect(localizedReleaseNotes(plain, NotesLanguage.english), plain);
      expect(localizedReleaseNotes(plain, NotesLanguage.chinese), plain);
    });

    test('returns empty only for an empty body', () {
      expect(localizedReleaseNotes('', NotesLanguage.english), isEmpty);
      expect(localizedReleaseNotes('   \n  ', NotesLanguage.english), isEmpty);
    });

    test('tolerates heading level and spacing differences', () {
      const body = '## Notes\n\n## Changelog\n\n* body\n\n## 更新日志\n\n* 正文';
      expect(
        localizedReleaseNotes(body, NotesLanguage.english).trim(),
        '* body',
      );
      expect(
        localizedReleaseNotes(body, NotesLanguage.chinese).trim(),
        '* 正文',
      );
    });
  });

  group('notesLanguageForLocale', () {
    test('maps zh to the Chinese block and everything else to English', () {
      expect(notesLanguageForLocale('zh'), NotesLanguage.chinese);
      expect(notesLanguageForLocale('zh-Hans'), NotesLanguage.chinese);
      expect(notesLanguageForLocale('ZH'), NotesLanguage.chinese);
      expect(notesLanguageForLocale('en'), NotesLanguage.english);
      expect(notesLanguageForLocale('de'), NotesLanguage.english);
    });
  });
}
