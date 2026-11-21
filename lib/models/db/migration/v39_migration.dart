import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/migration/migration_guards.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Schema v39: persistent derived index for scalable (500k) playback queues.
///
/// Replaces the O(N)-per-page re-walk of the effective stream with a
/// lazily-built, persisted row order:
///
///   • `vm_groups` / `vm_group_members` — materialized Virtual Merge groups
///     (the rule's own sort → boundary → caps result). A group is a function
///     of its RULE alone, so one row set is shared by every scenario/tag.
///   • `scenario_queue_entries` — the scenario's visible list rows
///     (file rows + group rows) ordered by `anchor_rank` (groups sit at their
///     earliest member's rank).
///   • `tag_view_entries` — the tag view's rows, isomorphic, sharing the same
///     group rows via `group_id`.
///
/// The tables are created EMPTY and filled lazily on first entry into a view;
/// the migration never pre-populates them, so upgrading a 500k library costs
/// nothing at startup.
///
/// Idempotent (`CREATE TABLE/INDEX IF NOT EXISTS`), also invoked from
/// `onCreate` so fresh installs get the same shape.
class MigrationV39 {
  final AppDatabase db;

  MigrationV39(this.db);

  Future<void> run(Migrator m) async {
    await createDerivedIndexTables(db);
  }

  /// Idempotent; also called from `_createIndexes()` on fresh installs.
  static Future<void> createDerivedIndexTables(AppDatabase db) async {
    const statements = <String>[
      // ── Tables (empty; drift-generated DDL is not reused here because
      //    onCreate's createAll() already covers fresh installs, while an
      //    upgrade needs explicit CREATE statements) ──
      '''
      CREATE TABLE IF NOT EXISTS vm_groups (
        group_id TEXT NOT NULL,
        rule_id TEXT NOT NULL,
        anchor_root TEXT NOT NULL DEFAULT '',
        display_seq INTEGER NOT NULL,
        segment_count INTEGER NOT NULL,
        total_duration_ms INTEGER NOT NULL DEFAULT 0,
        total_size_bytes INTEGER NOT NULL DEFAULT 0,
        build_id INTEGER NOT NULL,
        PRIMARY KEY (group_id, build_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS vm_group_members (
        group_id TEXT NOT NULL,
        in_group_rank INTEGER NOT NULL,
        media_node_id INTEGER NOT NULL,
        occurrence_index INTEGER NOT NULL DEFAULT 0,
        build_id INTEGER NOT NULL,
        PRIMARY KEY (group_id, in_group_rank, build_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS scenario_queue_entries (
        scenario_id TEXT NOT NULL,
        anchor_rank INTEGER NOT NULL,
        is_group INTEGER NOT NULL DEFAULT 0,
        group_id TEXT,
        media_node_id INTEGER,
        occurrence_index INTEGER NOT NULL DEFAULT 0,
        flags INTEGER NOT NULL DEFAULT 0,
        build_id INTEGER NOT NULL,
        PRIMARY KEY (scenario_id, anchor_rank, build_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS scenario_queue_builds (
        scenario_id TEXT NOT NULL,
        build_id INTEGER NOT NULL,
        base_count INTEGER NOT NULL,
        entry_count INTEGER NOT NULL,
        built_at INTEGER NOT NULL,
        PRIMARY KEY (scenario_id, build_id)
      );
      ''',
      '''
      CREATE TABLE IF NOT EXISTS tag_view_entries (
        tag_id TEXT NOT NULL,
        mode INTEGER NOT NULL DEFAULT 0,
        anchor_rank INTEGER NOT NULL,
        is_group INTEGER NOT NULL DEFAULT 0,
        group_id TEXT,
        media_node_id INTEGER,
        occurrence_index INTEGER NOT NULL DEFAULT 0,
        flags INTEGER NOT NULL DEFAULT 0,
        build_id INTEGER NOT NULL,
        PRIMARY KEY (tag_id, mode, anchor_rank, build_id)
      );
      ''',
    ];

    for (final stmt in statements) {
      try {
        await db.customStatement(stmt);
      } catch (e) {
        // Do NOT swallow: a missing derived-index table while the version
        // advances would break the paged reads. Rethrowing rolls the migration
        // back so the next open retries.
        _log.e('MigrationV39: table failed', e);
        rethrow;
      }
    }

    await createDerivedIndexes(db);
  }

  /// Idempotent set of seek indexes backing the paged reads.
  static Future<void> createDerivedIndexes(AppDatabase db) async {
    const statements = <String>[
      // NOTE: scenario_queue_entries AND vm_groups / vm_group_members indexes
      // are owned by MigrationV43 (schema v43 recreated those tables with
      // integer keys); creating them here would reference dropped columns.

      // tag_view_entries: page seek by (tag, mode, build, rank).
      'CREATE INDEX IF NOT EXISTS idx_tag_view_seek ON tag_view_entries(tag_id, mode, build_id, anchor_rank);',
      // tag_view_entries: membership/count intersection.
      'CREATE INDEX IF NOT EXISTS idx_tag_view_node ON tag_view_entries(tag_id, mode, build_id, media_node_id);',
      // tag_view_entries: bulk eviction of a stale generation.
      'CREATE INDEX IF NOT EXISTS idx_tag_view_build ON tag_view_entries(tag_id, mode, build_id);',
    ];
    for (final stmt in statements) {
      try {
        await db.customStatement(stmt);
      } catch (e) {
        // A hand-built/partial legacy database need not carry every feature
        // table; an index is a pure performance artifact, so its absence is
        // tolerated. Every other failure (disk full, lock, corruption) must
        // abort so drift rolls the schema version back and the next open
        // retries.
        if (!isMissingSchemaObject(e)) {
          _log.e('MigrationV39: index failed', e);
          rethrow;
        }
        _log.w('MigrationV39: index skipped, object absent: $e');
      }
    }
  }
}
