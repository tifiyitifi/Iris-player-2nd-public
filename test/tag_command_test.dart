import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/tag_play/model/domain/tag_command.dart';

void main() {
  group('parseTagCommand — valid', () {
    test('add with several dot-separated ordinals', () {
      final cmd = (parseTagCommand('+1.2.5') as TagCommandParsed).command;
      expect(cmd.kind, TagCommandKind.add);
      expect(cmd.ordinals, [1, 2, 5]);
    });

    test('remove with several ordinals', () {
      final cmd = (parseTagCommand('-2.4') as TagCommandParsed).command;
      expect(cmd.kind, TagCommandKind.remove);
      expect(cmd.ordinals, [2, 4]);
    });

    test('play with a single ordinal', () {
      final cmd = (parseTagCommand('*3') as TagCommandParsed).command;
      expect(cmd.kind, TagCommandKind.play);
      expect(cmd.ordinals, [3]);
    });

    test('play 0 is the no-tag target', () {
      final cmd = (parseTagCommand('*0') as TagCommandParsed).command;
      expect(cmd.kind, TagCommandKind.play);
      expect(cmd.ordinals, [kTagCommandNoTagOrdinal]);
    });

    test('operator prefill characters round-trip', () {
      expect(tagCommandOperator(TagCommandKind.add), '+');
      expect(tagCommandOperator(TagCommandKind.remove), '-');
      expect(tagCommandOperator(TagCommandKind.play), '*');
    });
  });

  group('parseTagCommand — lenient normalization', () {
    test('illegal characters are ignored, never rejected', () {
      final cmd = (parseTagCommand('  + 1 . 2  ') as TagCommandParsed).command;
      expect(cmd.ordinals, [1, 2]);
    });

    test('leading zeros fold away', () {
      final cmd = (parseTagCommand('+02.01.3') as TagCommandParsed).command;
      expect(cmd.ordinals, [2, 1, 3]);
    });

    test('duplicates collapse to first-seen order', () {
      final cmd = (parseTagCommand('+2.1.2') as TagCommandParsed).command;
      expect(cmd.ordinals, [2, 1]);
    });

    test('a stray operator sign splits, not fails', () {
      final cmd = (parseTagCommand('+1-2') as TagCommandParsed).command;
      expect(cmd.ordinals, [1, 2]);
    });

    test('a mixed zero is ignored, leaving only the real ordinals', () {
      final cmd = (parseTagCommand('+0.3') as TagCommandParsed).command;
      expect(cmd.ordinals, [3]);
      expect(cmd.allTags, isFalse);
      final reversed = (parseTagCommand('+3.0') as TagCommandParsed).command;
      expect(reversed.ordinals, [3]);
      expect(reversed.allTags, isFalse);
      final blank = (parseTagCommand('+1..2') as TagCommandParsed).command;
      expect(blank.ordinals, [1, 2]);
    });
  });

  group('parseTagCommand — invalid', () {
    TagCommandError errorOf(String raw) =>
        (parseTagCommand(raw) as TagCommandInvalid).error;

    test('nothing usable at all', () {
      expect(errorOf(''), TagCommandError.empty);
      expect(errorOf('   '), TagCommandError.empty);
      expect(errorOf('abc'), TagCommandError.empty);
    });

    test('missing operator', () {
      expect(errorOf('3'), TagCommandError.missingOperator);
      expect(errorOf('1.2'), TagCommandError.missingOperator);
    });

    test('operator without a usable ordinal', () {
      expect(errorOf('+'), TagCommandError.noOrdinals);
      expect(errorOf('-  '), TagCommandError.noOrdinals);
      expect(errorOf('*.'), TagCommandError.noOrdinals);
    });

    test('a lone 0 is valid: all tags for +/-, no-tag for *', () {
      for (final raw in ['+0', '-0', '+0.0', '-0.0']) {
        final cmd = (parseTagCommand(raw) as TagCommandParsed).command;
        expect(cmd.allTags, isTrue, reason: raw);
        expect(cmd.ordinals, isEmpty, reason: raw);
      }
      expect((parseTagCommand('+0') as TagCommandParsed).command.kind,
          TagCommandKind.add);
      expect((parseTagCommand('-0') as TagCommandParsed).command.kind,
          TagCommandKind.remove);

      final play = (parseTagCommand('*0') as TagCommandParsed).command;
      expect(play.ordinals, [kTagCommandNoTagOrdinal]);
      expect(play.allTags, isFalse);
    });

    test('play accepts exactly one ordinal', () {
      expect(errorOf('*1.2'), TagCommandError.playNeedsSingle);
      expect(errorOf('*0.1'), TagCommandError.playNeedsSingle);
      // Duplicate zeros collapse, so this is still the single no-tag target.
      expect(parseTagCommand('*0.0'), isA<TagCommandParsed>());
    });
  });

  group('tagOperatorResetOnEdit — mid-line operator restarts the command', () {
    test('an operator typed after text collapses the line to that operator',
        () {
      expect(tagOperatorResetOnEdit('+1.2', '+1.2*'), '*');
      expect(tagOperatorResetOnEdit('+1.2', '+1.2-'), '-');
      expect(tagOperatorResetOnEdit('*3', '*3+'), '+');
    });

    test('unrelated edits pass through untouched', () {
      // No change.
      expect(tagOperatorResetOnEdit('+1.2', '+1.2'), isNull);
      // Append a digit.
      expect(tagOperatorResetOnEdit('+1', '+1.2'), isNull);
      // Delete.
      expect(tagOperatorResetOnEdit('+1.2', '+1.'), isNull);
    });

    test('prefixing the missing operator is NOT a reset', () {
      // Caret at the head, typing the operator the line was missing.
      expect(tagOperatorResetOnEdit('1.2', '+1.2'), isNull);
      expect(tagOperatorResetOnEdit('', '+'), isNull);
    });

    test('pasting a whole command is NOT a reset', () {
      expect(tagOperatorResetOnEdit('', '+1.2.5'), isNull);
      expect(tagOperatorResetOnEdit('+1.2', '+1.2+3.4'), isNull);
    });
  });
}
