import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/fake_cut/core/fake_cut_preflight.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_segment.dart';
import 'package:iris/features/fake_cut/view/fake_cut_texts.dart';
import 'package:iris/l10n/app_localizations_en.dart';
import 'package:iris/l10n/app_localizations_zh.dart';

FakeCutPlan planWith({
  int markers = 0,
  int deselected = 0,
  bool fallback = false,
  int invalid = 0,
  int clamped = 0,
  int tooShort = 0,
  String? mediaFileName,
  String? sourceFileName,
}) =>
    FakeCutPlan(
      planPath: '/v/proj.llc',
      displayName: 'proj',
      version: 2,
      segments: <FakeCutSegment>[
        const FakeCutSegment(index: 0, startMs: 0, endMs: 1000),
      ],
      markerCount: markers,
      deselectedCount: deselected,
      usedSelectedFallback: fallback,
      invalidCount: invalid,
      clampedCount: clamped,
      tooShortCount: tooShort,
      mediaFileName: mediaFileName,
      sourceFileName: sourceFileName,
    );

void main() {
  final en = AppLocalizationsEn();
  final zh = AppLocalizationsZh();

  group('fakeCutBlockedText', () {
    test('every blocked reason has a distinct localized line', () {
      final Set<String> lines = <String>{};
      for (final FakeCutBlockReason reason in FakeCutBlockReason.values) {
        final String line = fakeCutBlockedText(en, reason);
        if (reason == FakeCutBlockReason.none) {
          expect(line, isEmpty);
          continue;
        }
        expect(line, isNotEmpty);
        lines.add(line);
      }
      expect(lines, hasLength(FakeCutBlockReason.values.length - 1));
    });

    test('Chinese lines differ from English (translations exist)', () {
      expect(fakeCutBlockedText(zh, FakeCutBlockReason.backend),
          isNot(fakeCutBlockedText(en, FakeCutBlockReason.backend)));
      expect(fakeCutBlockedText(zh, FakeCutBlockReason.unsupportedStorage),
          isNot(fakeCutBlockedText(en, FakeCutBlockReason.unsupportedStorage)));
      expect(fakeCutBlockedText(zh, FakeCutBlockReason.notVideo),
          isNot(fakeCutBlockedText(en, FakeCutBlockReason.notVideo)));
    });
  });

  group('fakeCutNoticeLines', () {
    test('renders one localized line per notice in plan order', () {
      final plan = planWith(
        markers: 2,
        deselected: 1,
        fallback: true,
        invalid: 3,
        clamped: 4,
        tooShort: 5,
        mediaFileName: 'other.mp4',
        sourceFileName: 'movie.mp4',
      );
      final lines = fakeCutNoticeLines(en, plan);
      expect(lines, hasLength(7));
      expect(lines[0].text, contains('2'));
      expect(lines[0].isWarning, isFalse);
      expect(lines[1].text, contains('1'));
      expect(lines[1].isWarning, isFalse);
      expect(lines[2].text, isNotEmpty);
      expect(lines[2].isWarning, isFalse);
      expect(lines[3].text, contains('3'));
      expect(lines[3].isWarning, isTrue);
      expect(lines[4].text, contains('4'));
      expect(lines[4].isWarning, isTrue);
      expect(lines[5].text, contains('5'));
      expect(lines[5].isWarning, isTrue);
      expect(lines[6].text, contains('other.mp4'));
      expect(lines[6].isWarning, isTrue);
    });

    test('a clean plan has no notices', () {
      expect(fakeCutNoticeLines(en, planWith()), isEmpty);
    });

    test('the mismatch notice is localized in both locales', () {
      final plan =
          planWith(mediaFileName: 'x.mp4', sourceFileName: 'y.mp4');
      expect(fakeCutNoticeLines(en, plan).single.text, contains('x.mp4'));
      expect(fakeCutNoticeLines(zh, plan).single.text, contains('x.mp4'));
      expect(fakeCutNoticeLines(en, plan).single.text,
          isNot(fakeCutNoticeLines(zh, plan).single.text));
    });
  });
}
