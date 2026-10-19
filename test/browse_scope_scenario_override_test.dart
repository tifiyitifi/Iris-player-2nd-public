import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_override_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_error.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// Browse-media-scope wiring for the override playability pre-checks: a scope
/// whose files are ALL out-of-scope must fail the pre-check (v15-D6 semantics
/// applied to the narrowed visibility) instead of installing a doomed scope.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await runZonedGuarded(() async {
      usePlayQueueStore();
      await usePlayQueueStore().initialized;
      useAppStore();
      await useAppStore().initialized;
    }, (Object e, StackTrace st) {});
  });

  setUp(() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.setActiveScenario(sys.id);
    await store.clearSources(sys.id);
    await store.clearExplicitItems(sys.id);
    await store.clearTemporaryExcludes(sys.id);

    await useAppStore().setMetadataGate(true);
    await useAppStore().updateBrowseMediaScope(BrowseMediaScope.videoOnly);
    addTearDown(() async {});
  });

  tearDown(() async {
    final store = useAppStore();
    store.set(store.state.copyWith(
      browseMediaScope: BrowseMediaScope.all,
      useMetadataSettings: false,
    ));
  });

  Future<void> seedAudioOnly() async {
    const p = 'Aud/a.mp3';
    await DbModule.mediaNodesDao.deleteNode('st-ov', p);
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:st-ov:$p',
      storageId: 'st-ov',
      path: p.split('/'),
      name: 'a.mp3',
      mediaType: MediaType.audio,
    ));
  }

  FileItem audioFileItem() {
    return const FileItem(
      storageId: 'st-ov',
      storageType: StorageType.none,
      name: 'a.mp3',
      uri: '/Aud/a.mp3',
      path: ['Aud', 'a.mp3'],
      size: 0,
      type: ContentType.audio,
    );
  }

  test('folder-scope play with an out-of-scope-only folder throws', () async {
    await seedAudioOnly();

    await expectLater(
      ScenarioOverrideActions.playFolderScopeInDefaultScenario(
        storageId: 'st-ov',
        folderPath: 'Aud',
        tapped: audioFileItem(),
        recursive: false,
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      ),
      throwsA(isA<PlaybackUnavailableException>()),
    );

    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    expect(await store.getSources(sys.id), isEmpty,
        reason: 'workspace must stay untouched');
  });

  test('selection play with an out-of-scope-only directory throws', () async {
    await seedAudioOnly();

    await expectLater(
      ScenarioOverrideActions.playSelectionInDefaultScenario(
        files: const [],
        directories: <ScenarioSourceSpec>[
          (
            storageId: 'st-ov',
            path: 'Aud',
            recursive: false,
            kind: ScenarioSourceKind.folder,
          ),
        ],
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      ),
      throwsA(isA<PlaybackUnavailableException>()),
    );
  });
}
