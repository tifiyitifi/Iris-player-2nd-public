import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_member.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_pin_preset.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_tag.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_view_state.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/features/tag_play/services/tag_membership_revision.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.tagPlay);

/// Facade over the tag_play tables (tags / members / view states / presets).
///
/// Deep module: callers speak in domain terms ("toggle membership", "active
/// members of a tag", "purge expired") while this class owns canonical path
/// normalization, lazy retention filtering, cascade deletes and transactions.
class TagPlayRepository {
  final VideoTagsDao tagsDao;
  final VideoTagMembersDao membersDao;
  final VideoTagViewStatesDao viewStatesDao;
  final VideoTagPinPresetsDao presetsDao;
  final AppDatabase db;

  TagPlayRepository({
    required this.tagsDao,
    required this.membersDao,
    required this.viewStatesDao,
    required this.presetsDao,
    required this.db,
  });

  // ── Tags ──

  Future<List<TagPlayTag>> tags() => tagsDao.getAll();

  Future<TagPlayTag?> tagById(int id) => tagsDao.getById(id);

  Future<TagPlayTag> createTag({
    required String name,
    String description = '',
    Duration? retention,
    Duration? resumeWindow,
    TagSystemKind? systemKind,
  }) {
    return tagsDao.addTag(TagPlayTag(
      id: 0,
      name: name.trim(),
      description: description.trim(),
      retention: retention,
      resumeWindow: resumeWindow,
      systemKind: systemKind,
    ));
  }

  /// Updates a tag. System-reserved rows ([TagPlayTag.systemKind] != null)
  /// are guarded: their name, role and reserved flag are fixed — attempts to
  /// rename, re-role or un-reserve them are refused (logged, no-op). Adopting
  /// a previously plain user tag as a reserved role (null → non-null) stays
  /// legal: [ensureReservedTags] relies on it.
  Future<void> updateTag(TagPlayTag tag) async {
    final existing = await tagsDao.getById(tag.id);
    if (existing == null) {
      _log.w('updateTag: missing tag id=${tag.id} — ignored');
      return;
    }
    final reserved = existing.systemKind != null;
    if (reserved) {
      if (tag.systemKind == null) {
        _log.w('updateTag: cannot un-reserve system tag id=${tag.id}');
        return;
      }
      if (tag.systemKind != existing.systemKind) {
        _log.w('updateTag: cannot change role of system tag id=${tag.id}');
        return;
      }
      if (tag.name != existing.name) {
        _log.w('updateTag: cannot rename system tag id=${tag.id}');
        return;
      }
    }
    await tagsDao.updateTag(tag);
  }

  /// Ensures the three system-reserved tags ([TagSystemKind.values]) exist
  /// with their canonical rows. Idempotent — safe to run on every startup.
  ///
  /// Adoption order per role: an existing reserved row (by kind) wins; else a
  /// plain user tag whose name equals the canonical name is claimed and
  /// normalized to the role's canonical row (kind + name + description +
  /// retention/resume policies — claiming implies the system owns it from now
  /// on); else the canonical row is created.
  Future<List<TagPlayTag>> ensureReservedTags() async {
    final all = await tags();
    final byKind = <TagSystemKind, TagPlayTag>{
      for (final t in all)
        if (t.systemKind != null) t.systemKind!: t,
    };
    final byName = {for (final t in all) t.name: t};

    final ensured = <TagPlayTag>[];
    for (final role in TagSystemKind.values) {
      final existing = byKind[role];
      if (existing != null) {
        ensured.add(existing);
        continue;
      }
      final sameName = byName[role.canonicalName];
      if (sameName != null) {
        final adopted = sameName.copyWith(
          name: role.canonicalName,
          description: role.canonicalDescription,
          retention: role.retention,
          resumeWindow: role.resumeWindow,
          systemKind: role,
        );
        await tagsDao.updateTag(adopted);
        ensured.add(adopted);
        _log.i('ensureReservedTags: adopted "${role.canonicalName}" '
            'as ${role.name} (id=${adopted.id})');
        continue;
      }
      final created = await createTag(
        name: role.canonicalName,
        description: role.canonicalDescription,
        retention: role.retention,
        resumeWindow: role.resumeWindow,
        systemKind: role,
      );
      ensured.add(created);
    }
    return ensured;
  }

  /// Deletes a tag together with its members and its play-view state
  /// (single transaction — no stray rows on failure).
  ///
  /// Returns false (and deletes nothing) when the tag is system-reserved.
  Future<bool> deleteTagCascade(int tagId) async {
    final tag = await tagsDao.getById(tagId);
    if (tag == null) return false;
    if (tag.systemKind != null) {
      _log.w('deleteTagCascade: refused — system tag id=$tagId '
          'role=${tag.systemKind}');
      return false;
    }
    await db.transaction(() async {
      await membersDao.removeAllMembersOfTag(tagId);
      await viewStatesDao.deleteByTag(tagId);
      await tagsDao.deleteTag(tagId);
    });
    TagMembershipRevision.shared.bump(tagId);
    return true;
  }

