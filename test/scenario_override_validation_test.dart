import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/actions/scenario_override_actions.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_error.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_exclude_rule.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_lifetime.dart';
import 'package:iris/features/scenario_playback/model/enum/exclude_rule_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// v15-D6 regression: override play actions validate playability BEFORE they
/// mutate the workspace — a doomed request throws [PlaybackUnavailableException]
/// and leaves the workspace (and the player) untouched.
void main() {
  setUpAll(() async {
    final db = AppDatabase(NativeDatabase.memory());
    DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    // Playback needs the app/queue stores; the real app tolerates the same
    // bootstrap errors in a guarded zone (see media_search_actions_test).
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
  });

  Future<void> seedFile(String storageId, String p) async {
    await DbModule.mediaNodesDao.deleteNode(storageId, p);
    final segments = p.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'f:$storageId:$p',
      storageId: storageId,
      path: segments,
      name: segments.last,
      mediaType: MediaType.video,
    ));
  }

  FileItem fileItem(String storageId, String p) {
    final segments = p.split('/');
    return FileItem(
      storageId: storageId,
      storageType: StorageType.none,
      name: segments.last,
      uri: '/$p',
      path: segments,
      size: 0,
      type: ContentType.video,
    );
  }

  Future<List<String>> workspacePaths() async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    final sources = await store.getSources(sys.id);
    return sources.map((s) => s.path).toList();
  }

  test('playFilesOverride with no playable file throws and leaves workspace '
      'untouched', () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await store.addSource(storageId: 's', path: 'keep', recursive: true);

    await expectLater(
      ScenarioOverrideActions.playFilesOverride(
        files: [fileItem('s', 'z/missing.mp4')],
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      ),
      throwsA(isA<PlaybackUnavailableException>()),
    );
    // Workspace NOT wiped — the pre-existing source survives.
    expect(await workspacePaths(), contains('keep'));
    final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
    expect(items, isEmpty);
  });

  test('playSelectionInDefaultScenario with an empty folder throws and leaves '
      'workspace untouched', () async {
    final store = usePlaybackScenarioStore();
    await store.ensureSystemPlayingScenario();
    await store.addSource(storageId: 's', path: 'keep', recursive: true);

    await expectLater(
      ScenarioOverrideActions.playSelectionInDefaultScenario(
        files: const [],
        directories: const [
          (
            storageId: 's',
            path: 'empty',
            recursive: true,
            kind: ScenarioSourceKind.folder,
          ),
        ],
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      ),
      throwsA(isA<PlaybackUnavailableException>()),
    );
    expect(await workspacePaths(), contains('keep'));
  });

  test('playFolderScopeInDefaultScenario with an empty folder throws and '
      'leaves workspace untouched', () async {
    final store = usePlaybackScenarioStore();
    await store.ensureSystemPlayingScenario();
    await store.addSource(storageId: 's', path: 'keep', recursive: true);

    await expectLater(
      ScenarioOverrideActions.playFolderScopeInDefaultScenario(
        storageId: 's',
        folderPath: 'empty',
        tapped: fileItem('s', 'empty/x.mp4'),
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      ),
      throwsA(isA<PlaybackUnavailableException>()),
    );
    expect(await workspacePaths(), contains('keep'));
  });

  test('a playable selection commits the override', () async {
    await seedFile('s', 'a/movie.mp4');
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();

    await ScenarioOverrideActions.playFilesOverride(
      files: [fileItem('s', 'a/movie.mp4')],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
    );
    final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
    expect(items.map((e) => e.path), contains('a/movie.mp4'));
  });

  // v15-D6 + SAF: a pure-SAF single-pick selection must pass the pre-check.
  // The file has no segment path; its identity is its document uri, which
  // `media_nodes` stores as the canonical path (v51). The pre-check used to
  // collect only `path.isNotEmpty` files and threw `..._not_in_db`.
  test('a pure-SAF selection passes the pre-check and commits the override',
      () async {
    const safUri =
        'content://com.android.providers.media.documents/document/video%3A101';
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: 'saf:$safUri',
      storageId: 's',
      path: const <String>[],
      name: 'saf.mp4',
      mediaType: MediaType.video,
      uri: safUri,
    ));
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();

    await ScenarioOverrideActions.playFilesOverride(
      files: const [
        FileItem(
          storageId: 's',
          name: 'saf.mp4',
          uri: safUri,
          type: ContentType.video,
        ),
      ],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
    );
    final items = await DbModule.scenarioRepo.getExplicitItems(sys.id);
    expect(items.map((e) => e.path), contains(safUri));
  });

  // v6-D36: `force` skips the playability pre-check and still installs the
  // intended scope (an unplayable scope simply resolves to an empty queue and
  // nothing starts).
  test('force skips the pre-check and installs the scope', () async {
    final store = usePlaybackScenarioStore();
    await store.ensureSystemPlayingScenario();

    await ScenarioOverrideActions.playSelectionInDefaultScenario(
      files: const [],
      directories: const [
        (
          storageId: 's',
          path: 'empty',
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ),
      ],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
      force: true,
    );
    expect(await workspacePaths(), contains('empty'));
  });

  // v6-D8: sources are installed honoring `ScenarioSourceSpec.recursive` — a
  // non-recursive dir with only nested media fails the pre-check; when it
  // passes, the committed source keeps recursive:false.
  test('non-recursive dir with only nested media fails the pre-check (D8)',
      () async {
    await seedFile('s', 'zz/sub/deep.mp4');
    final store = usePlaybackScenarioStore();
    await store.ensureSystemPlayingScenario();
    await store.addSource(storageId: 's', path: 'keep', recursive: true);

    await expectLater(
      ScenarioOverrideActions.playSelectionInDefaultScenario(
        files: const [],
        directories: const [
          (
            storageId: 's',
            path: 'zz',
            recursive: false,
            kind: ScenarioSourceKind.folder,
          ),
        ],
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
      ),
      throwsA(isA<PlaybackUnavailableException>()),
    );
    expect(await workspacePaths(), contains('keep'));
  });

  test('installed source keeps dir.recursive (D8)', () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await seedFile('s', 'a/top.mp4');

    await ScenarioOverrideActions.playSelectionInDefaultScenario(
      files: const [],
      directories: const [
        (
          storageId: 's',
          path: 'a',
          recursive: false,
          kind: ScenarioSourceKind.folder,
        ),
      ],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
    );
    final sources = await store.getSources(sys.id);
    expect(sources.where((s) => s.path == 'a').first.recursive, isFalse);
  });

  // v6-D30: override clears temporary excludes (mirroring `_replaceSources`).
  test('override clears temporary excludes (D30)', () async {
    final store = usePlaybackScenarioStore();
    final sys = await store.ensureSystemPlayingScenario();
    await seedFile('s', 'a/movie.mp4');
    await store.addExcludeRule(ScenarioExcludeRule(
      id: 0,
      scenarioId: sys.id,
      lifetime: ExcludeLifetime.temporary,
      kind: ExcludeRuleKind.media,
      storageId: 's',
      path: 'a/old.mp4',
    ));
    expect(await store.getExcludeRules(sys.id), isNotEmpty);

    await ScenarioOverrideActions.playSelectionInDefaultScenario(
      files: [fileItem('s', 'a/movie.mp4')],
      directories: const [],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
    );
    expect(await store.getExcludeRules(sys.id), isEmpty);
  });

  // v6-D35: playback starts from the FIRST AVAILABLE item, skipping any
  // available:false placeholder that happens to sort first.
  test('plays the first available item when the first explicit is missing (D35)',
      () async {
    final store = usePlaybackScenarioStore();
    await store.ensureSystemPlayingScenario();
    await seedFile('s', 'b.mp4');
    await seedFile('s', 'c.mp4');

    await ScenarioOverrideActions.playSelectionInDefaultScenario(
      files: [
        fileItem('s', 'a.mp4'), // missing → available:false placeholder
        fileItem('s', 'b.mp4'),
        fileItem('s', 'c.mp4'),
      ],
      directories: const [],
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
    );
    final current = await store.getCurrentItem();
    expect(current, isNotNull);
    expect(current!.mediaKey, contains('b.mp4'));
  });

  // v6-D37: with `force`, a tapped file absent from media_nodes installs the
  // scope but does NOT start playback.
  test('force with missing tapped file installs scope without playing (D37)',
      () async {
    final store = usePlaybackScenarioStore();
    await store.ensureSystemPlayingScenario();
    await seedFile('s', 'a/movie.mp4');

    await ScenarioOverrideActions.playFolderScopeInDefaultScenario(
      storageId: 's',
      folderPath: 'a',
      tapped: fileItem('s', 'a/other.mp4'),
      sortField: ScenarioSortField.name,
      sortDirection: SortDirection.asc,
      force: true,
    );
    expect(await workspacePaths(), contains('a'));
    final current = await store.getCurrentItem();
    expect(current == null || !current.mediaKey.contains('other.mp4'), isTrue);
  });
}
