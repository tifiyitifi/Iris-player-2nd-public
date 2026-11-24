import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/playback/playback_position_signal.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/commands/vm_dir_toggle.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

import 'helpers/sqlite3_loader.dart';

/// A paused master switch is a global stop: the folder toggle must not write a
/// rule that can never apply, and it must not resume the whole feature behind
/// the user's back. "Use" asks first; only an explicit choice may flip the
/// switch, and "keep only this folder" closes the other rules before it does.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  late String scenarioId;

  Future<void> seedMedia(String path, {int durationMs = 60000}) async {
    final parts = path.split('/');
    await DbModule.mediaNodesDao.insertNode(MediaNode.file(
      id: path,
      storageId: 'st1',
      path: parts,
      parentPath: parts.length <= 1
          ? null
          : parts.sublist(0, parts.length - 1).join('/'),
      name: parts.last,
      mediaType: MediaType.video,
      durationMs: durationMs,
    ));
  }

  Future<void> playSingle(String path) async {
    final parts = path.split('/');
    await usePlayQueueStore().update(
      playQueue: [
        PlayQueueItem(
          file: FileItem(
            storageId: 'st1',
            name: parts.last,
            uri: 'file:///$path',
            path: parts,
          ),
          index: 0,
        ),
      ],
      index: 0,
    );
  }

  Future<VmDirToggleResult> toggle({VmMasterOffChoice? choice}) =>
      toggleVmDirUseMode(
        storageId: 'st1',
        storageName: 'Store',
        name: 'a.mp4',
        path: const ['root', 'a.mp4'],
        storageBasePaths: const [],
        masterOffChoice: choice,
      );

  Future<void> seedRule({
    required String id,
    VmMatchMode mode = VmMatchMode.specifiedDirRecursive,
    List<String> paths = const ['other'],
    VmRuleUseMode useMode = VmRuleUseMode.use,
    bool enabled = true,
  }) =>
      DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
        id: id,
        name: id,
        matchMode: mode,
        paths: paths,
        useMode: useMode,
        enabled: enabled,
      ));

  List<VirtualMediaRule> rulesOf(List<VirtualMediaRule> all, String id) => [
        for (final r in all)
          if (r.id == id) r
      ];

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    PlaybackProviderRegistry.init();
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    for (final t in const [
      'media_nodes',
      'scenario',
      'scenario_sources',
      'scenario_explicit_items',
      'scenario_excludes',
      'scenario_state',
      'vm_rules',
      'virtual_media_states',
      'vm_progress',
      'scenario_queue_builds',
      'scenario_shared_index',
      'media_orders',
    ]) {
      await db.customStatement('DELETE FROM $t');
    }
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    VirtualMediaService.instance.invalidate();
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;
    VmPrefs.debugFailMasterWrite = false;
    debugFailFolderRuleWrite = false;
    // Default ON; the tests that need a pause switch it off explicitly.
    await VmPrefs.setMasterEnabled(true);
  });

  tearDown(() async {
    await VirtualMediaController.instance.stop().catchError((_) {});
    useVmPlaybackStore().replace(const VmPlaybackState());
    PlaybackPositionSignal.instance.clear();
  });

  test('a paused master switch asks before writing anything', () async {
    await seedRule(id: 'other');
    await VmPrefs.setMasterEnabled(false);

    final res = await toggle();

    expect(res.needsMasterChoice, isTrue);
    expect(res.otherEnabledCount, 1);
    expect(res.rule, isNull,
        reason: 'nothing may be written before the user decides');
    expect(await VmPrefs.masterEnabled(), isFalse,
        reason: 'the pause is a deliberate global stop, not something a '
            'folder action may end on its own');

    final all = await DbModule.virtualMediaRepo.loadRules();
    expect(all, hasLength(1), reason: 'no folder rule may be created yet');
    expect(all.single.id, 'other');
    expect(all.single.enabled, isTrue);
  });

  test('keeping only this folder closes the other rules and merges immediately',
      () async {
    await seedRule(id: 'other');
    await seedRule(id: 'already-off', enabled: false);
    await VmPrefs.setMasterEnabled(false);
    await DbModule.scenarioRepo.addSource(
      scenarioId: scenarioId,
      storageId: 'st1',
      path: 'root',
      recursive: true,
    );
    await seedMedia('root/a.mp4');
    await seedMedia('root/b.mp4');
    final store = usePlaybackScenarioStore();
    await store.ensureQueueIndex(scenarioId);
    await store.setCurrentItem(
      occurrence: const PlaybackOccurrenceId(
        storageId: 'st1',
        path: 'root/a.mp4',
      ),
    );
    await playSingle('root/a.mp4');
    await useAppStore().updateAutoPlay(true);

    final res = await toggle(choice: VmMasterOffChoice.keepOnlyCurrent);

    expect(res.needsMasterChoice, isFalse);
    expect(res.nowUsing, isTrue);
    expect(res.disabledOtherRules, 1);
    expect(res.notified, isTrue,
        reason: 'the command already refreshed the open surfaces');
    expect(await VmPrefs.masterEnabled(), isTrue);

    final all = await DbModule.virtualMediaRepo.loadRules();
    expect(rulesOf(all, 'other').single.enabled, isFalse,
        reason: 'the user asked for ONE folder, not a global resume');
    expect(rulesOf(all, 'already-off').single.enabled, isFalse,
        reason: 'an already disabled rule is not counted nor touched');
    final folder = rulesOf(all, res.rule!.id).single;
    expect(folder.matchMode, VmMatchMode.specifiedDir);
    expect(folder.paths, ['root']);
    expect(folder.useMode, VmRuleUseMode.use);
    expect(folder.enabled, isTrue);

    // The live feed is bound to the merged group: no reopen, same physical
    // file, both members on the virtual timeline.
    expect(res.adopted, isTrue);
    final ctrl = VirtualMediaController.instance;
    expect(ctrl.isActive, isTrue);
    expect(
      ctrl.state.item!.segments.map((s) => s.name),
      containsAll(<String>['a.mp4', 'b.mp4']),
    );
    expect(usePlayQueueStore().state.playQueue, hasLength(1));
    expect(usePlayQueueStore().state.playQueue.single.file.uri,
        'file:///root/a.mp4');
  });

  test('turning the switch on keeps the other rules', () async {
    await seedRule(id: 'other');
    await VmPrefs.setMasterEnabled(false);

    final res = await toggle(choice: VmMasterOffChoice.enableAll);

    expect(res.needsMasterChoice, isFalse);
    expect(res.nowUsing, isTrue);
    expect(res.disabledOtherRules, 0);
    expect(res.notified, isTrue,
        reason: 'the command already refreshed the open surfaces');
    expect(await VmPrefs.masterEnabled(), isTrue);
    final all = await DbModule.virtualMediaRepo.loadRules();
    expect(rulesOf(all, 'other').single.enabled, isTrue);
    expect(rulesOf(all, res.rule!.id).single.useMode, VmRuleUseMode.use);
  });

  test('not use while paused saves the exclusion and leaves the switch off',
      () async {
    // A recursive rule already merges the folder, so the button offers
    // "not use"; that exclusion is a valid edit even while paused.
    await seedRule(id: 'rec', paths: const ['root']);
    await VmPrefs.setMasterEnabled(false);

    final res = await toggle();

    expect(res.needsMasterChoice, isFalse);
    expect(res.nowUsing, isFalse);
    expect(res.masterPaused, isTrue,
        reason: 'the UI must say the change applies once merging resumes');
    expect(await VmPrefs.masterEnabled(), isFalse);
    final all = await DbModule.virtualMediaRepo.loadRules();
    final folder = rulesOf(all, res.rule!.id).single;
    expect(folder.matchMode, VmMatchMode.specifiedDir);
    expect(folder.useMode, VmRuleUseMode.notUse);
    expect(folder.enabled, isTrue);
  });

  test('the prompt count excludes the folder\'s own rule', () async {
    await seedRule(
      id: 'own',
      mode: VmMatchMode.specifiedDir,
      paths: const ['root'],
      useMode: VmRuleUseMode.notUse,
    );
    await seedRule(id: 'other');
    await VmPrefs.setMasterEnabled(false);

    final res = await toggle();

    expect(res.needsMasterChoice, isTrue);
    expect(res.otherEnabledCount, 1,
        reason: 'the folder rule is about to be flipped, not resumed');
  });

  test('keeping only this folder rolls back a failed disable', () async {
    final rules = <VirtualMediaRule>[
      VirtualMediaRule(
        id: 'a',
        name: 'a',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['x'],
      ),
      VirtualMediaRule(
        id: 'b',
        name: 'b',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['y'],
      ),
      VirtualMediaRule(
        id: 'already-off',
        name: 'already-off',
        matchMode: VmMatchMode.specifiedDirRecursive,
        paths: const ['z'],
        enabled: false,
      ),
    ];
    final state = <String, bool>{'a': true, 'b': true};
    var calls = 0;

    final count = await disableOtherRulesForKeepOnly(
      rules: rules,
      ownRuleId: null,
      setEnabled: (id, enabled) async {
        calls++;
        if (id == 'b' && !enabled) throw StateError('boom');
        state[id] = enabled;
      },
    );

    expect(count, isNull);
    expect(state['a'], isTrue, reason: 'the rule already disabled is restored');
    expect(state['b'], isTrue);
    expect(calls, 3, reason: 'a off, b off throws, then a on');
  });

  test('a failed folder write restores the rules it disabled', () async {
    await seedRule(id: 'other');
    await VmPrefs.setMasterEnabled(false);
    // The disable batch lands, then the folder-rule write fails: the action
    // must still change nothing.
    debugFailFolderRuleWrite = true;
    addTearDown(() => debugFailFolderRuleWrite = false);

    final res = await toggle(choice: VmMasterOffChoice.keepOnlyCurrent);

    expect(res.failed, isTrue, reason: 'the folder rule could not be written');
    expect(res.nowUsing, isFalse);
    expect(res.rule, isNull);
    final all = await DbModule.virtualMediaRepo.loadRules();
    expect(rulesOf(all, 'other').single.enabled, isTrue,
        reason: 'the disable batch must be rolled back with the failed write');
    expect(
      all.where((r) => r.matchMode == VmMatchMode.specifiedDir),
      isEmpty,
      reason: 'no folder rule may be left behind',
    );
  });

  test('a failed master write keeps the switch off and reports it', () async {
    await seedRule(id: 'other');
    await VmPrefs.setMasterEnabled(false);
    VmPrefs.debugFailMasterWrite = true;
    addTearDown(() => VmPrefs.debugFailMasterWrite = false);

    final res = await toggle(choice: VmMasterOffChoice.enableAll);

    expect(res.masterSaveFailed, isTrue);
    expect(res.notified, isFalse, reason: 'nothing was resolved or notified');
    expect(res.nowUsing, isFalse);
    expect(await VmPrefs.masterEnabled(), isFalse,
        reason: 'the switch write never landed');
    final all = await DbModule.virtualMediaRepo.loadRules();
    final folder = rulesOf(all, res.rule!.id).single;
    expect(folder.useMode, VmRuleUseMode.use,
        reason: 'the folder rule itself is saved');
    expect(rulesOf(all, 'other').single.enabled, isTrue,
        reason: 'enableAll leaves the other rules alone');
  });

  test('a failed master write after keep-only reopens the other rules',
      () async {
    await seedRule(id: 'other');
    await VmPrefs.setMasterEnabled(false);
    VmPrefs.debugFailMasterWrite = true;
    addTearDown(() => VmPrefs.debugFailMasterWrite = false);

    final res = await toggle(choice: VmMasterOffChoice.keepOnlyCurrent);

    expect(res.masterSaveFailed, isTrue);
    expect(res.nowUsing, isFalse);
    expect(res.disabledOtherRules, 0, reason: 'the disable batch is undone');
    expect(res.rule, isNull,
        reason: 'the folder rule created by the failed action is removed');
    final all = await DbModule.virtualMediaRepo.loadRules();
    expect(rulesOf(all, 'other').single.enabled, isTrue,
        reason: 'the user must not be left with their other folders closed');
    expect(all.where((r) => r.id != 'other'), isEmpty,
        reason: 'a half-applied keep-only must leave no folder rule behind');
    expect(await VmPrefs.masterEnabled(), isFalse,
        reason: 'the switch write never landed');
  });
}