  /// Tag ids referenced by [pinnedTagIds] that still exist, preserving order.
  Future<List<TagPlayTag>> tagsByIds(List<int> pinnedTagIds) async {
    if (pinnedTagIds.isEmpty) return const [];
    final all = await tags();
    final byId = {for (final t in all) t.id: t};
    return [
      for (final id in pinnedTagIds)
        if (byId[id] != null) byId[id]!,
    ];
  }

  // ── Membership ──

  /// Adds or re-adds (refreshing `addedAt`) the media to [tagId].
  Future<void> addMember({
    required int tagId,
    required String storageId,
    required List<String> pathSegments,
    DateTime? at,
  }) async {
    await membersDao.addMember(
      tagId: tagId,
      storageId: storageId,
      canonicalPath: canonicalDbPath(pathSegments.join('/')),
      addedAt: at ?? DateTime.now(),
    );
    TagMembershipRevision.shared.bump(tagId);
  }

  Future<void> removeMember({
    required int tagId,
    required String storageId,
    required List<String> pathSegments,
  }) async {
    await membersDao.removeMember(
      tagId: tagId,
      storageId: storageId,
      canonicalPath: canonicalDbPath(pathSegments.join('/')),
    );
    TagMembershipRevision.shared.bump(tagId);
  }

  /// Raw members of [tagId] (newest first), WITHOUT expiry filtering.
  Future<List<TagPlayMember>> membersOf(int tagId) =>
      membersDao.membersOf(tagId);

  /// Members of [tagId] that are still inside the tag's retention window.
  ///
  /// Lazy expiry: expired rows are hidden here first; physical deletion is a
  /// separate background sweep ([purgeExpired]) so reads never block on writes.
  Future<List<TagPlayMember>> activeMembersOf(int tagId,
      {DateTime? now}) async {
    final tag = await tagById(tagId);
    final retention = tag?.retention;
    final members = await membersDao.membersOf(tagId);
    if (retention == null) return members;
    final cutoff = (now ?? DateTime.now()).subtract(retention);
    return members
        .where((m) => !m.addedAt.isBefore(cutoff))
        .toList(growable: false);
  }

  /// Active members of EVERY tag in one pass, keyed by tag id. Retention
  /// filtering is applied per tag (a tag keeps forever when it has no
  /// retention window). Used by the sheet's media-count computation.
  Future<Map<int, List<TagPlayMember>>> activeMembersByTag({
    DateTime? now,
  }) async {
    final reference = now ?? DateTime.now();
    final all = await tags();
    final grouped = <int, List<TagPlayMember>>{};
    for (final member in await membersDao.allMembers()) {
      grouped.putIfAbsent(member.tagId, () => []).add(member);
    }
    final out = <int, List<TagPlayMember>>{};
    for (final tag in all) {
      final members = grouped[tag.id] ?? const <TagPlayMember>[];
      final retention = tag.retention;
      if (retention == null) {
        out[tag.id] = members;
        continue;
      }
      final cutoff = reference.subtract(retention);
      out[tag.id] = members
          .where((m) => !m.addedAt.isBefore(cutoff))
          .toList(growable: false);
    }
    return out;
  }

