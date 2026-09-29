import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/local_storage_discovery.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';

/// Regression guard for "the storagedb shows no local storage at all".
///
/// The discovery is kicked off from the popup ROOT's `useEffect`. flutter_hooks
/// executes effect callbacks inside `initHook`, where ANY inherited-widget
/// lookup (`Localizations.of`, i.e. `getLocalizations`) fails its assertion in
/// debug — so the discovery must take [LocalStorageLabels] resolved in build and
/// must never touch a `BuildContext` itself. Before that split, the run died
/// with `'!_debugIsInitHook': Cannot listen to inherited widgets inside
/// HookState.initState` and no disk was ever persisted.
void main() {
  late AppDatabase db;

  final disk = makeLocalStorage(
    type: StorageType.internal,
    name: 'Internal',
    basePath: const ['/storage/emulated/0'],
    volumeId: 'vol:emulated',
  );

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    useStorageStore();
    await useStorageStore().initialized;
  });

  tearDownAll(() async {
    await db.close();
  });

  setUp(() async {
    LocalStorageDiscovery.debugEnumerator = null;
    final store = useStorageStore();
    for (final s in [...store.state.storages]) {
      await store.removeStorage(s);
    }
  });

  tearDown(() {
    LocalStorageDiscovery.debugEnumerator = null;
  });

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('the popup-root effect persists the discovered disk without '
      'throwing', (tester) async {
    LocalStorageDiscovery.debugEnumerator = () async => [disk];

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: const _DiscoveryHost(),
    ));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(useStorageStore().findById(disk.id), isNotNull);
  });

  testWidgets('the loaded-gated effect still reaches the discovery once the '
      'store is ready', (tester) async {
    LocalStorageDiscovery.debugEnumerator = () async => [disk];

    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: const _DiscoveryHost(gateOnLoaded: true),
    ));
    await settle(tester);

    expect(tester.takeException(), isNull);
    expect(useStorageStore().findById(disk.id), isNotNull);
  });
}

/// Mirrors `StoragesDb`: resolve the labels during build, then run the discovery
/// from the effect. [gateOnLoaded] reproduces the root's `storageStore.loaded`
/// gate (the store is already loaded in these tests, so it only exercises the
/// hook shape).
class _DiscoveryHost extends HookWidget {
  const _DiscoveryHost({this.gateOnLoaded = false});

  final bool gateOnLoaded;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final store = useStorageStore();
    useEffect(() {
      if (gateOnLoaded && !store.loaded) return null;
      final labels = LocalStorageLabels.of(t);
      Future.microtask(() => LocalStorageDiscovery.ensure(labels: labels));
      return null;
    }, [store.loaded]);
    return const SizedBox.shrink();
  }
}
