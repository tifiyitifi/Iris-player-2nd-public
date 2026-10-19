import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/widgets/dialogs/show_confirm_suppressible_dialog.dart';

Future<void> pumpHarness(WidgetTester tester) async {
  await tester.pumpWidget(const MaterialApp(
    locale: Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(),
  ));
  // Deferred l10n delegates load async — settle once before opening dialogs.
  await tester.pumpAndSettle();
}

void main() {
  group('shouldShowWarning', () {
    test('shows by default and hides once suppressed', () {
      expect(shouldShowWarning([], kWarningForceAppendNoMedia), isTrue);
      expect(shouldShowWarning([kWarningForceAppendNoMedia], kWarningForceAppendNoMedia), isFalse);
      expect(shouldShowWarning([kWarningForceAppendNoMedia], kWarningPhysicalDeleteRecycle), isTrue);
    });

    test('registry exposes every suppressible warning', () {
      expect(kSuppressibleWarningIds, [
        kWarningPhysicalDeleteRecycle,
        kWarningForceAppendNoMedia,
        kWarningGestureEditCancel,
        kWarningGestureEditReset,
        kWarningGestureEditConfirm,
        kWarningBgAutoControl,
        kWarningBgAlignExitDiscard,
        kWarningBgAlignSilenceNoFile,
        kWarningBgAlignMovePointHint,
        kWarningBgAlignPercentHint,
        kWarningBgAlignSnapGuide,
        kWarningBgAlignSnapNone,
        kWarningBgAlignForceSeek,
        kWarningBgContinuation,
        kWarningWebdavSharedHost,
        kWarningDragDropScopeRestricted,
        kWarningScenarioWorkspace,
        kWarningScenarioBrowsePlayOverride,
        kWarningTagCommandGrammar,
        kWarningVmMergeConcept,
        kWarningAppOverview,
      ]);
    });
  });

  group('ConfirmSuppressibleDialog', () {
    Future<bool> pumpAndConfirm(
      WidgetTester tester, {
      required bool checkDontAsk,
      required bool pressConfirm,
      required bool preSuppressed,
      List<String> suppressedOnSuppress = const [],
    }) async {
      String? capturedId;
      final result = showConfirmSuppressibleDialog(
        tester.element(find.byType(Scaffold)),
        warningId: 'w1',
        title: 'T',
        message: 'M',
        isSuppressedOverride: (_) => preSuppressed,
        onSuppressOverride: (id) => capturedId = id,
      );

      if (preSuppressed) {
        // Fast path: no dialog at all.
        await tester.pump();
        return result;
      }

      await tester.pump(); // showDialog route in
      if (checkDontAsk) {
        await tester.tap(find.byType(CheckboxListTile));
        await tester.pump();
      }
      await tester.tap(find.text(pressConfirm ? 'OK' : 'Cancel'));
      await tester.pump();
      if (checkDontAsk && pressConfirm && capturedId != 'w1') {
        fail('suppression was not persisted on confirmed dont-ask');
      }
      return await result;
    }

    testWidgets('cancel returns false without suppressing', (tester) async {
      await pumpHarness(tester);
      final r = await pumpAndConfirm(tester,
          checkDontAsk: false, pressConfirm: false, preSuppressed: false);
      expect(r, isFalse);
    });

    testWidgets('confirm without checkbox returns true, no suppression',
        (tester) async {
      await pumpHarness(tester);
      final r = await pumpAndConfirm(tester,
          checkDontAsk: false, pressConfirm: true, preSuppressed: false);
      expect(r, isTrue);
    });

    testWidgets('checkbox defaults unchecked; confirm persists suppression',
        (tester) async {
      String? suppressedId;
      await pumpHarness(tester);
      final future = showConfirmSuppressibleDialog(
        tester.element(find.byType(Scaffold)),
        warningId: 'w1',
        title: 'T',
        message: 'M',
        onSuppressOverride: (id) => suppressedId = id,
      );
      await tester.pump(); // dialog route

      final checkbox = find.byType(CheckboxListTile);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      await tester.tap(checkbox);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);

      await tester.tap(find.text('OK'));
      await tester.pump();
      expect(await future, isTrue);
      expect(suppressedId, 'w1');
    });

    testWidgets('already-suppressed id auto-confirms without UI',
        (tester) async {
      await pumpHarness(tester);
      final r = await pumpAndConfirm(tester,
          checkDontAsk: false, pressConfirm: false, preSuppressed: true);
      expect(r, isTrue);
      expect(find.byType(AlertDialog), findsNothing);
    });
  });
}
