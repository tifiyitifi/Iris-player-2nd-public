import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';

import 'helpers/sqlite3_loader.dart';

/// Opening/closing a cut is an ADMISSION change for Virtual Merge, not a rule
/// edit (ADR 0035). It must re-group every open surface while leaving the
/// per-session scan bookkeeping alone — the previous full rule fan-out re-armed
/// the Shell probe and the scan prompt for unrelated files.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    useAppStore();
    await useAppStore().initialized;
  });

  tearDownAll(() async {
    await db.close();
  });

  test('a cut-plan change re-groups and keeps the scan bookkeeping', () async {
    final service = VirtualMediaService.instance;
    final store = usePlaybackScenarioStore();
    service.markShellUnsupported(<String>['st1:a.mp4']);
    service.dismissScanScope('scope-1');
    VmMembershipPin.instance.seedRule('r1', <PinnedVmChunk>[
      const PinnedVmChunk(
        ruleId: 'r1',
        scopeKey: 'r1|a|#1',
        rootPath: 'a',
        displayIndex: 1,
        originalSegments: <VirtualSegment>[
          VirtualSegment(
            mediaKey: 'st1:a/1.mp4',
            storageId: 'st1',
            path: <String>['a', '1.mp4'],
            name: '1.mp4',
            parentPath: 'a',
            durationMs: 1000,
          ),
        ],
      ),
    ]);
    expect(VmMembershipPin.instance.isActive, isTrue);
    final int vmRevision = service.revision;
    final int playbackVersion = store.state.playbackVersion;
    final int scanRevision = store.state.sourceScanRevision;

    // The installed handler: the cut store calls it before bumping its revision.
    await PlaybackProviderRegistry.onCutPlanChanged(
      const FileItem(
        name: 'a.mp4',
        uri: 'C:/work/a.mp4',
        path: <String>['a.mp4'],
      ),
    );

    expect(service.revision, vmRevision + 1,
        reason: 'the derived-index signature must include the new admission');
    expect(store.state.playbackVersion, playbackVersion + 1);
    expect(store.state.sourceScanRevision, scanRevision + 1,
        reason: 'open queue surfaces only refetch on the scan revision');
    expect(VmMembershipPin.instance.isActive, isFalse,
        reason: 'a re-group trigger drops a delete-time boundary freeze');
    expect(service.isShellUnsupported('st1:a.mp4'), isTrue,
        reason: 'a cut toggle must not re-arm the Shell probe');
    expect(service.isScanDismissed('scope-1'), isTrue,
        reason: 'a cut toggle must not re-arm the scan prompt');
  });
}
