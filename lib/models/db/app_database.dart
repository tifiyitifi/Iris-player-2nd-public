import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:iris/features/background_playback/model/db/tables/bg_mapping_segments_table.dart';
import 'package:iris/features/background_playback/model/db/tables/bg_mappings_table.dart';
// Referenced by the generated `media_nodes.modified_at` converter (app_database.g.dart
// is a part of this library, so the class must be imported HERE, not only in the
// table file).
import 'package:iris/features/media_library/model/db/adapters/epoch_millis_converter.dart';
import 'package:iris/features/media_library/model/db/tables/media_lib_sources_table.dart';
import 'package:iris/features/media_library/model/db/tables/media_libs_table.dart';
import 'package:iris/features/media_library/model/db/tables/media_nodes_table.dart';
import 'package:iris/features/media_library/model/db/tables/scan_queue_table.dart';
import 'package:iris/features/media_library/model/db/tables/scan_states_table.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/playback_order.dart';
import 'package:iris/features/scenario_playback/model/enum/duplicate_policy.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_lifetime.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_scope.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/features/scenario_playback/model/db/tables/scenario_excludes_table.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_explicit_items_table.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_queue_builds_table.dart';
import 'package:iris/features/scenario_playback/model/db/tables/media_orders_table.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_shared_index_table.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_sources_table.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenario_states_table.dart';
import 'package:iris/features/meta_settings/model/db/tables/feature_flags_table.dart';
import 'package:iris/features/meta_settings/model/db/tables/setting_defs_table.dart';
import 'package:iris/features/meta_settings/model/db/tables/setting_values_table.dart';
import 'package:iris/features/meta_settings/model/enum/feature_stage.dart';
import 'package:iris/features/meta_settings/model/enum/settings_section.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/features/meta_settings/model/enum/setting_widget_kind.dart';
import 'package:iris/features/scenario_playback/model/db/tables/scenarios_table.dart';
import 'package:iris/features/tag_play/model/db/tables/video_tag_members_table.dart';
import 'package:iris/features/tag_play/model/db/tables/video_tag_pin_presets_table.dart';
import 'package:iris/features/tag_play/model/db/tables/video_tag_view_states_table.dart';
import 'package:iris/features/tag_play/model/db/tables/video_tags_table.dart';
import 'package:iris/features/tag_play/model/db/tables/tag_view_entries_table.dart';
import 'package:iris/features/tag_play/model/enum/tag_play_sort_field.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/models/db/migration/v2_migration.dart';
import 'package:iris/models/db/migration/v3_migration.dart';
import 'package:iris/models/db/migration/v4_migration.dart';
import 'package:iris/models/db/migration/v5_migration.dart';
import 'package:iris/models/db/migration/v6_migration.dart';
import 'package:iris/models/db/migration/v7_migration.dart';
import 'package:iris/models/db/migration/v8_migration.dart';
import 'package:iris/models/db/migration/v9_migration.dart';
import 'package:iris/models/db/migration/v10_migration.dart';
import 'package:iris/models/db/migration/v11_migration.dart';
import 'package:iris/models/db/migration/v12_migration.dart';
import 'package:iris/models/db/migration/v13_migration.dart';
import 'package:iris/models/db/migration/v14_migration.dart';
import 'package:iris/features/virtual_media/model/db/tables/virtual_media_tables.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/migration/v15_migration.dart';
import 'package:iris/models/db/migration/v16_migration.dart';
import 'package:iris/models/db/migration/v17_migration.dart';
import 'package:iris/models/db/migration/v18_migration.dart';
import 'package:iris/models/db/migration/v19_migration.dart';
import 'package:iris/models/db/migration/v20_migration.dart';
import 'package:iris/models/db/migration/v21_migration.dart';
import 'package:iris/models/db/migration/v22_migration.dart';
import 'package:iris/models/db/migration/v23_migration.dart';
import 'package:iris/models/db/migration/v24_migration.dart';
import 'package:iris/models/db/migration/v25_migration.dart';
import 'package:iris/models/db/migration/v26_migration.dart';
import 'package:iris/models/db/migration/v27_migration.dart';
import 'package:iris/models/db/migration/v28_migration.dart';
import 'package:iris/models/db/migration/v29_migration.dart';
import 'package:iris/models/db/migration/v30_migration.dart';
import 'package:iris/models/db/migration/v31_migration.dart';
import 'package:iris/models/db/migration/v32_migration.dart';
import 'package:iris/models/db/migration/v33_migration.dart';
import 'package:iris/models/db/migration/v34_migration.dart';
import 'package:iris/models/db/migration/v35_migration.dart';
import 'package:iris/models/db/migration/v36_migration.dart';
import 'package:iris/models/db/migration/v37_migration.dart';
import 'package:iris/models/db/migration/v38_migration.dart';
import 'package:iris/models/db/migration/v39_migration.dart';
import 'package:iris/models/db/migration/v40_migration.dart';
import 'package:iris/models/db/migration/v41_migration.dart';
import 'package:iris/models/db/migration/v42_migration.dart';
import 'package:iris/models/db/migration/v43_migration.dart';
import 'package:iris/models/db/migration/v44_migration.dart';
import 'package:iris/models/db/migration/v45_migration.dart';
import 'package:iris/models/db/migration/v46_migration.dart';
import 'package:iris/models/db/db_busy_retry.dart' show kDbBusyTimeoutMs;
import 'package:iris/models/db/migration/v47_migration.dart';
import 'package:iris/models/db/migration/v48_migration.dart';
import 'package:iris/models/db/migration/v49_migration.dart';
import 'package:iris/models/db/migration/v50_migration.dart';
import 'package:iris/models/db/migration/v51_migration.dart';
import 'package:iris/models/db/tables/app_meta_table.dart';
import 'package:iris/models/db/tables/navigation_table.dart';
import 'package:iris/models/db/tables/storage_table.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:iris/utils/logger.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart';

