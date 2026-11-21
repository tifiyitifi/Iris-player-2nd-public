import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:iris/features/virtual_media/model/db/dao/virtual_media_progress_dao.dart';
import 'package:iris/features/virtual_media/model/db/dao/virtual_media_rules_dao.dart';
import 'package:iris/features/virtual_media/model/db/dao/virtual_media_states_dao.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

/// Rule CRUD + anchor persistence for the Virtual Merge feature.
///
/// Row ↔ domain mapping is centralized here so callers never see Drift
/// companions or raw JSON columns. JSON columns decode defensively:
/// malformed payloads degrade to the column default, never throw.
class VirtualMediaRepository {
  final VirtualMediaRulesDao rulesDao;
  final VirtualMediaStatesDao statesDao;
  final VirtualMediaProgressDao progressDao;

  VirtualMediaRepository(
      {required this.rulesDao,
      required this.statesDao,
      required this.progressDao});

  // ── Rules ──

  Stream<List<VirtualMediaRule>> watchRules() =>
      rulesDao.watchAll().map((rows) => rows.map(rowToRule).toList());

  Future<List<VirtualMediaRule>> loadRules() async =>
      (await rulesDao.getAll()).map(rowToRule).toList();

  Future<VirtualMediaRule?> ruleById(String id) async {
    final row = await rulesDao.getById(id);
    return row == null ? null : rowToRule(row);
  }

  Future<void> saveRule(VirtualMediaRule rule) =>
      rulesDao.upsert(ruleToCompanion(rule));

  Future<void> setRuleEnabled(String id, bool enabled) =>
      rulesDao.setEnabled(id, enabled);

  /// Flips the use/exclude polarity of a rule.
  ///
  /// The polarity changes which scope semantics the rule's chunks carry, so both
  /// the per-scenario `vm_progress` rows and the resume anchors for this rule
  /// are dropped in the SAME transaction: a position recorded while the folder
  /// merged must never resurrect after it stopped merging (and vice versa).
  Future<void> setRuleUseMode(String id, VmRuleUseMode useMode) async {
    await rulesDao.db.transaction(() async {
      await rulesDao.setUseMode(id, useMode);
      await progressDao.deleteForRule(id);
      await statesDao.deleteByRule(id);
    });
  }

  Future<void> setRulePinned(String id, bool pinned) =>
      rulesDao.setPinned(id, pinned);

  Future<void> deleteRule(String id) => rulesDao.deleteById(id);

  /// Deletes a rule plus its stray-prone rows: per-scenario vm_progress for
  /// the rule and resume anchors of its scopes. Atomic (one transaction):
  /// a crash mid-way can no longer leave stray rows, and a failure throws so
  /// callers surface an explanatory dialog instead of a half-delete.
  Future<void> deleteRuleCascade(String id) async {
    await rulesDao.db.transaction(() async {
      await rulesDao.deleteById(id);
      await progressDao.deleteForRule(id);
      await statesDao.deleteByRule(id);
    });
  }

  // ── Resume anchors ──

  Future<({String segmentKey, int localPositionMs})?> loadAnchor(
      String scopeKey) async {
    final row = await statesDao.get(scopeKey);
    if (row == null || row.segmentKey.isEmpty) return null;
    return (
      segmentKey: row.segmentKey,
      localPositionMs: row.segmentLocalPositionMs,
    );
  }

  Future<void> saveAnchor({
    required String scopeKey,
    required String segmentKey,
    required int localPositionMs,
  }) {
    return statesDao.save(
      scopeKey: scopeKey,
      segmentKey: segmentKey,
      segmentLocalPositionMs: localPositionMs,
    );
  }

  /// Drops every resume anchor (v18 migration: the v1 scopeKey format is
  /// incompatible with v2 group keys, so old anchors can never match).
  Future<void> clearAnchors() => statesDao.clearAll();

  /// Every anchor keyed by its real scopeKey (settings-transfer export).
  Future<List<({String scopeKey, String segmentKey, int localPositionMs})>>
      loadAnchors() async {
    final rows = await statesDao.getAll();
    return [
      for (final r in rows)
        (
          scopeKey: r.scopeKey,
          segmentKey: r.segmentKey,
          localPositionMs: r.segmentLocalPositionMs,
        ),
    ];
  }

  // ── Per-scenario/tag progress (v21) ──

  Future<void> saveVmProgress({
    required String scenarioId,
    required String tagId,
    required String ruleId,
    required String scopeKey,
    required String segmentKey,
    required int localPositionMs,
  }) =>
      progressDao.save(
        scenarioId: scenarioId,
        tagId: tagId,
        ruleId: ruleId,
        scopeKey: scopeKey,
        segmentKey: segmentKey,
        localPositionMs: localPositionMs,
      );

