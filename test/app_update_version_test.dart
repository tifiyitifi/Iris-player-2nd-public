import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_update/model/app_version.dart';

void main() {
  group('parseVersion', () {
    test('reads a plain dotted version', () {
      expect(parseVersion('2.0.4'), [2, 0, 4]);
    });

    test('tolerates a leading v, as GitHub tags carry', () {
      expect(parseVersion('v2.0.4'), [2, 0, 4]);
      expect(parseVersion('V2.0.4'), [2, 0, 4]);
    });

    test('drops build metadata: the tag is the contract', () {
      expect(parseVersion('2.0.4+10'), [2, 0, 4]);
      expect(parseVersion('v2.0.4+10'), [2, 0, 4]);
    });

    test('rejects a leftover local-build tag instead of coercing it', () {
      // `2.0.0.local` is neither draft nor prerelease on the public repository,
      // so GitHub can report it as the latest release. Parsing it as 0 would
      // make every install look up to date.
      expect(parseVersion('2.0.0.local'), isNull);
      expect(parseVersion('nightly'), isNull);
      expect(parseVersion('2.0.x'), isNull);
    });

    test('rejects empty and malformed input', () {
      expect(parseVersion(''), isNull);
      expect(parseVersion('   '), isNull);
      expect(parseVersion('2..0'), isNull);
      expect(parseVersion('2.-1'), isNull);
    });
  });

  group('compareVersions', () {
    test('orders by the first differing segment', () {
      expect(compareVersions('2.0.4', '2.0.5')!, lessThan(0));
      expect(compareVersions('2.1.0', '2.0.9')!, greaterThan(0));
      expect(compareVersions('3.0.0', '2.99.99')!, greaterThan(0));
    });

    test('is zero for equal versions regardless of length or build', () {
      expect(compareVersions('2.0.4', '2.0.4'), 0);
      expect(compareVersions('v2.0.4', '2.0.4'), 0);
      expect(compareVersions('2.0.4+10', '2.0.4'), 0);
      expect(compareVersions('2.0', '2.0.0'), 0);
    });

    test('reports "cannot tell" when either side is unparseable', () {
      // Callers must not read null as "up to date".
      expect(compareVersions('2.0.0.local', '2.0.4'), isNull);
      expect(compareVersions('2.0.4', '2.0.0.local'), isNull);
    });
  });
}
