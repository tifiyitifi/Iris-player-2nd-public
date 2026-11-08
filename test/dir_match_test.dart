import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/dir_match.dart';

void main() {
  const suffixS1 = [DirPatternEntry(kind: DirPatternKind.suffix, text: 'S1')];

  group('specifiedDir', () {
    test('matches only the direct parent, tolerating absolute-vs-relative', () {
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.specifiedDir,
          paths: const ['vault/003'],
          patterns: const [],
          fullPath: 'E:/vault/003/a.mp4',
          parentPath: 'E:/vault/003',
        ),
        isTrue,
      );
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.specifiedDir,
          paths: const ['vault/003'],
          patterns: const [],
          fullPath: 'E:/vault/003/sub/a.mp4',
          parentPath: 'E:/vault/003/sub',
        ),
        isFalse,
      );
    });

    test('empty paths never match', () {
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.specifiedDir,
          paths: const [],
          patterns: const [],
          fullPath: 'a/b.mp4',
          parentPath: 'a',
        ),
        isFalse,
      );
    });
  });

  group('specifiedDirRecursive', () {
    test('includes subdirectories', () {
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.specifiedDirRecursive,
          paths: const ['Anime'],
          patterns: const [],
          fullPath: 'Anime/Sub/a.mp4',
          parentPath: 'Anime/Sub',
        ),
        isTrue,
      );
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.specifiedDirRecursive,
          paths: const ['Anime'],
          patterns: const [],
          fullPath: 'Other/a.mp4',
          parentPath: 'Other',
        ),
        isFalse,
      );
    });
  });

  group('patternDir', () {
    test('suffix matches the parent base name case-insensitively', () {
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDir,
          paths: const [],
          patterns: suffixS1,
          fullPath: 'AnimeS1/a.mp4',
          parentPath: 'AnimeS1',
        ),
        isTrue,
      );
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDir,
          paths: const [],
          patterns: suffixS1,
          fullPath: 'AnimeS2/a.mp4',
          parentPath: 'AnimeS2',
        ),
        isFalse,
      );
    });

    test('activated entries are AND-ed', () {
      const patterns = [
        DirPatternEntry(kind: DirPatternKind.contains, text: 'Anime'),
        DirPatternEntry(kind: DirPatternKind.contains, text: 'S1'),
      ];
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDir,
          paths: const [],
          patterns: patterns,
          fullPath: 'AnimeS1/a.mp4',
          parentPath: 'AnimeS1',
        ),
        isTrue,
      );
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDir,
          paths: const [],
          patterns: patterns,
          fullPath: 'AnimeS2/a.mp4',
          parentPath: 'AnimeS2',
        ),
        isFalse,
      );
    });

    test('zero activated entries never match', () {
      const patterns = [
        DirPatternEntry(
            kind: DirPatternKind.contains, text: 'Anime', activated: false),
      ];
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDir,
          paths: const [],
          patterns: patterns,
          fullPath: 'AnimeS1/a.mp4',
          parentPath: 'AnimeS1',
        ),
        isFalse,
      );
    });

    test('invalid regex fails closed', () {
      const patterns = [
        DirPatternEntry(kind: DirPatternKind.regex, text: '([unclosed'),
      ];
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDir,
          paths: const [],
          patterns: patterns,
          fullPath: 'Anime/a.mp4',
          parentPath: 'Anime',
        ),
        isFalse,
      );
    });
  });

  group('patternDirRecursive', () {
    test('matches under a matched ancestor', () {
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDirRecursive,
          paths: const [],
          patterns: suffixS1,
          fullPath: 'AnimeS1/Sub/a.mp4',
          parentPath: 'AnimeS1/Sub',
        ),
        isTrue,
      );
      expect(
        dirRuleMatchesFile(
          mode: DirMatchMode.patternDirRecursive,
          paths: const [],
          patterns: suffixS1,
          fullPath: 'AnimeS2/Sub/a.mp4',
          parentPath: 'AnimeS2/Sub',
        ),
        isFalse,
      );
    });
  });

  group('decodeDirPatterns', () {    test('malformed JSON degrades to an empty list', () {
      expect(decodeDirPatterns('not json'), isEmpty);
      expect(decodeDirPatterns('{"a":1}'), isEmpty);
    });

    test('round-trips entries', () {
      const entry = DirPatternEntry(
        kind: DirPatternKind.prefix,
        text: 'S',
        activated: false,
        pinned: true,
      );
      final decoded = decodeDirPatterns('[${_json(entry)}]');
      expect(decoded.single, entry);
    });
  });

  group('compileDirRule equivalence', () {
    bool viaCompiled({
      required DirMatchMode mode,
      List<String> paths = const [],
      List<DirPatternEntry> patterns = const [],
      required String fullPath,
      required String parentPath,
    }) {
      final compiled =
          compileDirRule(mode: mode, paths: paths, patterns: patterns);
      // Compile once, match many: reuse across files like the hot loops do.
      final again =
          compileDirRule(mode: mode, paths: paths, patterns: patterns);
      final a = compiledDirRuleMatchesFile(compiled,
          fullPath: fullPath, parentPath: parentPath);
      final b = compiledDirRuleMatchesFile(again,
          fullPath: fullPath, parentPath: parentPath);
      expect(a, b);
      return a;
    }

    bool uncompiled({
      required DirMatchMode mode,
      List<String> paths = const [],
      List<DirPatternEntry> patterns = const [],
      required String fullPath,
      required String parentPath,
    }) =>
        dirRuleMatchesFile(
          mode: mode,
          paths: paths,
          patterns: patterns,
          fullPath: fullPath,
          parentPath: parentPath,
        );

    test('specifiedDir matches compiled == uncompiled', () {
      for (final parent in ['E:/vault/003', 'E:/vault/003/sub', '']) {
        expect(
          viaCompiled(
            mode: DirMatchMode.specifiedDir,
            paths: const ['vault/003'],
            fullPath: '$parent/a.mp4',
            parentPath: parent,
          ),
          uncompiled(
            mode: DirMatchMode.specifiedDir,
            paths: const ['vault/003'],
            fullPath: '$parent/a.mp4',
            parentPath: parent,
          ),
        );
      }
    });

    test('recursive + patterns agree, incl. ancestors and bad regex', () {
      const patterns = [
        DirPatternEntry(kind: DirPatternKind.suffix, text: 'S1'),
        DirPatternEntry(kind: DirPatternKind.regex, text: '([unclosed'),
      ];
      for (final mode in [
        DirMatchMode.specifiedDirRecursive,
        DirMatchMode.patternDir,
        DirMatchMode.patternDirRecursive
      ]) {
        for (final parent in ['AnimeS1', 'AnimeS1/Sub', 'AnimeS2', '']) {
          expect(
            viaCompiled(
              mode: mode,
              paths: const ['Anime'],
              patterns: patterns,
              fullPath: '$parent/a.mp4',
              parentPath: parent,
            ),
            uncompiled(
              mode: mode,
              paths: const ['Anime'],
              patterns: patterns,
              fullPath: '$parent/a.mp4',
              parentPath: parent,
            ),
          );
        }
      }
    });
  });
}

String _json(DirPatternEntry e) =>
    '{"kind":"${e.kind.name}","text":"${e.text}",'
    '"activated":${e.activated},"pinned":${e.pinned}}';
