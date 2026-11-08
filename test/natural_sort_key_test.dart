import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/utils/natural_sort_key.dart';

/// The natural order is defined by [naturalSortKey]'s BYTE order — SQL
/// (`ORDER BY natural_name`) and Dart must agree by construction, so these
/// tests pin the encoding, not a separate comparator implementation.
void main() {
  group('naturalSortKey ordering', () {
    void expectOrder(List<String> ascending) {
      for (var i = 0; i + 1 < ascending.length; i++) {
        expect(
          naturalCompare(ascending[i], ascending[i + 1]),
          lessThan(0),
          reason: '"${ascending[i]}" must sort before "${ascending[i + 1]}"',
        );
      }
    }

    test('the reported bug: 1, 2, 10 (not 1, 10, 20)', () {
      expectOrder(['1.mkv', '2.mkv', '10.mkv', '20.mkv', '100.mkv']);
    });

    test('VLC test vectors (src/test/sort.c)', () {
      // "" < "a"; "foo1" < "foo2" < "foo10"
      expect(naturalCompare('', 'a'), lessThan(0));
      expect(naturalCompare('a', 'b'), lessThan(0));
      expect(naturalCompare('foo1.ogg', 'foo2.ogg'), lessThan(0));
      expect(naturalCompare('foo2.ogg', 'foo10.ogg'), lessThan(0));
      expect(naturalCompare('foo1.ogg', 'foo10.ogg'), lessThan(0));
      // VLC orders foo01 before foo1 via strcoll; IRIS keeps vmNaturalCompare's
      // "fewer leading zeros first" rule (see the file header).
      expect(naturalCompare('foo1.ogg', 'foo01.ogg'), lessThan(0));
      expect(naturalCompare('a', 'a'), 0);
      expect(naturalCompare('123', '123'), 0);
    });

    test('episode style names', () {
      expectOrder([
        'Show S01E2.mkv',
        'Show S01E10.mkv',
        'Show S01E100.mkv',
        'Show S02E1.mkv',
      ]);
      expect(naturalCompare('ep2.mp4', 'ep10.mp4'), lessThan(0));
      expect(naturalCompare('EP2.MKV', 'ep10.mkv'), lessThan(0));
    });

    test('digits sort before letters, and prefix is shorter-first', () {
      expect(naturalCompare('2', 'a'), lessThan(0));
      expect(naturalCompare('a', 'ab'), lessThan(0));
      expect(naturalCompare('a1', 'ab'), lessThan(0));
      expect(naturalCompare('a', 'a1'), lessThan(0));
    });

    test('leading zeros stay deterministic', () {
      expectOrder(['7.mkv', '07.mkv', '007.mkv']);
      // equal value, equal padding → identical key
      expect(naturalCompare('ep02', 'EP02'), 0);
    });

    test('arbitrary-length digit runs (no fixed-width cap)', () {
      expect(
        naturalCompare('12345678901234.dat', '12345678901235.dat'),
        lessThan(0),
      );
      expect(
        naturalCompare('99999999999999999999.dat', '100000000000000000000.dat'),
        lessThan(0),
      );
    });

    test('case-only differences tie (the path tail decides)', () {
      expect(naturalCompare('A.mkv', 'a.mkv'), 0);
      expect(naturalCompare('进击的巨人.MKV', '进击的巨人.mkv'), 0);
    });

    test('CJK names keep their digit awareness', () {
      expectOrder([
        '进击的巨人 第2集.mkv',
        '进击的巨人 第10集.mkv',
        '进击的巨人 第100集.mkv',
      ]);
    });

    test('separator characters do not merge runs', () {
      // A digit sorts before any separator, so "a1" precedes "a 1" — the run
      // markers must not swallow the separator into the digit run.
      expectOrder(['a1.mkv', 'a 1.mkv', 'a-1.mkv', 'b1.mkv']);
    });

    test('empty and whitespace names', () {
      expect(naturalSortKey(''), '');
      expect(naturalCompare('', '0'), lessThan(0));
      expect(naturalCompare(' ', '0'), greaterThan(0));
    });
  });

  group('naturalSortKey properties', () {
    const alphabet = 'ab Z09._-进巨éΩ';

    test('total order: antisymmetric and transitive on random names', () {
      final rnd = Random(20251105);
      final names = <String>{
        for (var i = 0; i < 400; i++)
          () {
            final len = rnd.nextInt(10);
            return [
              for (var j = 0; j < len; j++)
                alphabet[rnd.nextInt(alphabet.length)],
            ].join();
          }(),
      }.toList();

      for (var i = 0; i < names.length; i++) {
        for (var j = 0; j < names.length; j++) {
          final ab = naturalCompare(names[i], names[j]);
          final ba = naturalCompare(names[j], names[i]);
          expect(ab.sign, -ba.sign,
              reason: '"${names[i]}" vs "${names[j]}" not antisymmetric');
          expect(ab.sign,
              naturalSortKey(names[i]).compareTo(naturalSortKey(names[j])).sign);
        }
      }

      // transitivity via a sorted copy
      final sorted = List<String>.of(names)..sort(naturalCompare);
      for (var i = 0; i + 1 < sorted.length; i++) {
        expect(naturalCompare(sorted[i], sorted[i + 1]), lessThanOrEqualTo(0));
      }
      // sorting is idempotent under the same key function
      final resorted = List<String>.of(sorted)..sort(naturalCompare);
      expect(resorted, sorted);
    });

    test('case folding never changes the order of the lower-cased names', () {
      final rnd = Random(7);
      for (var i = 0; i < 200; i++) {
        String gen() {
          const chars = 'AbC019.x';
          final len = 1 + rnd.nextInt(8);
          return [for (var j = 0; j < len; j++) chars[rnd.nextInt(chars.length)]]
              .join();
        }

        final a = gen();
        final b = gen();
        expect(
          naturalCompare(a, b).sign,
          naturalCompare(a.toLowerCase(), b.toLowerCase()).sign,
          reason: 'case folding changed the order of "$a" / "$b"',
        );
      }
    });
  });
}