part 'app_database.g.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

/*
VERY IMPORTANT

After changing Drift table:

RUN:

flutter pub run build_runner build --delete-conflicting-outputs

Otherwise generated drift/freezed files remain stale.
*/

@DriftDatabase(
  tables: [
    // Existing tables
    StoragesTable,
    FavoritesTable,
    NavigationTable,

    // Media Library tables (introduced in schema version 2)
    MediaNodesTable,
    ScanStatesTable,
    MediaLibsTable,
    MediaLibSourcesTable,

    // Scenario-driven playback tables (schema version 10, v6 layout)
    ScenariosTable,
    ScenarioSourcesTable,
    ScenarioExplicitItemsTable,
    ScenarioExcludesTable,
    ScenarioStatesTable,

    // Metadata-driven settings tables (schema version 12)
    SettingDefsTable,
    SettingValuesTable,
    FeatureFlagsTable,

    // Tag-play tables (schema version 13)
    VideoTagsTable,
    VideoTagMembersTable,
    VideoTagViewStatesTable,
    VideoTagPinPresetsTable,

    // Virtual Media tables (schema version 16; rules v2 schema in v18;
    //   progress per scenario/tag in v21)
    VmRulesTable,
    VirtualMediaStatesTable,
    VmProgressTable,

    // Scan queue for 50w resumable scans (v22)
    ScanQueueTable,

    // 副音 playback foreground-mapping timelines (v26)
    BgMappingsTable,
    BgMappingSegmentsTable,

    // Persistent derived queue index for scalable (500k) playback (v39)
    //
    // The v39/v43 ROW tables (vm_groups, vm_group_members,
    // scenario_queue_entries) are retired as of v45: the shared-order index
    // below is the only representation. Only the build meta survives.
    ScenarioQueueBuildsTable,
    TagViewEntriesTable,

    // Cross-restart key/value bookkeeping (v41)
    AppMetaTable,

    // Shared media orders for the shared-order derived index (v44)
    MediaOrdersTable,
    ScenarioSharedIndexTable,
  ],
)
class AppDatabase extends _$AppDatabase {
  AppDatabase([QueryExecutor? executor]) : super(executor ?? _openConnection());

  /// Increment schema version whenever the database structure changes.
  @override
  int get schemaVersion => 51;