  /// Active member counts per tag, computed in SQL. When no tag has a
  /// retention window this is a plain GROUP BY; otherwise the per-tag retention
  /// cutoffs are applied in Dart over the (small) per-tag count map.
  Future<Map<int, int>> memberCountsByTag({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    final all = await tags();
    final hasRetention = all.any((t) => t.retention != null);
    if (!hasRetention) return membersDao.countsByTag();

    // Retention-aware: count rows added at/after each tag's own cutoff. One
    // SQL GROUP BY per distinct cutoff window (usually very few tags).
    final out = <int, int>{};
    final byCutoff = <int, List<int>>{};
    for (final tag in all) {
      final retention = tag.retention;
      if (retention == null) {
        out[tag.id] = 0; // filled by the unlimited group below
        continue;
      }
      final cutoffMs =
          reference.subtract(retention).millisecondsSinceEpoch;
      byCutoff.putIfAbsent(cutoffMs, () => []).add(tag.id);
    }
    final unlimited = await membersDao.countsByTag();
    for (final tag in all) {
      if (tag.retention == null) out[tag.id] = unlimited[tag.id] ?? 0;
    }
    for (final entry in byCutoff.entries) {
      final counts = await membersDao.countsByTag(
        addedAfter: DateTime.fromMillisecondsSinceEpoch(entry.key),
      );
      for (final tagId in entry.value) {
        out[tagId] = counts[tagId] ?? 0;
      }
    }
    return out;
  }

  /// Tag ids the given media belongs to (existing memberships only).
  Future<Set<int>> membershipsOf({
    required String storageId,
    required List<String> pathSegments,
  }) async {
    final ids = await membersDao.tagIdsOfMedia(
      storageId,
      canonicalDbPath(pathSegments.join('/')),
    );
    return ids.toSet();
  }

  /// Bulk membership lookup for queue rows: maps each canonical media key
  /// (`storageId:canonicalPath`, the same shape as [TagPlayMember.mediaKey])
  /// to the tags the media belongs to. Returns an empty list for untagged keys.
  Future<Map<String, List<TagPlayTag>>> tagsOfMediaKeys(
      Set<String> keys) async {
    if (keys.isEmpty) return const {};
    final storageIds = <String>{};
    final paths = <String>{};
    for (final key in keys) {
      final idx = key.indexOf(':');
      if (idx <= 0) continue;
      storageIds.add(key.substring(0, idx));
      paths.add(key.substring(idx + 1));
    }
    final rows = await membersDao.membersMatching(
      storageIds: storageIds.toList(),
      paths: paths.toList(),
    );
    final allTags = await tags();
    final byId = {for (final t in allTags) t.id: t};
    // Prefill every requested key so callers can distinguish "loaded, no tags"
    // (empty list) from "not yet loaded" (absent map entry).
    final result = {for (final k in keys) k: <TagPlayTag>[]};
    for (final member in rows) {
      if (!keys.contains(member.mediaKey)) continue;
      final tag = byId[member.tagId];
      if (tag == null) continue;
      result.putIfAbsent(member.mediaKey, () => []).add(tag);
    }
    return result;
  }

  /// Newest active member of [tagId], or null when none qualifies.
  Future<TagPlayMember?> latestActiveMember(int tagId, {DateTime? now}) async {
    final active = await activeMembersOf(tagId, now: now);
    return active.isEmpty ? null : active.first;
  }

  // ── Retention sweep (background, idempotent) ──

  /// Physically deletes every expired member across all retention-bound tags.
  /// Returns the number of removed rows. Safe to run repeatedly (startup hook).
  Future<int> purgeExpired({DateTime? now}) async {
    final reference = now ?? DateTime.now();
    var removed = 0;
    final touched = <int>{};
    try {
      await db.transaction(() async {
        for (final tag in await tags()) {
          final retention = tag.retention;
          if (retention == null) continue;
          final cutoff = reference.subtract(retention);
          final gone = await membersDao.deleteExpiredOfTag(tag.id, cutoff);
          if (gone > 0) {
            removed += gone;
            touched.add(tag.id);
          }
        }
      });
    } catch (e) {
      _log.e('TagPlayRepository.purgeExpired failed: $e');
      return removed;
    }
    if (removed > 0) {
      _log.i('TagPlayRepository.purgeExpired removed=$removed');
      // Each affected tag is announced separately so an unrelated tag's
      // retention sweep never invalidates a 副音 pool that reads other tags.
      for (final tagId in touched) {
        TagMembershipRevision.shared.bump(tagId);
      }
    }
    return removed;
  }

  // ── View states ──

  Future<TagPlayViewState?> stateOf(int tagId) => viewStatesDao.getByTag(tagId);

  Future<void> saveState(TagPlayViewState state) => viewStatesDao.upsert(state);

  // ── Pin presets ──

  Future<List<TagPlayPinPreset>> presets() => presetsDao.getAll();

  Future<int> savePreset(TagPlayPinPreset preset) => presetsDao.save(preset);

  Future<void> deletePreset(int id) => presetsDao.deleteById(id);

  // ── Maintenance ──

  /// Drops memberships whose media vanished from every given set. Used by
  /// future sync integrations; kept minimal for now.
  Future<void> removeMembershipsForTags({
    required List<int> tagIds,
    required Set<String> canonicalKeys,
  }) async {
    if (tagIds.isEmpty || canonicalKeys.isEmpty) return;
    await db.transaction(() async {
      for (final tagId in tagIds) {
        for (final member in await membersDao.membersOf(tagId)) {
          if (!canonicalKeys.contains(member.mediaKey)) {
            await membersDao.removeMember(
              tagId: tagId,
              storageId: member.storageId,
              canonicalPath: member.path,
            );
          }
        }
      }
    });
  }

  /// Whether any of [tagIds] exists (used by preset application validation).
  Future<bool> anyTagExists(List<int> tagIds) async {
    if (tagIds.isEmpty) return false;
    final ids = (await tags()).map((t) => t.id).toSet();
    return tagIds.any(ids.contains);
  }
}
