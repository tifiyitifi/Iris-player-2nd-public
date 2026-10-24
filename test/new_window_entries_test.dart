import 'package:flutter_test/flutter_test.dart';
import 'package:iris/widgets/popups/storages/db/storages_db_list.dart';

/// Every storagedb "more" menu offers the multi-window entry ONLY where it can
/// work: scenario mode (a directory source is resolvable) and a build that can
/// actually spawn a second process (never the single-instance Store package).
void main() {
  group('storage tile menu', () {
    List<StorageTileAction> actions({
      required bool scenarioMode,
      bool canNewWindow = true,
      bool isScanned = false,
    }) =>
        [
          for (final e in storageTileMenuActions(
            scenarioMode: scenarioMode,
            canScan: true,
            online: true,
            isScanned: isScanned,
            canNewWindow: canNewWindow,
          ))
            e.action,
        ];

    test('scenario mode lists the new-window play entry', () {
      expect(
        actions(scenarioMode: true),
        contains(StorageTileAction.playInNewWindow),
      );
    });

    test('the entry disappears when the build cannot multi-instance', () {
      expect(
        actions(scenarioMode: true, canNewWindow: false),
        isNot(contains(StorageTileAction.playInNewWindow)),
      );
    });

    test('legacy mode never offers it (no directory sources there)', () {
      expect(
        actions(scenarioMode: false),
        isNot(contains(StorageTileAction.playInNewWindow)),
      );
    });

    test('the entry is enabled like play / append', () {
      final entry = storageTileMenuActions(
        scenarioMode: true,
        canScan: true,
        online: false,
        isScanned: false,
        canNewWindow: true,
      ).firstWhere((e) => e.action == StorageTileAction.playInNewWindow);
      expect(entry.enabled, isTrue);
    });
  });
}
