import 'package:drift/drift.dart';
import 'package:iris/models/db/app_database.dart';

/// Schema v28: 副音 candidate-source rules table — RETIRED.
///
/// `bg_source_rules` is dropped in v48: 副音 now resolves its candidate pool
/// from the reserved 「副音备选」tag's VIEW (a tag play view, shared with the
/// foreground), so the rule table has no reader or writer and its Drift table
/// class is gone. This step is kept as a no-op so the migration chain still
/// runs in order for a database that predates it (v48 removes the table
/// either way).
///
/// NOTE: the rules that predate this table lived as a KV JSON blob
/// (`BackgroundPlaybackState.sources`) imported once by the now-deleted
/// `BgSourceBootstrap`. A database so old that it jumps straight into the
/// current chain never creates the table AND never runs that bootstrap, so
/// those pre-v28 rules are not recoverable anywhere — accepted, since no such
/// instance remains in the wild. See the v48 migration for the surviving path.
class MigrationV28 {
  final AppDatabase db;

  MigrationV28(this.db);

  Future<void> run(Migrator m) async {
    // Intentionally empty — see the class doc. The table is created by
    // nothing and dropped by MigrationV48.
  }
}
