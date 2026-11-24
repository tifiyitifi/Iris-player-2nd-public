import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/view/vm_manager_page.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:provider/provider.dart' show InheritedProvider;
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// A folder action may resume the paused master switch. The switch at the top
/// of the manager must show that at once instead of keeping the state it read
/// when the page opened — the reported "the switch did not refresh".
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    PlaybackProviderRegistry.init();
    useAppStore();
    await useAppStore().initialized;
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
  });

  setUp(() async {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
          useScenarioDrivenPlayback: true,
        ));
    await usePlayQueueStore().clear();
    for (final rule in await DbModule.virtualMediaRepo.loadRules()) {
      await DbModule.virtualMediaRepo.deleteRule(rule.id);
    }
    // The page opens paused; the folder action is what resumes it.
    await VmPrefs.setMasterEnabled(false);
  });

  testWidgets('a folder action resumes the switch and clears the banner',
      (tester) async {
    await _seedCurrentVideo();
    await _pumpManager(tester);

    final switchTile = find.byKey(const ValueKey('vm_master_switch'));
    expect(tester.widget<SwitchListTile>(switchTile).value, isFalse,
        reason: 'the paused switch must open showing OFF');
    expect(find.text('虚拟合播总开关关闭中，规则改动暂不生效。'), findsOneWidget);

    await _openPausedPrompt(tester);

    // Three choices, every time: one is greyed here because the database holds
    // no other enabled rule.
    expect(find.text('只保留当前文件夹规则'), findsOneWidget);
    expect(find.text('直接开启总开关'), findsOneWidget);
    expect(find.text('取消本次操作'), findsOneWidget);

    await tester.tap(find.text('直接开启总开关'));
    // The switch follows the resume once the manager re-reads the preference.
    await _pumpUntil(
        tester, () => tester.widget<SwitchListTile>(switchTile).value,
        because: 'the switch to show the resumed state');
    await tester.pump(const Duration(milliseconds: 250));
    await _dismissNextFeedNotice(tester);

    expect(await VmPrefs.masterEnabled(), isTrue);
    expect(tester.widget<SwitchListTile>(switchTile).value, isTrue,
        reason: 'the folder action resumed merging, so the switch must follow');
    expect(find.text('虚拟合播总开关关闭中，规则改动暂不生效。'), findsNothing);
  });

  testWidgets('one folder action runs the notification fan-out exactly once',
      (tester) async {
    await _seedCurrentVideo();
    await _pumpManager(tester);
    await _openPausedPrompt(tester);

    final switchTile = find.byKey(const ValueKey('vm_master_switch'));
    final beforeVersion = usePlaybackScenarioStore().state.playbackVersion;
    VirtualMediaService.debugNotifyCount = 0;

    await tester.tap(find.text('直接开启总开关'));
    await _pumpUntil(
        tester, () => tester.widget<SwitchListTile>(switchTile).value,
        because: 'the switch to show the resumed state');
    await tester.pump(const Duration(milliseconds: 250));
    await _dismissNextFeedNotice(tester);

    // The command already refreshed the open surfaces; the manager's reload
    // must NOT fan out a second time.
    expect(VirtualMediaService.debugNotifyCount, 1);
    expect(usePlaybackScenarioStore().state.playbackVersion, beforeVersion + 1);
    expect(await VmPrefs.masterEnabled(), isTrue);
  });

  testWidgets('a failed master write still refreshes through the manager',
      (tester) async {
    await _seedCurrentVideo();
    await _pumpManager(tester);
    await _openPausedPrompt(tester);
    // The rule is saved, but the switch write fails: the command cannot notify.
    VmPrefs.debugFailMasterWrite = true;
    addTearDown(() => VmPrefs.debugFailMasterWrite = false);
    VirtualMediaService.debugNotifyCount = 0;

    await tester.tap(find.text('直接开启总开关'));
    await _pumpUntil(tester,
        () => find.text('文件夹规则已保存，但总开关未能开启。请在管理页手动开启。').evaluate().isNotEmpty,
        because: 'the partial-outcome notice');

    // Exactly one fan-out — the manager's, because the command did not notify.
    expect(VirtualMediaService.debugNotifyCount, 1);
    expect(await VmPrefs.masterEnabled(), isFalse);
    expect(
        tester
            .widget<SwitchListTile>(
                find.byKey(const ValueKey('vm_master_switch')))
            .value,
        isFalse,
        reason: 'a write that never landed must not look applied');
  });

  testWidgets('saving the rule editor runs the fan-out exactly once',
      (tester) async {
    await _seedCurrentVideo();
    await DbModule.virtualMediaRepo.saveRule(const VirtualMediaRule(
      id: 'seeded',
      name: 'Seeded',
      matchMode: VmMatchMode.specifiedDirRecursive,
      paths: ['root'],
    ));
    await _pumpManager(tester);

    // Edit the seeded rule: an existing rule needs no concept guide and its
    // stored name/path make the editor save immediately valid.
    await tester.tap(find.byType(PopupMenuButton<String>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('编辑'));
    await _pumpUntil(tester, () => find.text('保存').evaluate().isNotEmpty,
        because: 'the rule editor');

    // The editor notifies on save; the manager must only reload.
    VirtualMediaService.debugNotifyCount = 0;
    await tester.tap(find.text('保存'));
    await _pumpUntil(tester, () => find.text('保存').evaluate().isEmpty,
        because: 'the editor to close');
    await tester.pump(const Duration(milliseconds: 250));

    expect(VirtualMediaService.debugNotifyCount, 1,
        reason: 'the editor is the one notification choke point for a save');
  });
}