  @override
  MigrationStrategy get migration => MigrationStrategy(
        /// Called only when the database file does not yet exist.
        onCreate: (m) async {
          // Create all tables declared in @DriftDatabase.
          await m.createAll();

          // Create custom indexes.
          await _createIndexes();
        },

        /// Called when an existing database has an older schema version.
        onUpgrade: (m, from, to) async {
          if (from < 2) {
            await MigrationV2(this).run(m);
          }

          if (from < 3) {
            await MigrationV3(this).run(m);
          }

          if (from < 4) {
            await MigrationV4(this).run(m);
          }

          if (from < 5) {
            await MigrationV5(this).run(m);
          }

          if (from < 6) {
            await MigrationV6(this).run(m);
          }

          if (from < 7) {
            await MigrationV7(this).run(m);
          }

          if (from < 8) {
            await MigrationV8(this).run(m);
          }

          if (from < 9) {
            await MigrationV9(this).run(m);
          }

          if (from < 10) {
            await MigrationV10(this).run(m);
          }

          if (from < 11) {
            await MigrationV11(this).run(m);
          }

          if (from < 12) {
            await MigrationV12(this).run(m);
          }

          if (from < 13) {
            await MigrationV13(this).run(m);
          }

          if (from < 14) {
            await MigrationV14(this).run(m);
          }

          if (from < 15) {
            await MigrationV15(this).run(m);
          }

          if (from < 16) {
            await MigrationV16(this).run(m);
          }

          if (from < 17) {
            await MigrationV17(this).run(m);
          }

          if (from < 18) {
            await MigrationV18(this).run(m);
          }

          if (from < 19) {
            await MigrationV19(this).run(m);
          }

          if (from < 20) {
            await MigrationV20(this).run(m);
          }

          if (from < 21) {
            await MigrationV21(this).run(m);
          }

          if (from < 22) {
            await MigrationV22(this).run(m);
          }

          if (from < 23) {
            await MigrationV23(this).run(m);
          }

          if (from < 24) {
            await MigrationV24(this).run(m);
          }

          if (from < 25) {
            await MigrationV25(this).run(m);
          }

          if (from < 26) {
            await MigrationV26(this).run(m);
          }

          if (from < 27) {
            await MigrationV27(this).run(m);
          }

          if (from < 28) {
            await MigrationV28(this).run(m);
          }

          if (from < 29) {
            await MigrationV29(this).run(m);
          }

          if (from < 30) {
            await MigrationV30(this).run(m);
          }

          if (from < 31) {
            await MigrationV31(this).run(m);
          }

          if (from < 32) {
            await MigrationV32(this).run(m);
          }

          if (from < 33) {
            await MigrationV33(this).run(m);
          }

          if (from < 34) {
            await MigrationV34(this).run(m);
          }

          if (from < 35) {
            await MigrationV35(this).run(m);
          }

          if (from < 36) {
            await MigrationV36(this).run(m);
          }

          if (from < 37) {
            await MigrationV37(this).run(m);
          }

          if (from < 38) {
            await MigrationV38(this).run(m);
          }

          if (from < 39) {
            await MigrationV39(this).run(m);
          }

          if (from < 40) {
            await MigrationV40(this).run(m);
          }

          if (from < 41) {
            await MigrationV41(this).run(m);
          }

          if (from < 42) {
            await MigrationV42(this).run(m);
          }

          if (from < 43) {
            await MigrationV43(this).run(m);
          }

          if (from < 44) {
            await MigrationV44(this).run(m);
          }

          if (from < 45) {
            await MigrationV45(this).run(m);
          }

          if (from < 46) {
            await MigrationV46(this).run(m);
          }

          if (from < 47) {
            await MigrationV47(this).run(m);
          }

          if (from < 48) {
            await MigrationV48(this).run(m);
          }

          if (from < 49) {
            await MigrationV49(this).run(m);
          }

          if (from < 50) {
            await MigrationV50(this).run(m);
          }

          if (from < 51) {
            await MigrationV51(this).run(m);
          }
        },

        /// Optional hook useful during development.
        beforeOpen: (details) async {
          areaKeyLog.i(
            'Opening database: version=${details.versionNow}, '
            'created=${details.wasCreated}, '
            'upgraded=${details.hadUpgrade}',
          );
          // Safety net: heal any NULL data scope (invisible to scope-keyed
          // queries + exempt from UNIQUE(data_scope_id, path)). No-op when
          // every row is already scope-keyed.
          await MigrationV31.backfillNullScopes(this);
        },
      );

