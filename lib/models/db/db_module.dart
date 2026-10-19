import 'dart:async';

import 'package:iris/features/background_playback/model/db/dao/bg_mapping_segments_dao.dart';
import 'package:iris/features/background_playback/model/db/dao/bg_mappings_dao.dart';
import 'package:iris/features/background_playback/model/db/repositories/background_mapping_repository.dart';
import 'package:iris/features/media_library/model/db/dao/media_lib_sources_dao.dart';
import 'package:iris/features/media_library/model/db/dao/media_libs_dao.dart';
import 'package:iris/features/media_library/model/db/dao/media_nodes_dao.dart';
import 'package:iris/features/media_library/model/db/dao/scan_queue_dao.dart';
import 'package:iris/features/media_library/model/db/dao/scan_states_dao.dart';
import 'package:iris/features/media_library/model/db/repositories/media_library_repository_facade.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/library_repository.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_library_repository.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_node_repository.dart';
import 'package:iris/features/media_library/model/db/repositories/sub/media_scan_repository.dart';
import 'package:iris/features/meta_settings/model/db/repositories/settings_db_repository.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_excludes_dao.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_explicit_items_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/media_order_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_queue_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_shared_index_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_sources_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenario_states_dao.dart';
import 'package:iris/features/scenario_playback/model/db/dao/scenarios_dao.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_members_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_pin_presets_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tag_view_states_dao.dart';
import 'package:iris/features/tag_play/model/db/dao/video_tags_dao.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/virtual_media/model/db/dao/virtual_media_progress_dao.dart';
import 'package:iris/features/virtual_media/model/db/dao/virtual_media_rules_dao.dart';
import 'package:iris/features/virtual_media/model/db/dao/virtual_media_states_dao.dart';
import 'package:iris/features/virtual_media/model/db/repositories/virtual_media_repository.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/dao/app_meta_dao.dart';
import 'package:iris/models/db/dao/favorites_dao.dart';
import 'package:iris/models/db/dao/navigation_dao.dart';
import 'package:iris/models/db/dao/storage_dao.dart';
import 'package:iris/models/db/repositories/favorites_db_repository.dart';
import 'package:iris/models/db/repositories/navigation_db_repository.dart';
import 'package:iris/models/db/repositories/storage_db_repository.dart';

class DbModule {
  // DAOs
  static late final StorageDao storageDao;
  static late final FavoritesDao favoritesDao;
  static late final NavigationDao navigationDao;

  static late final MediaLibsDao mediaLibsDao;
  static late final MediaLibSourcesDao mediaLibSourcesDao;
  static late final MediaNodesDao mediaNodesDao;
  static late final ScanStatesDao scanStatesDao;
  static late final ScanQueueDao scanQueueDao;

  // Scenario-driven playback DAOs
  static late final ScenariosDao scenariosDao;
  static late final ScenarioSourcesDao scenarioSourcesDao;
  static late final ScenarioExplicitItemsDao scenarioExplicitItemsDao;
  static late final ScenarioExcludesDao scenarioExcludesDao;
  static late final ScenarioStatesDao scenarioStatesDao;

  // v39 derived queue index (scalable 500k playback).
  static late final ScenarioQueueIndexDao scenarioQueueIndexDao;

  /// v44 shared media orders (shared-order derived index).
  static late final MediaOrderDao mediaOrderDao;

  /// v44 per-scenario shared-order derived index.
  static late final ScenarioSharedIndexDao scenarioSharedIndexDao;

  /// Cross-restart key/value bookkeeping (v41).
  static late final AppMetaDao appMetaDao;

  // Tag-play DAOs
  static late final VideoTagsDao videoTagsDao;
  static late final VideoTagMembersDao videoTagMembersDao;
  static late final VideoTagViewStatesDao videoTagViewStatesDao;
  static late final VideoTagPinPresetsDao videoTagPinPresetsDao;

  // Virtual Media DAOs
  static late final VirtualMediaRulesDao virtualMediaRulesDao;
  static late final VirtualMediaStatesDao virtualMediaStatesDao;
  static late final VirtualMediaProgressDao virtualMediaProgressDao;

  // Repositories
  static late final StorageDbRepository storageRepo;
  static late final SettingsDbRepository metaSettingsRepo;
  static late final FavoritesDbRepository favoritesRepo;
  static late final NavigationDbRepository navRepo;

  static late final LibraryRepository libraryRepo;
  static late final MediaLibrarySourcesRepository libSourceRepo;
  static late final MediaNodeRepository mediaNodeRepo;
  static late final ScanStateRepository scanStateRepo;

  static late final MediaLibraryFacade mediaFacade;

  static late final ScenarioRepository scenarioRepo;

  static late final TagPlayRepository tagPlayRepo;

  static late final VirtualMediaRepository virtualMediaRepo;

  // 副音 playback mapping (v26)
  static late final BgMappingsDao bgMappingsDao;
  static late final BgMappingSegmentsDao bgMappingSegmentsDao;
  static late final BackgroundMappingRepository bgMappingRepo;

