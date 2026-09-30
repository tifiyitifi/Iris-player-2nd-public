import 'package:iris/features/background_playback/model/db/repositories/bg_source_rule_repository.dart';
import 'package:iris/features/background_playback/model/enum/bg_source_rule_kind.dart';
import 'package:iris/features/background_playback/model/source/bg_source_rule.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/models/db/db_module.dart';

/// Whether a membership change of [tagId] can change what the 副音 source
/// rules resolve.
///
/// Pure by design: it is the only place that knows a membership write is
/// RELEVANT, and it must be answerable without I/O so the rule set can be
/// tested exhaustively. Callers resolve the DB side through
/// [isTagRelevantToBg].
///
/// Relevance has three shapes, and the third is the one that is easy to miss:
/// - a `tag` rule reads its own `tagId` — or the reserved 「副音备选」 tag when
///   it left the id empty (the zero-id rule means "the built-in source");
/// - a `directory` rule narrows by `filterTagId` (tagFilterEnabled), so a
///   membership write changes which library rows survive the match;
/// - with NO enabled rule at all the pool falls back to the built-in
///   pure-tag source, so the reserved tag is relevant even though no rule
///   mentions it.
///
/// A `file` rule names one exact path, so nothing about a tag can affect it.
bool isTagRelevantToBgRules({
  required List<BgSourceRule> rules,
  required int tagId,
  int? reservedTagId,
}) {
  final enabled = [for (final r in rules) if (r.enabled) r];
  if (enabled.isEmpty) return tagId == reservedTagId;
  for (final rule in enabled) {
    // Only a `tag` rule reads a tag through `tagId`; a `file` rule's null
    // tagId is simply "not a tag source" and must not fall through to the
    // reserved tag.
    if (rule.kind == BgSourceRuleKind.tag) {
      final ruleTagId = rule.tagId ?? reservedTagId;
      if (ruleTagId != null && ruleTagId == tagId) return true;
    }
    // A directory rule narrows the library by `filterTagId`, so its member
    // write changes which rows survive the match.
    if (rule.tagFilterEnabled && rule.filterTagId == tagId) return true;
  }
  return false;
}

/// DB-backed [isTagRelevantToBgRules].
///
/// [reservedTagId] is resolved lazily: the zero-id rule and the zero-active
/// fallback are the only cases that need it, so a rule set that names its tags
/// outright never pays for the reserved-tag lookup.
Future<bool> isTagRelevantToBg(
  int tagId, {
  BgSourceRuleRepository? ruleRepo,
  TagPlayRepository? tagRepo,
  Future<int?> Function()? reservedTagIdOf,
}) async {
  final rules = await (ruleRepo ?? DbModule.bgSourceRuleRepo).loadRules();
  final needsReserved = [for (final r in rules) if (r.enabled) r].isEmpty ||
      rules.any(
        (r) => r.enabled && r.kind == BgSourceRuleKind.tag && r.tagId == null,
      );
  final reserved = needsReserved
      ? await (reservedTagIdOf ?? _reservedTagId)(tagRepo)
      : null;
  return isTagRelevantToBgRules(
    rules: rules,
    tagId: tagId,
    reservedTagId: reserved,
  );
}

/// Id of the reserved 「副音备选」 tag, or null when it has not been created
/// yet (before the tag_play bootstrap ran).
Future<int?> _reservedTagId(TagPlayRepository? repo) async {
  final tags = await (repo ?? DbModule.tagPlayRepo).tags();
  for (final tag in tags) {
    if (tag.systemKind == TagSystemKind.backgroundVoiceCandidate) {
      return tag.id;
    }
  }
  return null;
}
