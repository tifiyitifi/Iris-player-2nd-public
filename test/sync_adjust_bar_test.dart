import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/player.dart';
import 'package:iris/widgets/popups/track/sync_adjust_bar.dart';

/// Regression guard for the 28px `RenderFlex overflowed` reported on a 360dp
/// phone: the sync bar's two 3-button clusters plus the step label did not fit a
/// fixed Row. It now wraps, and the tooltips/step label are localized (no
/// hardcoded "-0.5s"/"+0.5s").
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  MediaPlayer buildPlayer() => MediaPlayer(
        isInitializing: false,
        isPlaying: false,
        externalSubtitles: const [],
        position: Duration.zero,
        duration: Duration.zero,
        buffer: Duration.zero,
        width: 0,
        height: 0,
        saveProgress: () async {},
        play: () async {},
        pause: () async {},
        backward: (_) async {},
        forward: (_) async {},
        stepBackward: () async {},
        stepForward: () async {},
        seek: (_) async {},
      );

  Future<void> pumpBar(WidgetTester tester, {required double width}) async {
    tester.view.physicalSize = Size(width, 640);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });

    await tester.pumpWidget(
      MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: SizedBox(
            width: width,
            child: SyncAdjustBar(player: buildPlayer()),
          ),
        ),
      ),
    );
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
  }

  testWidgets('lays out overflow-free at the phone width that used to clip',
      (tester) async {
    // 353.8 is the exact RenderFlex constraint the on-device overflow reported.
    await pumpBar(tester, width: 353.8);

    expect(tester.takeException(), isNull);
    expect(find.byType(Wrap), findsOneWidget);
  });

  testWidgets('still fits on a desktop-sized panel', (tester) async {
    await pumpBar(tester, width: 620);

    expect(tester.takeException(), isNull);
    expect(find.byType(Wrap), findsOneWidget);
  });

  testWidgets('tooltips and step label come from the ARB', (tester) async {
    await pumpBar(tester, width: 620);

    expect(find.byTooltip('0.5s earlier'), findsWidgets);
    expect(find.byTooltip('0.5s later'), findsWidgets);
    expect(find.byTooltip('Reset'), findsWidgets);
    // One interpolation per cluster: Subtitle + Audio, plus the step label.
    expect(find.text('±0.5s'), findsOneWidget);
  });
}
