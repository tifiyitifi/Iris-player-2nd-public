import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/json5_light.dart';

void main() {
  group('parseJson5', () {
    test('reads the LosslessCut project shape', () {
      final value = parseJson5('''
{
  // a comment
  version: 2,
  mediaFileName: '与室友的真心話.mp4',
  cutSegments: [
    { start: 8.033, end: 44.978744, name: '', selected: true, },
    /* block comment */
    { start: 60.359165, end: 83.43333333333334, name: '片段 2' },
  ],
}
''');
      expect(value, isA<Map<String, Object?>>());
      final map = value! as Map<String, Object?>;
      expect(map['version'], 2);
      expect(map['mediaFileName'], '与室友的真心話.mp4');
      final segments = map['cutSegments']! as List<Object?>;
      expect(segments, hasLength(2));
      final first = segments.first! as Map<String, Object?>;
      expect(first['start'], 8.033);
      expect(first['selected'], true);
      expect((segments.last! as Map<String, Object?>)['name'], '片段 2');
    });

    test('accepts double quotes, escapes, plus signs and hex', () {
      final map = parseJson5(
          r'{"a": "line\nbreak", "b": +3, "c": 0x10, "d": [1, 2, 3,], "e": null}')!
          as Map<String, Object?>;
      expect(map['a'], 'line\nbreak');
      expect(map['b'], 3);
      expect(map['c'], 16);
      expect(map['d'], <Object?>[1, 2, 3]);
      expect(map['e'], isNull);
    });

    test('strips a BOM', () {
      final value = parseJson5('\uFEFF{version: 2}');
      expect((value! as Map<String, Object?>)['version'], 2);
    });

    test('reports the offset of a syntax error', () {
      expect(
        () => parseJson5('{ version: 2, cutSegments: [ }'),
        throwsA(isA<Json5FormatException>()),
      );
    });

    test('rejects non-finite identifiers', () {
      expect(() => parseJson5('{a: Infinity}'),
          throwsA(isA<Json5FormatException>()));
    });

    test('an absurd nesting depth is a format error, not a crashed stack', () {
      // The reader recursed once per opener with no limit: a project-sized file
      // of `[` raised StackOverflowError, an Error the `on FormatException`
      // handling upstream cannot catch — one broken project then emptied the
      // whole directory's list.
      final String deep = '${'[' * 2000}${']' * 2000}';
      expect(
        () => parseJson5(deep),
        throwsA(isA<Json5FormatException>()
            .having((e) => e.message, 'message', contains('nested'))),
      );
      // Real projects are a handful of levels deep and keep working.
      expect(parseJson5('[[[[1]]]]'), <Object?>[
        <Object?>[
          <Object?>[
            <Object?>[1],
          ],
        ],
      ]);
    });
  });
}
