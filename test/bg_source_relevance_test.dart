import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_source_rule_kind.dart';
import 'package:iris/features/background_playback/model/source/bg_source_rule.dart';
import 'package:iris/features/background_playback/services/bg_source_relevance.dart';

BgSourceRule _rule({
  String id = 'r',
  BgSourceRuleKind kind = BgSourceRuleKind.tag,
  bool enabled = true,
  int? tagId,
  bool tagFilterEnabled = false,
  int? filterTagId,
}) =>
    BgSourceRule(
      id: id,
      kind: kind,
      enabled: enabled,
      tagId: tagId,
      tagFilterEnabled: tagFilterEnabled,
      filterTagId: filterTagId,
    );

void main() {
  const builtin = 7; // 「副音备选」
  const other = 9;

  group('isTagRelevantToBgRules', () {
    test('a tag rule matches its own tag', () {
      expect(
        isTagRelevantToBgRules(
          rules: [_rule(tagId: other)],
          tagId: other,
          reservedTagId: builtin,
        ),
        isTrue,
      );
      expect(
        isTagRelevantToBgRules(
          rules: [_rule(tagId: other)],
          tagId: builtin,
          reservedTagId: builtin,
        ),
        isFalse,
      );
    });

    test('a zero-id tag rule means the built-in reserved source', () {
      // The seeded built-in rule carries no tagId: it reads 「副音备选」.
      expect(
        isTagRelevantToBgRules(
          rules: [_rule()],
          tagId: builtin,
          reservedTagId: builtin,
        ),
        isTrue,
      );
    });

    test('a directory rule with a tag filter matches the filtered tag', () {
      final rules = [_rule(kind: BgSourceRuleKind.directory, filterTagId: other)];
      expect(
        isTagRelevantToBgRules(
          rules: [rules.first.copyWith(tagFilterEnabled: true)],
          tagId: other,
          reservedTagId: builtin,
        ),
        isTrue,
      );
      // Without the filter flag the tag is not read at all.
      expect(
        isTagRelevantToBgRules(
          rules: rules,
          tagId: other,
          reservedTagId: builtin,
        ),
        isFalse,
      );
    });

    test('a file rule is unaffected by any tag', () {
      expect(
        isTagRelevantToBgRules(
          rules: [_rule(kind: BgSourceRuleKind.file)],
          tagId: builtin,
          reservedTagId: builtin,
        ),
        isFalse,
      );
    });

    test('a disabled rule is not a reader', () {
      expect(
        isTagRelevantToBgRules(
          rules: [_rule(tagId: other, enabled: false)],
          tagId: other,
          reservedTagId: builtin,
        ),
        isFalse,
      );
    });

    test('with no enabled rule the built-in pure-tag source reads the '
        'reserved tag', () {
      expect(
        isTagRelevantToBgRules(
          rules: [_rule(tagId: other, enabled: false)],
          tagId: builtin,
          reservedTagId: builtin,
        ),
        isTrue,
      );
      expect(
        isTagRelevantToBgRules(
          rules: const [],
          tagId: other,
          reservedTagId: builtin,
        ),
        isFalse,
      );
    });

    test('an unknown reserved tag cannot match', () {
      // Before the tag_play bootstrap ran there is no reserved tag; matching it
      // would be a coincidence.
      expect(
        isTagRelevantToBgRules(
          rules: [_rule()],
          tagId: builtin,
        ),
        isFalse,
      );
    });
  });
}