  Future<void> clearVmProgressForScope(
          String scenarioId, String tagId, String scopeKey) =>
      progressDao.deleteForScope(scenarioId, tagId, scopeKey);

  /// Broad scope-wide delete: wipes EVERY scenario's/tag's row for [scopeKey].
  /// Session stop paths must NOT use this — use [clearVmProgressForScope]
  /// with the current session's (scenarioId, tagId) instead.
  Future<void> clearVmProgressForScopeKey(String scopeKey) =>
      progressDao.deleteForScopeKey(scopeKey);

  Future<void> clearVmProgressForRule(String ruleId) =>
      progressDao.deleteForRule(ruleId);

  Future<void> clearAllVmProgress() => progressDao.clearAll();

  // ── Mapping ──

  static VirtualMediaRule rowToRule(VmRulesTableData row) {
    // Clamp dirty values into the shared hard-ceiling range so a hand-edited
    // DB row can never produce an unbounded chunk downstream.
    final dur = row.maxDurationMinutes.clamp(1, kVmHardMaxDurationMinutes);
    final cnt = row.maxItemCount.clamp(1, kVmHardMaxItemCount);
    final tags = _decodeTitleTags(row.titleTags);
    return VirtualMediaRule(
      id: row.id,
      name: row.name,
      description: row.description,
      matchMode: row.matchMode,
      paths: _decodeStringList(row.paths),
      patterns: _decodePatterns(row.patterns),
      sortField: row.sortField,
      sortDir: row.sortDir,
      boundary: row.boundary,
      maxDurationMinutes: dur,
      maxItemCount: cnt,
      useDurationCap: row.useDurationCap,
      useCountCap: row.useCountCap,
      useExcludeOverlong: row.useExcludeOverlong,
      maxSingleDurationMinutes: row.maxSingleDurationMinutes
          .clamp(1, kVmHardMaxDurationMinutes),
      skipSingleSegment: row.skipSingleSegment,
      titleTags: tags.isEmpty
          ? const [VmTitleTag.dirName, VmTitleTag.seq]
          : tags,
      useMode: row.useMode,
      enabled: row.enabled,
      pinned: row.pinned,
      playerTitleSeparator: row.playerTitleSeparator.isEmpty
          ? ':'
          : row.playerTitleSeparator,
    );
  }

  static VmRulesTableCompanion ruleToCompanion(VirtualMediaRule r) {
    return VmRulesTableCompanion.insert(
      id: r.id,
      name: r.name,
      description: Value(r.description),
      matchMode: Value(r.matchMode),
      paths: Value(jsonEncode(r.paths)),
      patterns: Value(jsonEncode([
        for (final p in r.patterns)
          {
            'kind': p.kind.name,
            'text': p.text,
            'activated': p.activated,
            'pinned': p.pinned,
          }
      ])),
      sortField: Value(r.sortField),
      sortDir: Value(r.sortDir),
      boundary: Value(r.boundary),
      maxDurationMinutes: Value(r.maxDurationMinutes),
      maxItemCount: Value(r.maxItemCount),
      useDurationCap: Value(r.useDurationCap),
      useCountCap: Value(r.useCountCap),
      useExcludeOverlong: Value(r.useExcludeOverlong),
      maxSingleDurationMinutes: Value(r.maxSingleDurationMinutes),
      skipSingleSegment: Value(r.skipSingleSegment),
      titleTags: Value(jsonEncode([for (final t in r.titleTags) t.name])),
      useMode: Value(r.useMode),
      enabled: Value(r.enabled),
      pinned: Value(r.pinned),
      playerTitleSeparator: Value(r.playerTitleSeparator),
    );
  }

  static List<String> _decodeStringList(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is List) {
        return decoded.whereType<String>().toList(growable: false);
      }
    } catch (_) {}
    return const [];
  }

  static List<VmPatternEntry> _decodePatterns(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      final out = <VmPatternEntry>[];
      for (final entry in decoded) {
        final map = entry is Map
            ? Map<String, dynamic>.from(entry)
            : <String, dynamic>{};
        final kind = VmPatternKind.values
            .where((k) => k.name == map['kind'])
            .firstOrNull;
        if (kind == null) continue;
        out.add(VmPatternEntry(
          kind: kind,
          text: (map['text'] as String?) ?? '',
          activated: (map['activated'] as bool?) ?? true,
          pinned: (map['pinned'] as bool?) ?? false,
        ));
      }
      return out;
    } catch (_) {
      return const [];
    }
  }

  static List<VmTitleTag> _decodeTitleTags(String json) {
    try {
      final decoded = jsonDecode(json);
      if (decoded is! List) return const [];
      final out = <VmTitleTag>[];
      for (final name in decoded) {
        final tag = VmTitleTag.values
            .where((t) => t.name == name)
            .firstOrNull;
        if (tag != null) out.add(tag);
      }
      return out;
    } catch (_) {
      return const [];
    }
  }
}
