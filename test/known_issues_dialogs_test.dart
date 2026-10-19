import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/widgets/dialogs/show_known_issues_dialog.dart';

/// Pumps a minimal host page whose single button opens the dialog under test.
/// The dialog is a plain [showDialog] wrapper without plugin dependencies, so
/// no mocks are needed.
Future<void> _pumpDialogOpener(
  WidgetTester tester,
  Future<dynamic> Function(BuildContext) open,
) async {
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('en'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: Builder(
        builder: (context) => Center(
          child: TextButton(
            onPressed: () => open(context),
            child: const Text('OPEN'),
          ),
        ),
      ),
    ),
  ));
  // Deferred l10n delegates load async — settle once before tapping.
  await tester.pumpAndSettle();
  await tester.tap(find.text('OPEN'));
  await tester.pumpAndSettle();
}

void main() {
  group('knownIssueSections (pure)', () {
    testWidgets('returns every known issue without platform filtering',
        (tester) async {
      late List<KnownIssueSection> sections;
      await _pumpDialogOpener(tester, (ctx) async {
        sections = knownIssueSections(t: AppLocalizations.of(ctx)!);
      });
      final text = sections.map((s) => '${s.header}\n${s.body}').join('\n');

      // The API has no platform branch: desktop-specific entries stay listed,
      // with applicability explained by their header/body.
      expect(text, contains('window_manager native defect'));
      expect(text, contains('Flutter 3.35+'));
      expect(text, contains('entire merged item unplayable'));
      // Cross-platform entries and the VM merge optimisation note.
      expect(text, contains('media-kit #1324'));
      expect(text, contains('5,000'));
      expect(text, contains('shared derived index'));
      expect(text, contains('bitmap'));
      expect(text, contains('does not take part in multi-select'));
      // Desktop close hides the window before the process finishes shutdown.
      expect(text, contains('Alt + F4'));
      expect(text, contains('Task Manager'));
      expect(text, contains('does not mean the close failed'));
      expect(text,
          contains('prioritises smooth playback over seek precision'));
    });
  });

  group('KnownIssuesDialog', () {
    testWidgets('opens with every entry, including the desktop close note',
        (tester) async {
      await _pumpDialogOpener(tester, showKnownIssuesDialog);

      expect(find.text('Known issues'), findsWidgets);
      expect(
          find.textContaining('window_manager native defect'), findsOneWidget);
      expect(find.textContaining('media-kit #1324'), findsOneWidget);
      expect(find.textContaining('Alt + F4'), findsOneWidget);
      expect(
          find.textContaining('prioritises smooth playback over seek precision'),
          findsOneWidget);
      expect(find.text('Got it'), findsOneWidget);
    });
  });
}
