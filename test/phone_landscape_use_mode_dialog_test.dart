import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/widgets/dialogs/show_phone_landscape_use_mode_dialog.dart';

/// The legacy use-mode picker must offer exactly the three LIVE modes.
///
/// [PhoneLandscapeUseMode] still carries the deprecated `rightHanded` /
/// `leftHanded` members so an old persisted blob can be parsed, but rendering
/// them in the picker produced five rows with two duplicated pairs — and
/// tapping a deprecated row persisted it back. Deprecated values are read at
/// load-normalisation time only, never presented as a choice.
void main() {
  testWidgets('use-mode picker lists each live mode exactly once',
      (tester) async {
    await tester.pumpWidget(StoreScope(
      child: MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (BuildContext context) => TextButton(
              onPressed: () => showPhoneLandscapeUseModeDialog(context),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();
    useAppStore().set(const AppState(
      phoneLandscapeUseMode: PhoneLandscapeUseMode.rightSide,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    // kLivePhoneLandscapeUseModes is the single source of truth for "which
    // modes may be offered"; a deprecated member sneaking in must not add a
    // row, and the three labels must each appear exactly once.
    expect(
      find.byType(ListTile),
      findsNWidgets(kLivePhoneLandscapeUseModes.length),
      reason: 'only the live modes may be offered',
    );
    for (final String label in <String>['普通控制', '右侧控制', '左侧控制']) {
      expect(find.text(label), findsOneWidget,
          reason: '"$label" must appear exactly once');
    }
  });
}
