import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/widgets/dialogs/show_phone_horizontal_slider_dialog.dart';

Widget _harness() {
  return StoreScope(
    child: MaterialApp(
      locale: const Locale('zh'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Center(
          child: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showPhoneLandScapeSliderDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ),
  );
}

Future<void> _open(WidgetTester tester) async {
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets(
      'slider-type picker folds circle placement into the one-handed sides',
      (tester) async {
    // Start from the AppState defaults (right side / circle right).
    await tester.pumpWidget(_harness());
    // Deferred l10n delegates load async — settle before opening.
    await tester.pumpAndSettle();
    await _open(tester);

    // The old circleRight/circleLeft labels are gone.
    expect(find.text('正常'), findsOneWidget);
    expect(find.text('右侧'), findsOneWidget);
    expect(find.text('左侧'), findsOneWidget);
    expect(find.textContaining('circle'), findsNothing);

    // Selecting right side auto-sets the one-handed mode AND the classic
    // circle placement.
    await tester.tap(find.text('右侧'));
    await tester.pumpAndSettle();
    final store = useAppStore();
    expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.rightSide);
    expect(store.state.phoneLandscapeSliderType,
        PhoneLandscapeSliderType.circleRight);

    // Left side mirrors to the left.
    await _open(tester);
    await tester.tap(find.text('左侧'));
    await tester.pumpAndSettle();
    expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftSide);
    expect(store.state.phoneLandscapeSliderType,
        PhoneLandscapeSliderType.circleLeft);

    // Normal resets both.
    await _open(tester);
    await tester.tap(find.text('正常'));
    await tester.pumpAndSettle();
    expect(store.state.phoneLandscapeUseMode, PhoneLandscapeUseMode.normal);
    expect(store.state.phoneLandscapeSliderType, PhoneLandscapeSliderType.normal);
  });
}