import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/migration/v54_migration.dart';

import 'helpers/sqlite3_loader.dart';

/// Schema v54 contract: `vm_rules` gains the use/exclude polarity
/// (`use_mode`), defaulting to `use` so existing installations keep merging.
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

  tearDownAll(() async {
    await db.close();
  });

  Future<Set<String>> vmRuleColumns() async {
    final rows = await db.customSelect('PRAGMA table_info(vm_rules)').get();
    return rows.map((row) => row.read<String>('name')).toSet();
  }

  test('schemaVersion advanced to 54', () {
    expect(db.schemaVersion, greaterThanOrEqualTo(54));
  });

  test('vm_rules carries the use_mode column', () async {
    expect(await vmRuleColumns(), contains('use_mode'));
  });

  test('MigrationV54 is re-entrant', () async {
    await MigrationV54(db).run(db.createMigrator());
    expect(await vmRuleColumns(), contains('use_mode'));
  });

  test('a v53 database upgrades: use_mode is added with the use default',
      () async {
    final dir = Directory.systemTemp.createTempSync('iris_v54_upgrade');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}/iris_storages.db');

    final v53 = AppDatabase(NativeDatabase(file));
    await v53.customSelect('SELECT 1').get();
    await v53.customInsert(
      'INSERT INTO vm_rules (id, name) VALUES (?, ?)',
      variables: [
        Variable.withString('v53_legacy_row'),
        Variable.withString('legacy'),
      ],
    );
    // Recreate the v53 shape: the column does not exist yet.
    await v53.customStatement('ALTER TABLE vm_rules DROP COLUMN use_mode');
    await v53.customStatement('PRAGMA user_version = 53');
    await v53.close();

    final upgraded = AppDatabase(NativeDatabase(file));
    addTearDown(upgraded.close);
    await upgraded.customSelect('SELECT 1').get();

    final cols =
        (await upgraded.customSelect('PRAGMA table_info(vm_rules)').get())
            .map((row) => row.read<String>('name'))
            .toSet();
    expect(cols, contains('use_mode'));
    final row = await upgraded.customSelect(
      'SELECT use_mode FROM vm_rules WHERE id = ?',
      variables: [Variable.withString('v53_legacy_row')],
    ).getSingle();
    expect(row.read<String>('use_mode'), 'use',
        reason: 'existing inclusion rules must keep merging after the upgrade');
  });

  test('a row inserted without use_mode reads the use default', () async {
    await db.customInsert(
      'INSERT INTO vm_rules (id, name) VALUES (?, ?)',
      variables: [
        Variable.withString('v54_defaults'),
        Variable.withString('defaults'),
      ],
    );
    final rule = await DbModule.virtualMediaRepo.ruleById('v54_defaults');
    expect(rule, isNotNull);
    expect(rule!.useMode, VmRuleUseMode.use);
  });

  test('repository round-trips the notUse polarity', () async {
    await DbModule.virtualMediaRepo.saveRule(VirtualMediaRule(
      id: 'v54_roundtrip',
      name: 'roundtrip',
      useMode: VmRuleUseMode.notUse,
    ));
    final rule = await DbModule.virtualMediaRepo.ruleById('v54_roundtrip');
    expect(rule, isNotNull);
    expect(rule!.useMode, VmRuleUseMode.notUse);
  });
}