  // 副音 candidate-source rules (v28) retired: 副音 now resolves from its
  // background scenario. See BackgroundScenarioPool.

  static MediaNodeRepository get nodeRepository => mediaNodeRepo;

  static MediaLibrarySourcesRepository get sourcesRepository => libSourceRepo;

  static ScenarioRepository get scenarioRepository => scenarioRepo;

  static final Completer<void> _ready = Completer<void>();

  /// Completes once [init] has wired every DAO/repo.
  ///
  /// Lifecycle: `AppStore`/`UnifiedPlayQueueStore` are constructed during the
  /// first frame, before [init] runs. Startup awaits this gate (via
  /// `AppStore.applyConfiguredBackends`) before touching DB-backed stores, so
  /// the query backend never races the DB wiring.
  static Future<void> get ready => _ready.future;

  /// Whether [init] has finished. Synchronous probe for callers that must NOT
  /// touch a DB-backed store before it is wired (e.g. the 副音 store's
  /// best-effort position persistence, which is a no-op in store-free tests).
  static bool get isReady => _ready.isCompleted;

  static Future<void> init(AppDatabase db) async {
    // DAOs
    storageDao = StorageDao(db);
    favoritesDao = FavoritesDao(db);
    navigationDao = NavigationDao(db);

    mediaLibsDao = MediaLibsDao(db);
    mediaLibSourcesDao = MediaLibSourcesDao(db);
    mediaNodesDao = MediaNodesDao(db);
    scanStatesDao = ScanStatesDao(db);
    scanQueueDao = ScanQueueDao(db);

    scenariosDao = ScenariosDao(db);
    scenarioSourcesDao = ScenarioSourcesDao(db);
    scenarioExplicitItemsDao = ScenarioExplicitItemsDao(db);
    scenarioExcludesDao = ScenarioExcludesDao(db);
    scenarioStatesDao = ScenarioStatesDao(db);
    scenarioQueueIndexDao = ScenarioQueueIndexDao(db);
    mediaOrderDao = MediaOrderDao(db);
    scenarioSharedIndexDao = ScenarioSharedIndexDao(db);
    appMetaDao = AppMetaDao(db);

    videoTagsDao = VideoTagsDao(db);
    videoTagMembersDao = VideoTagMembersDao(db);
    videoTagViewStatesDao = VideoTagViewStatesDao(db);
    videoTagPinPresetsDao = VideoTagPinPresetsDao(db);

    virtualMediaRulesDao = VirtualMediaRulesDao(db);
    virtualMediaStatesDao = VirtualMediaStatesDao(db);
    virtualMediaProgressDao = VirtualMediaProgressDao(db);

    // Repos
    storageRepo = StorageDbRepository(storageDao);
    favoritesRepo = FavoritesDbRepository(favoritesDao);
    navRepo = NavigationDbRepository(navigationDao);

    libraryRepo = LibraryRepository(
      libsDao: mediaLibsDao,
      sourcesDao: mediaLibSourcesDao,
      db: db,
    );

    libSourceRepo = MediaLibrarySourcesRepository(mediaLibSourcesDao);

    mediaNodeRepo = MediaNodeRepository(
      mediaNodesDao,
    );

    scanStateRepo = ScanStateRepository(
      db: db,
      scanDao: scanStatesDao,
      nodesDao: mediaNodesDao,
    );

    mediaFacade = MediaLibraryFacade(
      libraryRepo: libraryRepo,
      scanRepo: scanStateRepo,
    );

    scenarioRepo = ScenarioRepository(
      scenariosDao: scenariosDao,
      sourcesDao: scenarioSourcesDao,
      itemsDao: scenarioExplicitItemsDao,
      excludesDao: scenarioExcludesDao,
      statesDao: scenarioStatesDao,
    );

    tagPlayRepo = TagPlayRepository(
      tagsDao: videoTagsDao,
      membersDao: videoTagMembersDao,
      viewStatesDao: videoTagViewStatesDao,
      presetsDao: videoTagPinPresetsDao,
      db: db,
    );

    virtualMediaRepo = VirtualMediaRepository(
      rulesDao: virtualMediaRulesDao,
      statesDao: virtualMediaStatesDao,
      progressDao: virtualMediaProgressDao,
    );

    bgMappingsDao = BgMappingsDao(db);
    bgMappingSegmentsDao = BgMappingSegmentsDao(db);
    bgMappingRepo = BackgroundMappingRepository(
      mappingsDao: bgMappingsDao,
      segmentsDao: bgMappingSegmentsDao,
      db: db,
    );

    // Metadata-settings subsystem: seeds defs/flags mirrors; must complete
    // before any store loads so the gate path (if enabled) can route.
    await MetaSettingsModule.init(db);
    metaSettingsRepo = MetaSettingsModule.repo;

    // Row-level encryption sweep for legacy plaintext passwords (v17).
    // Best-effort: failures are logged but never block startup.
    try {
      await storageRepo.migratePlaintextPasswords();
    } catch (_) {}

    if (!_ready.isCompleted) _ready.complete();
  }
}