  /// Creates all custom indexes used by the media library subsystem.
  ///
  /// Uses `IF NOT EXISTS` so this method can safely be called from both
  /// `onCreate`
  Future<void> _createIndexes() async {
    await MigrationV2(this).createNewIndexes();
    await MigrationV4(this).createNewIndexes();
    // v31 scope-keyed media_nodes indexes (idempotent; fresh installs need
    // them too because queries filter by data_scope_id, not storage_id).
    await MigrationV31.createScopeIndexes(this);
    // v33 vm_progress non-PK delete indexes (same idempotency contract).
    await MigrationV33.createVmProgressIndexes(this);
    // v35 perf indexes (scope sort columns + feature-table lookups).
    await MigrationV35.createPerfIndexes(this);
    // v39 derived queue-index seek indexes (fresh installs get the tables via
    // createAll(); a migrated install gets its tables from MigrationV39).
    await MigrationV39.createDerivedIndexes(this);
    // v42 drops the redundant ones v39 created, so a fresh install converges on
    // the same index set an upgraded database has.
    await MigrationV42.dropRedundantIndexes(this);
    // NOTE: no v43 call here. v43's indexes belong to the row tables v45 drops,
    // so a fresh install (and every upgraded one) has neither.
  }
}

/// Pure resolver for the Drift database file location.
///
/// Precedence: Android databases dir > portable root (`<userdata>/db`,
/// only when a resolved portable root exists) > documents dir. The
/// defensive fallback (portable requested but no root) keeps installed-mode
/// behavior instead of throwing.
String resolveDbFilePath({
  required bool isAndroid,
  required bool isPortable,
  required String? portableRootPath,
  required String androidDatabasesPath,
  required String documentsPath,
  required String dbFileName,
}) {
  if (!isAndroid && isPortable && portableRootPath != null) {
    return p.join(portableRootPath, 'db', dbFileName);
  }
  if (isAndroid) {
    return p.join(androidDatabasesPath, dbFileName);
  }
  return p.join(documentsPath, dbFileName);
}

/// Opens the Drift database using a package-name-based filename.
///
/// Android:
///   Uses the standard SQLite database directory, making the database
///   visible to Android Studio's Database Inspector.
///
/// Windows portable mode (`portable.flag` next to the exe):
///   Uses `<exeDir>/userdata/db` so the whole folder stays movable.
///
/// Other platforms / installed Windows:
///   Uses the application documents directory.
/// Pragmas applied to EVERY connection to the app database.
///
/// WHY: several IRIS windows (processes) may open this same SQLite file, each
/// with its own writer. WAL lets readers and the single writer coexist,
/// `busy_timeout` makes a competing writer WAIT instead of failing immediately
/// with SQLITE_BUSY, and `synchronous=NORMAL` is the durable-enough pairing for
/// WAL. `journal_mode` is persisted in the database file, so an existing
/// database switches to WAL on its first open after this change.
DatabaseSetup get multiInstancePragmaSetup => (db) {
  db.execute('PRAGMA journal_mode=WAL');
  db.execute('PRAGMA busy_timeout=$kDbBusyTimeoutMs');
  db.execute('PRAGMA synchronous=NORMAL');
};

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    // Build a unique database file name based on the package name.
    final packageInfo = await PackageInfo.fromPlatform();
    final dbFileName = '${packageInfo.packageName}_storages.db';

    final bool isAndroid = Platform.isAndroid;
    final String androidDatabasesPath =
        isAndroid ? await getDatabasesPath() : '';
    final String documentsPath =
        isAndroid ? '' : (await getApplicationDocumentsDirectory()).path;

    final PortableLayout? layout = AppPaths.layout;
    final String filePath = resolveDbFilePath(
      isAndroid: isAndroid,
      isPortable: AppPaths.isPortable,
      portableRootPath: layout?.rootPath,
      androidDatabasesPath: androidDatabasesPath,
      documentsPath: documentsPath,
      dbFileName: dbFileName,
    );

    if (!isAndroid && AppPaths.isPortable && layout != null) {
      // sqlite3 does not create missing parent directories itself.
      await Directory(layout.dbDirPath).create(recursive: true);
    }

    final File file = File(filePath);

    areaKeyLog.i('Drift DB path: ${file.path}');

    // SQL logging disabled by default; enable via --dart-define=IRIS_LOG_KEYS=drift
    // to avoid log spam in normal debug runs (see .ai_knowledge log.txt).
    return NativeDatabase(
      file,
      logStatements: false,
      setup: multiInstancePragmaSetup,
    );
  });
}
