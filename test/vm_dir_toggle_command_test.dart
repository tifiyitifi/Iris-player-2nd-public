import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/commands/vm_dir_toggle.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';

import 'helpers/sqlite3_loader.dart';

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
  });

  setUp(() async {
    await db.delete(db.vmRulesTable).go();
  });

  Future<VmDirToggleResult> toggle() => toggleVmDirUseMode(
        storageId: 's',
        storageName: 'Store',
        name: 'a.mp4',
        path: const ['Shorts', 'a.mp4'],
        storageBasePaths: const [],
      );

  test('no rule creates an enabled specifiedDir use rule', () async {
    final res = await toggle();
    expect(res.usable, isTrue);
    expect(res.nowUsing, isTrue);
    final rule = res.rule!;
    expect(rule.matchMode, VmMatchMode.specifiedDir);
    expect(rule.paths, ['Shorts']);
    expect(rule.useMode, VmRuleUseMode.use);
    expect(rule.enabled, isTrue);
  });

  test('a recursive use rule creates a notUse rule for just the folder',
      () async {
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'rec',
      name: 'rec',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: const ['Shorts'],
    ));
    final res = await toggle();
    expect(res.nowUsing, isFalse);
    expect(res.rule!.useMode, VmRuleUseMode.notUse);
    expect(res.rule!.matchMode, VmMatchMode.specifiedDir);
    expect(res.rule!.paths, ['Shorts']);
  });

  test('an existing folder rule is reused, toggled and enabled', () async {
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'dir',
      name: 'dir',
      matchMode: VmMatchMode.specifiedDir,
      paths: const ['Shorts'],
      enabled: false,
    ));

    final first = await toggle();
    // Disabled use rule -> stays "use", becomes enabled (no duplicate).
    expect(first.nowUsing, isTrue);
    expect(first.rule!.id, 'dir');
    expect((await DbModule.virtualMediaRepo.ruleById('dir'))!.enabled, isTrue);

    // Seed stale progress + anchor, then flip to notUse: both must be cleared.
    await DbModule.virtualMediaRepo.saveVmProgress(
      scenarioId: 'sys',
      tagId: '',
      ruleId: 'dir',
      scopeKey: 'dir|Shorts|#1',
      segmentKey: 's:Shorts/a.mp4',
      localPositionMs: 9,
    );
    await DbModule.virtualMediaRepo.saveAnchor(
      scopeKey: 'dir|Shorts|#1',
      segmentKey: 's:Shorts/a.mp4',
      localPositionMs: 9,
    );

    final second = await toggle();
    expect(second.nowUsing, isFalse);
    final stored = await DbModule.virtualMediaRepo.ruleById('dir');
    expect(stored!.useMode, VmRuleUseMode.notUse);
    expect(await DbModule.virtualMediaRepo.loadAnchors(), isEmpty);
  });

  test('SAF single pick (empty path) has no folder to toggle', () async {
    final res = await toggleVmDirUseMode(
      storageId: 's',
      storageName: '',
      name: 'a.mp4',
      path: const [],
      storageBasePaths: const [],
      uri: 'content://doc/a',
    );
    expect(res.usable, isFalse);
  });
}