Future<void> _seedCurrentVideo() => usePlayQueueStore().update(
      playQueue: [
        PlayQueueItem(
          file: FileItem(
            storageId: 's',
            name: 'a.mp4',
            uri: 'file:///root/a.mp4',
            path: const ['root', 'a.mp4'],
          ),
          index: 0,
        ),
      ],
      index: 0,
    );

Future<void> _pumpManager(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(420, 1200));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(_storeScope(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: const Scaffold(
      body: SizedBox(width: 420, child: VmManagerPage()),
    ),
  )));
  // One frame, then poll instead of pumpAndSettle: the page shows a spinner
  // while its preference/rule reads run, and a repeating spinner never
  // "settles" if the fake clock outruns those reads.
  await tester.pump();
  await _pumpUntil(tester, () => !_spinning(tester),
      because: 'the manager to finish loading');
}

/// Taps the folder toggle and waits for the paused-master prompt.
Future<void> _openPausedPrompt(WidgetTester tester) async {
  await tester.tap(find.text('对该视频直属文件夹使用虚拟合播（仅此文件夹）'));
  await _pumpUntil(tester, () => find.text('直接开启总开关').evaluate().isNotEmpty,
      because: 'the paused-master prompt');
  await tester.pump(const Duration(milliseconds: 250));
}

/// Headless hosting may or may not bind a live feed; when it does not, the
/// panel explains the next-feed outcome first.
Future<void> _dismissNextFeedNotice(WidgetTester tester) async {
  const nextFeed = '已保存。当前视频保持单文件播放，下一次播放时生效。';
  if (find.text(nextFeed).evaluate().isEmpty) return;
  Navigator.of(tester.element(find.text(nextFeed))).pop();
  await tester.pump(const Duration(milliseconds: 250));
}

bool _spinning(WidgetTester tester) =>
    find.byType(CircularProgressIndicator).evaluate().isNotEmpty;

/// Pumps frames until [done]; fails instead of hanging when a repeating
/// animation would keep `pumpAndSettle` from ever returning.
Future<void> _pumpUntil(WidgetTester tester, bool Function() done,
    {String? because}) async {
  for (var i = 0; i < 100; i++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (done()) return;
  }
  fail('timed out${because == null ? '' : ' waiting for $because'}');
}

/// StoreScope-equivalent that keeps the global [StoreLocator] out of the
/// dispose path (the real scope disposes it and races later tests).
Widget _storeScope(Widget child) => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (e, value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: child,
    );
