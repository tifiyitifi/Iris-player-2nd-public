import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/model/enum/bg_vm_scope_mode.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_scope_dialog.dart';
import 'package:iris/features/background_playback/view/bg_quick_panel_host.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// 作用范围 card content: the Virtual Merge rules it carries.
///
/// Kept in its own file (separate test isolate) from the pure/store VM rule
/// tests — a store-writing test followed by a widget test in the SAME file
/// leaves the harness awaiting an unresolved store load.
Widget _harness() => InheritedProvider<StoreLocator>.value(
      value: StoreLocator(),
      startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
        final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
        return sub.cancel;
      },
      lazy: false,
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Stack(
            children: [
              const BgQuickPanelHost(),
              Align(
                alignment: Alignment.topLeft,
                child: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () => showBackgroundScopeDialog(context),
                    child: const Text('open'),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );

Future<BackgroundPlaybackStore> _openPanel(
  WidgetTester tester, {
  BgApplyScope scope = BgApplyScope.currentOnly,
  bool viaButton = true,
  BgQuickPanel panel = BgQuickPanel.scope,
}) async {
  useAppStore().set(useAppStore().state.copyWith(
        useMetadataSettings: true,
        useLegacyStoragePersistence: false,
      ));
  addTearDown(() => StoreLocator().delete(BackgroundPlaybackStore));

  final bg = useBackgroundPlaybackStore();
  await bg.initialized;
  bg.set(bg.state.copyWith(
    enabled: true,
    applyScope: scope,
    // Opening via the button TOGGLES the card, so it must start closed.
    openQuickPanel: viaButton ? BgQuickPanel.none : panel,
  ));

  await tester.pumpWidget(_harness());
  await tester.pumpAndSettle();
  if (viaButton) {
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }
  return bg;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  testWidgets('作用范围: carries the two cross-video switches and applies them',
      (tester) async {
    final bg = await _openPanel(tester);

    expect(find.text('Cross-video switches'), findsWidgets);
    expect(find.text('Video moves to a new list item'), findsOneWidget);
    expect(
      find.text('Virtual video switches segments (a real file change)'),
      findsOneWidget,
    );
    expect(find.text('Keep playing'), findsOneWidget);
    expect(find.text('Keep playing (tiled)'), findsOneWidget);
    expect(find.text('Switch to a new bg'), findsNWidgets(2));

    // Defaults: item = switch to a new bg, segment = keep playing (tiled).
    expect(bg.state.bgItemSwitch, BgCrossAction.newBg);
    expect(bg.state.bgSegmentSwitch, BgCrossAction.keepPlaying);

    final segSwitch = find.byKey(const ValueKey('bg_segment_switch_segments'));
    // The segmented row can be wider than the card, so scroll the LABEL into
    // view (scrolling the whole row would leave the second segment clipped).
    final segNewBg = find.descendant(
      of: segSwitch,
      matching: find.text('Switch to a new bg'),
    );
    await tester.ensureVisible(segNewBg);
    await tester.pumpAndSettle();
    await tester.tap(segNewBg);
    await tester.pumpAndSettle();
    expect(bg.state.bgSegmentSwitch, BgCrossAction.newBg);
  });

  testWidgets('作用范围: the VM matching mode shows for 仅当前 and applies it',
      (tester) async {
    final bg = await _openPanel(tester);

    expect(find.byKey(const ValueKey('bg_vm_scope_segments')), findsOneWidget);
    expect(find.text('Current segment only'), findsOneWidget);
    expect(find.text('Whole virtual video'), findsOneWidget);
    expect(bg.state.bgVmScopeMode, BgVmScopeMode.perBlock);

    final whole = find.text('Whole virtual video');
    await tester.ensureVisible(whole);
    await tester.pumpAndSettle();
    await tester.tap(whole);
    await tester.pumpAndSettle();

    expect(bg.state.bgVmScopeMode, BgVmScopeMode.wholeVirtual);
    expect(
      find.textContaining('only stops when you leave for another video'),
      findsOneWidget,
    );
  });

  testWidgets('作用范围: the VM matching mode is hidden for the all-videos scope',
      (tester) async {
    await _openPanel(tester, scope: BgApplyScope.all);

    expect(find.byKey(const ValueKey('bg_vm_scope_segments')), findsNothing,
        reason: 'the mode only governs the "this video" scope');
    // The cross-video switches stay available regardless.
    expect(find.byKey(const ValueKey('bg_item_switch_segments')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('bg_segment_switch_segments')), findsOneWidget);
  });

  testWidgets('作用范围 card fits a 360x640 phone (VM rules do not overflow)',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _openPanel(tester);

    // The card clamps to the video area and the content scrolls, so no rule is
    // clipped and nothing overflows.
    expect(find.byKey(const ValueKey('bg_vm_scope_segments')), findsOneWidget);
    expect(find.byKey(const ValueKey('bg_item_switch_segments')), findsOneWidget);
    expect(
        find.byKey(const ValueKey('bg_segment_switch_segments')), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
