import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/features/virtual_media/interaction/ui/vm_tiled_manual_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';

Widget _app(Future<void> Function(BuildContext context) open) => MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => open(context),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  testWidgets('percent pick round-trips through the canonical shell',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Object? result;
    await tester.pumpWidget(_app((context) async {
      result = await showVmTiledManualDialog(context);
    }));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('vm_tiled_percent_field')), '50');
    await tester.pump();
    // Deferred l10n: resolve the OK label from the live tree.
    final t = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    await tester.tap(find.text(t.ok));
    await tester.pumpAndSettle();

    final pick = result as TiledManualPick?;
    expect(pick, isNotNull);
    expect(pick!.percent, 50);
    expect(pick.overshot, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('keyboard frames cause zero form rebuilds', (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.view.resetViewInsets();
    });

    var builds = 0;
    await tester.pumpWidget(_app((context) async {
      await showVmTiledManualDialog(context,
          debugOnFormBuild: () => builds++);
    }));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final settled = builds;
    expect(settled, greaterThan(0));

    tester.view.viewInsets = const FakeViewPadding(bottom: 300);
    await tester.pumpAndSettle();

    expect(builds, settled);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a >100 entry is cleared when from-head is chosen',
      (tester) async {
    tester.view.physicalSize = const Size(360, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    Object? result;
    await tester.pumpWidget(_app((context) async {
      result = await showVmTiledManualDialog(context);
    }));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.enterText(
        find.byKey(const ValueKey('vm_tiled_percent_field')), '150');
    await tester.pump();
    final t = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    await tester.tap(find.text(t.bg_align_head_option));
    await tester.pump();
    await tester.tap(find.text(t.ok));
    await tester.pumpAndSettle();

    final pick = result as TiledManualPick?;
    expect(pick, isNotNull);
    expect(pick!.choice, BgAlignChoice.fromHead);
    expect(pick.overshot, isFalse,
        reason: 'a stale overshoot must not jump to the NEXT bg file');
  });
}
