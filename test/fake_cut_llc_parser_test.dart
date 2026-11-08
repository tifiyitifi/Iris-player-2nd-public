import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/services/llc_parser.dart';

void main() {
  group('LlcParser.parse', () {
    test('v2 numeric seconds, absent selected means selected', () {
      final project = LlcParser.parse('''
{
  version: 2,
  mediaFileName: 'a.mp4',
  cutSegments: [
    { start: 8.033, end: 44.978744, name: '', selected: true },
    { start: 60.359165, end: 83.43333333333334, name: 'x' },
  ],
}
''');
      expect(project.version, 2);
      expect(project.mediaFileName, 'a.mp4');
      expect(project.segments, hasLength(2));
      expect(project.segments.first.startMs, 8033);
      expect(project.segments.first.endMs, 44979);
      expect(project.segments.last.selected, isTrue);
    });

    test('a segment without end is a marker', () {
      final project = LlcParser.parse('''
{version: 2, cutSegments: [{start: 520.596492, name: '', selected: true}]}
''');
      expect(project.segments.single.isMarker, isTrue);
      expect(project.segments.single.endMs, isNull);
    });

    test('v3 timecode strings', () {
      final project = LlcParser.parse('''
{
  version: 3,
  mediaFileName: 'b.mp4',
  cutSegments: [
    { start: '00:00:08.033000000', end: '00:00:44.978744000', name: '', selected: true },
    { start: '00:01:00.359165000', end: '00:01:23.433333333', name: 'y' },
  ],
}
''');
      expect(project.version, 3);
      expect(project.segments.first.startMs, 8033);
      expect(project.segments.first.endMs, 44979);
      expect(project.segments.last.startMs, 60359);
      expect(project.segments.last.endMs, 83433);
    });

    test('v1 missing start defaults to 0', () {
      final project = LlcParser.parse('''
{version: 1, cutSegments: [{end: 12.5, name: ''}]}
''');
      expect(project.segments.single.startMs, 0);
      expect(project.segments.single.endMs, 12500);
    });

    test('selected false is kept as false', () {
      final project = LlcParser.parse('''
{version: 2, cutSegments: [{start: 1, end: 2, name: '', selected: false}]}
''');
      expect(project.segments.single.selected, isFalse);
    });

    test('unsupported version', () {
      expect(
        () => LlcParser.parse('{version: 9, cutSegments: []}'),
        throwsA(isA<LlcParseException>().having(
            (e) => e.failure, 'failure', LlcParseFailure.unsupportedVersion)),
      );
    });

    test('a fractional version is rejected, an integral one is accepted', () {
      // `toInt()` silently turned a future 2.9 into v2 and parsed it with v2
      // rules. A whole-number double (`3.0`) is still a valid encoding.
      expect(
        () => LlcParser.parse('{version: 2.9, cutSegments: []}'),
        throwsA(isA<LlcParseException>().having(
            (e) => e.failure, 'failure', LlcParseFailure.unsupportedVersion)),
      );
      expect(LlcParser.parse('{version: 3.0, cutSegments: []}').version, 3);
    });

    test('invalid time value', () {
      expect(
        () => LlcParser.parse(
            "{version: 3, cutSegments: [{start: 'nope', end: '00:00:01.0', name: ''}]}"),
        throwsA(isA<LlcParseException>()
            .having((e) => e.failure, 'failure', LlcParseFailure.invalidTime)),
      );
    });

    test('an out-of-range hour field is a parse failure, not a crash', () {
      // `int.parse` threw a FormatException for a 20-digit hour field. The
      // discovery layer only catches LlcParseException, so one hand-edited
      // project aborted the whole folder's list and — through
      // `ensureActivePlan` — the open itself.
      final String huge = '9' * 20;
      expect(
        () => LlcParser.parse("{version: 3, cutSegments: "
            "[{start: '$huge:00:00', end: '00:00:01', name: ''}]}"),
        throwsA(isA<LlcParseException>()
            .having((e) => e.failure, 'failure', LlcParseFailure.invalidTime)),
      );
    });

    test('a non-JSON5 file is invalidJson', () {
      expect(
        () => LlcParser.parse('not a project'),
        throwsA(isA<LlcParseException>().having(
            (e) => e.failure, 'failure', LlcParseFailure.invalidJson)),
      );
    });
  });

  group('LlcParser.parseTimeValueMs', () {
    test('numbers are seconds', () {
      expect(LlcParser.parseTimeValueMs(1.5), 1500);
      expect(LlcParser.parseTimeValueMs(0), 0);
    });

    test('lenient timecodes', () {
      expect(LlcParser.parseTimeValueMs('1:02:03.5'), 3723500);
      expect(LlcParser.parseTimeValueMs('02:03.25'), 123250);
      expect(LlcParser.parseTimeValueMs('12.5'), 12500);
    });

    test('invalid values', () {
      expect(LlcParser.parseTimeValueMs('01:99:00.0'), isNull);
      expect(LlcParser.parseTimeValueMs('abc'), isNull);
      expect(LlcParser.parseTimeValueMs(true), isNull);
    });

    test('an astronomically large value is "invalid", never an Error', () {
      // `double.parse` accepts an arbitrarily long digit run and answers
      // Infinity; `(seconds * 1000).round()` then throws UnsupportedError — an
      // Error, so `on LlcParseException` could not stop it.
      expect(LlcParser.parseTimeValueMs('9' * 400), isNull);
      expect(LlcParser.parseTimeValueMs('0.${'9' * 400}'), isNotNull);
    });

    test('nanosecond precision rounds to the nearest millisecond', () {
      expect(LlcParser.parseTimeValueMs('00:00:00.000600000'), 1);
    });
  });
}
