import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/commands/vm_master_actions.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/view/vm_master_switch.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

import 'helpers/sqlite3_loader.dart';

/// The virtual-merge master switch is a SEAMLESS pause, not a stop:
/// - the current physical file keeps playing (queue + autoplay untouched),
/// - the live segment is written back as the scenario's current item,
/// - the enabled-rule set resolves empty immediately,
/// - both list re-resolution signals bump.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late String scenarioId;

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    final sys = await usePlaybackScenarioStore().ensureSystemPlayingScenario();
    await usePlaybackScenarioStore().refreshScenarios();
    await usePlaybackScenarioStore().setActiveScenario(sys.id);
    scenarioId = sys.id;
    PlaybackProviderRegistry.init();
    useAppStore();
    await useAppStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
  });

  setUp(() async {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    useVmPlaybackStore().replace(const VmPlaybackState());
    await usePlayQueueStore().clear();
    await useAppStore().updateAutoPlay(false);
    for (final rule in await DbModule.virtualMediaRepo.loadRules()) {
      await DbModule.virtualMediaRepo.deleteRule(rule.id);
    }
    await DbModule.virtualMediaRepo.clearAllVmProgress();
    await DbModule.virtualMediaRepo.clearAnchors();
    await VmPrefs.setMasterEnabled(true);
    VirtualMediaService.instance.invalidate();
  });

  Future<void> seed(String name) async {
    await DbModule.mediaNodesDao.deleteNode('s', name);
    await DbModule.mediaNodesDao.insertNode(
      MediaNode.file(
        id: 'f:s:$name',
        storageId: 's',
        path: [name],
        name: name,
        mediaType: MediaType.video,
      ),
    );
  }

  VirtualMediaItem item() => VirtualMediaItem(
        ruleId: 'r',
        scopeKey: 'r|d|#1',
        rootPath: 'd',
        displayIndex: 1,
        displayName: 'group',
        segments: const [
          VirtualSegment(
            mediaKey: 's:a0.mp4',
            storageId: 's',
            path: ['a0.mp4'],
            name: 'a0.mp4',
            parentPath: '',
            durationMs: 60000,
          ),
          VirtualSegment(
            mediaKey: 's:a1.mp4',
            storageId: 's',
            path: ['a1.mp4'],
            name: 'a1.mp4',
            parentPath: '',
            durationMs: 60000,
          ),
        ],
      );

  test('master switch defaults ON and persists OFF', () async {
    expect(await VmPrefs.masterEnabled(), isTrue);

    await VmPrefs.setMasterEnabled(false);

    final rows = await DbModule.metaSettingsRepo.loadRawValues();
    expect(rows['virtualmedia.masterEnabled'], '0');
    expect(await VmPrefs.masterEnabled(), isFalse);
  });

  test('disabling pauses resolution without touching the rules', () async {
    final rule = VirtualMediaRule(
      id: 'r',
      name: 'rule',
      matchMode: VmMatchMode.specifiedDir,
      paths: const [''],
    );
    await DbModule.virtualMediaRepo.saveRule(rule);

    expect(await VirtualMediaService.instance.enabledRules(), hasLength(1));

    await setVmMasterEnabled(enabled: false);

    expect(await VirtualMediaService.instance.enabledRules(), isEmpty);
    final stored = await DbModule.virtualMediaRepo.loadRules();
    expect(stored, hasLength(1));
    expect(stored.single.enabled, isTrue);

    await setVmMasterEnabled(enabled: true);

    expect(await VirtualMediaService.instance.enabledRules(), hasLength(1));
    expect(await VmPrefs.masterEnabled(), isTrue);
  });

  test(
      'disabling mid-session keeps the file playing and books the live segment',
      () async {
    await seed('a0.mp4');
    await seed('a1.mp4');
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'r',
      name: 'rule',
      matchMode: VmMatchMode.specifiedDir,
      paths: const [''],
    ));
    await useAppStore().updateAutoPlay(true);

    final ctrl = VirtualMediaController.instance;
    await ctrl.startSession(queue: [item()], queueIndex: 0, segmentIndex: 1);
    expect(ctrl.isActive, isTrue);
    expect(usePlayQueueStore().state.playQueue.single.file.name, 'a1.mp4');

    final beforeVersion = usePlaybackScenarioStore().state.playbackVersion;
    final beforeScan = usePlaybackScenarioStore().state.sourceScanRevision;

    await setVmMasterEnabled(enabled: false);

    // No stop: the feed/queue/autoplay survive, only VM state drops.
    expect(ctrl.isActive, isFalse);
    expect(useVmPlaybackStore().state.item, isNull);
    expect(usePlayQueueStore().state.playQueue.single.file.name, 'a1.mp4');
    expect(useAppStore().state.autoPlay, isTrue);

    // The live physical segment becomes the scenario's current item, so the
    // plain list highlight / next-prev / resume continue from it.
    final state = await usePlaybackScenarioStore().activeState();
    expect(state?.currentPlaybackOccurrence?.path, 'a1.mp4');
    expect(state?.currentPlaybackOccurrence?.storageId, 's');
    expect(scenarioId, isNotEmpty);

    // Both re-resolution signals moved (player chrome + open queue refetch).
    expect(usePlaybackScenarioStore().state.playbackVersion,
        greaterThan(beforeVersion));
    expect(usePlaybackScenarioStore().state.sourceScanRevision,
        greaterThan(beforeScan));

    expect(await VirtualMediaService.instance.enabledRules(), isEmpty);
  });

  testWidgets('master switch persists OFF and reports the title',
      (tester) async {
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(
        body: SizedBox(
          width: 420,
          child: VmMasterSwitch(),
        ),
      ),
    ));
    // Let the REAL async pref load run; the switch is disabled until then.
    await tester.pumpAndSettle();

    final row = find.byKey(const ValueKey('vm_master_switch'));
    expect(row, findsOneWidget);
    expect(find.text('虚拟合并'), findsOneWidget);

    await tester.tap(row);
    await tester.pumpAndSettle();

    expect(await VmPrefs.masterEnabled(), isFalse);
  });
}
