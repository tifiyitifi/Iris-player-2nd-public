import 'package:drift/drift.dart';
import 'package:iris/features/virtual_media/model/db/tables/virtual_media_tables.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/models/db/app_database.dart';

part 'virtual_media_rules_dao.g.dart';

/// Raw access to `vm_rules`. Mapping to the domain model lives in
/// [VirtualMediaRepository].
///
/// Display order is pinned-first then stable id — "无视优先级": the order
/// is purely presentational.
@DriftAccessor(tables: [VmRulesTable])
class VirtualMediaRulesDao extends DatabaseAccessor<AppDatabase>
    with _$VirtualMediaRulesDaoMixin {
  VirtualMediaRulesDao(super.db);

  Future<List<VmRulesTableData>> getAll() {
    return (select(vmRulesTable)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
          ]))
        .get();
  }

  Stream<List<VmRulesTableData>> watchAll() {
    return (select(vmRulesTable)
          ..orderBy([
            (t) => OrderingTerm(
                expression: t.pinned, mode: OrderingMode.desc),
            (t) => OrderingTerm(expression: t.id, mode: OrderingMode.asc),
          ]))
        .watch();
  }

  Future<VmRulesTableData?> getById(String id) {
    return (select(vmRulesTable)..where((t) => t.id.equals(id)))
        .getSingleOrNull();
  }

  Future<void> upsert(VmRulesTableCompanion companion) {
    return into(vmRulesTable).insertOnConflictUpdate(companion);
  }

  Future<void> setEnabled(String id, bool enabled) {
    return (update(vmRulesTable)..where((t) => t.id.equals(id)))
        .write(VmRulesTableCompanion(enabled: Value(enabled)));
  }

  Future<void> setUseMode(String id, VmRuleUseMode useMode) {
    return (update(vmRulesTable)..where((t) => t.id.equals(id)))
        .write(VmRulesTableCompanion(useMode: Value(useMode)));
  }

  Future<void> setPinned(String id, bool pinned) {
    return (update(vmRulesTable)..where((t) => t.id.equals(id)))
        .write(VmRulesTableCompanion(pinned: Value(pinned)));
  }

  Future<int> deleteById(String id) {
    return (delete(vmRulesTable)..where((t) => t.id.equals(id))).go();
  }
}
