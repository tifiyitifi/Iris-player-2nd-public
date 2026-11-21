import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart'
    show debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/commands/tag_play_actions.dart';
import 'package:iris/features/tag_play/model/db/repositories/tag_play_repository.dart';
import 'package:iris/features/tag_play/store/tag_play_state.dart';
import 'package:iris/features/tag_play/store/use_tag_play_store.dart';
import 'package:iris/features/tag_play/view/tag_play_sheet.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/platform.dart'
    show debugIsMobilePlatformOverride;
import 'package:iris/widgets/popup.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// StoreScope-equivalent that does NOT dispose the global StoreLocator on
/// unmount — [StoreScope] tears it down fire-and-forget, which races the next
/// test's stores against a closing locator ("Cannot add new events after
/// calling close"). Mirrors StoreScope's build minus the dispose.
Widget _storeScope(Widget child) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: child,
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late TagPlayRepository repo;

  setUpAll(() async {
    final bootstrap = AppDatabase(NativeDatabase.memory());
    await DbModule.init(bootstrap);
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    final app = useAppStore();
    app.set(app.state.copyWith(useMetadataSettings: true));
    // The sheet's command runner resolves `*` through the registry (the same
    // wiring main.dart performs).
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    PlaybackProviderRegistry.init();
  });

  setUp(() {
    TagPlayStore.sessionHintHidden = false;
    useTagPlayStore().set(const TagPlayState());
    repo = DbModule.tagPlayRepo;
  });

  /// The sheet mounted bare (no route chrome) — layout/behavior assertions
  /// that do not depend on the route.
  Widget bareTree(
    Size surface,
    double keyboard, {
    String? initialCommand,
  }) {
    return _storeScope(
      MaterialApp(
        locale: const Locale('zh'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: MediaQuery(
          data: MediaQueryData(
            size: surface,
            viewInsets: EdgeInsets.only(bottom: keyboard),
            // Phone-realistic: the larger font exposes cramped chrome.
            textScaler: const TextScaler.linear(1.3),
          ),
          child: Scaffold(
            resizeToAvoidBottomInset: false,
            body: Align(
              alignment: Alignment.bottomLeft,
              child: TagPlaySheet(initialCommand: initialCommand),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> pumpSheet(
    WidgetTester tester, {
    Size surface = const Size(360, 640),
    double keyboard = 0,
    String? initialCommand,
  }) async {
    tester.view.physicalSize = surface;
    tester.view.devicePixelRatio = 1.0;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
    await tester.pumpWidget(
        bareTree(surface, keyboard, initialCommand: initialCommand));
    await tester.pumpAndSettle();
  }

  /// Opens the sheet through the REAL [Popup] route — the same chrome
  /// production uses, including its autofocus Escape-to-close listener.
  Future<void> pumpViaPopup(
    WidgetTester tester, {
    String? initialCommand,
    bool openViaShortcut = false,
  }) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      _storeScope(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                hostContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    Navigator.of(hostContext).push(Popup<void>(
      direction: PopupDirection.right,
      child: TagPlaySheet(
        initialCommand: initialCommand,
        openViaShortcut: openViaShortcut,
      ),
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('sheet 360px + software keyboard + large font: no overflow',
      (tester) async {
    await pumpSheet(tester, keyboard: 300);
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputField')), findsOneWidget);
  });

  testWidgets('desktop shows the input bar prefilled with the entry operator',
      (tester) async {
    await pumpSheet(tester, initialCommand: '+');
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.controller?.text, '+');
  });

  testWidgets('desktop: the field takes focus through the real Popup route',
      (tester) async {
    await pumpViaPopup(tester, initialCommand: '+');
    expect(tester.takeException(), isNull);
    // Regression: the route's autofocus Escape listener wins the scope's
    // autofocus race, so without an explicit claim the typed digits go nowhere.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.focusNode?.hasFocus, isTrue);
  });

  testWidgets('tapping the sheet background does not dismiss it',
      (tester) async {
    await pumpViaPopup(tester, initialCommand: '+');
    // The header is empty chrome — a tap there must not reach the route
    // barrier (that would close the sheet while the user reaches back in).
    await tester.tap(find.text('Tag Play'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputField')), findsOneWidget);
  });

  testWidgets('closing the sheet releases focus so the keys work again',
      (tester) async {
    await pumpViaPopup(tester, initialCommand: '+');
    final field = find.byKey(const ValueKey('tagInputField'));
    expect(field, findsOneWidget);

    Navigator.of(tester.element(field)).pop();
    await tester.pumpAndSettle();
    expect(field, findsNothing);

    // `playerKeysAllowed` blocks shortcuts while primary focus sits inside a
    // text field — a stale field focus would leave the numpad keys dead.
    final focusContext = FocusManager.instance.primaryFocus?.context;
    expect(focusContext?.findAncestorStateOfType<EditableTextState>(), isNull);
  });

  testWidgets('a successful submit clears the line and keeps the field ready',
      (tester) async {
    await pumpViaPopup(tester, initialCommand: '+');
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '*0');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    // `TextInputAction.done` unfocuses the field; the bar re-claims it so the
    // numpad entry keys keep working without re-opening the sheet, and the
    // line restarts empty for the next command.
    expect(field.controller?.text, '');
    expect(field.focusNode?.hasFocus, isTrue);
  });

  testWidgets('a numpad operator restarts the line for the next command',
      (tester) async {
    await pumpViaPopup(tester, initialCommand: '+1.2');
    await tester.sendKeyEvent(LogicalKeyboardKey.numpadMultiply);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.controller?.text, '*');
    expect(field.controller?.selection.baseOffset, 1);
    expect(field.focusNode?.hasFocus, isTrue);
  });

  testWidgets('a main-keyboard operator mid-line collapses to that operator',
      (tester) async {
    await pumpViaPopup(tester, initialCommand: '+');
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '+1.2');
    // The main keyboard appends `*` at the caret (numpad keys are intercepted
    // as key events; this is the formatter backstop for the same intent).
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: '+1.2*',
      selection: TextSelection.collapsed(offset: 5),
    ));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);

    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.controller?.text, '*');
  });

  testWidgets('slash cancels the input and closes the sheet', (tester) async {
    await pumpViaPopup(tester, initialCommand: '+1.2');
    await tester.sendKeyEvent(LogicalKeyboardKey.slash);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputField')), findsNothing);
    expect(find.text('Tag Play'), findsNothing);
  });

  testWidgets('rows lead with an exclusive radio; no tag is the default',
      (tester) async {
    await repo.createTag(name: 'one');
    await repo.createTag(name: 'two');
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    // Default selection = "no tag"; both tag rows unselected.
    expect(find.byIcon(Icons.radio_button_checked), findsOneWidget);
    expect(find.byIcon(Icons.radio_button_unchecked), findsNWidgets(2));
    // The old ambiguous "Play" half is gone.
    expect(find.text('播放'), findsNothing);
  });

  testWidgets('a tag row shows its scenario/total media count',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    await repo
        .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['x.mp4']);
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    // No active scenario in this harness → scenarioCount 0, membership 1.
    expect(find.text('0/1'), findsOneWidget);
  });

  testWidgets('the previous-view row stays hidden by default, stack or not',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    final store = useTagPlayStore();
    // A persisted stack must not resurrect the row while the preference is
    // OFF (the default).
    store.set(store.state.copyWith(viewStackTagIds: [tag.id]));

    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    // The radio already shows the active tag — no jump-back row by default.
    expect(find.byIcon(Icons.undo_rounded), findsNothing);
  });

  testWidgets('the previous-view row renders once the preference is opted in',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    final store = useTagPlayStore();
    store.set(store.state.copyWith(
      viewStackEnabled: true,
      viewStackTagIds: [tag.id],
    ));

    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    expect(find.byIcon(Icons.undo_rounded), findsOneWidget);
  });

  testWidgets('the media count sits on the row sub-title, not at its front',
      (tester) async {
    final tag = await repo.createTag(name: 'subtitle-count');
    await repo
        .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['x.mp4']);
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);

    final row = find.byKey(ValueKey('tagRow-${tag.id}'));
    final count = find.descendant(of: row, matching: find.text('0/1'));
    expect(count, findsOneWidget);

    // It shares the sub-title column with the name (its own line)...
    final subTitle = find
        .ancestor(of: find.text('subtitle-count'), matching: find.byType(Column))
        .first;
    expect(find.descendant(of: subTitle, matching: count), findsOneWidget);

    // ...instead of leading the row: it now renders to the right of the radio.
    final activate = find.descendant(
      of: row,
      matching: find.byKey(ValueKey('tagRowActivate-${tag.id}')),
    );
    expect(
      tester.getTopLeft(count).dx,
      greaterThan(tester.getTopLeft(activate).dx),
    );
  });

  testWidgets('a tag with no media in the scenario gets a disabled radio',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    await repo
        .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['x.mp4']);
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);

    final button = tester.widget<IconButton>(
      find.byKey(ValueKey('tagRowActivate-${tag.id}')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('ignore-scenario toggle stays settable while no tag view is active',
      (tester) async {
    await repo.createTag(name: 'one');
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);

    // The switch is a preference: it can be prepared before any tag view is
    // active, so the checkbox is never disabled.
    final toggle = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('tagIgnoreScenarioToggle')),
    );
    expect(toggle.value, isFalse);
    expect(toggle.onChanged, isNotNull);
  });

  testWidgets(
      'toggling ignore-scenario with no active tag enables member-only rows',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    await repo
        .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['x.mp4']);
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);

    final activate = find.byKey(ValueKey('tagRowActivate-${tag.id}'));
    // Without ignoring the scenario the tag has no scenario media → greyed.
    expect(tester.widget<IconButton>(activate).onPressed, isNull);

    await tester.tap(find.byKey(const ValueKey('tagIgnoreScenarioToggle')));
    await tester.pumpAndSettle();

    expect(useTagPlayStore().state.ignoreScenario, isTrue);
    // Its own membership is what the view would now play, so it is jumpable.
    expect(tester.widget<IconButton>(activate).onPressed, isNotNull);
  });

  testWidgets('ignore-scenario toggle is enabled once a tag view is active',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    await repo
        .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['x.mp4']);
    final store = useTagPlayStore();
    store.set(store.state.copyWith(activeViewTagId: tag.id));

    await pumpSheet(tester);
    expect(tester.takeException(), isNull);

    final toggle = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('tagIgnoreScenarioToggle')),
    );
    expect(toggle.onChanged, isNotNull);
    // With ignore-scenario off, the tag's empty scenario view stays greyed.
    final button = tester.widget<IconButton>(
      find.byKey(ValueKey('tagRowActivate-${tag.id}')),
    );
    expect(button.onPressed, isNull);
  });

  testWidgets('ignore-scenario on enables a tag with members but no scenario media',
      (tester) async {
    final tag = await repo.createTag(name: 'one');
    await repo
        .addMember(tagId: tag.id, storageId: 's1', pathSegments: ['x.mp4']);
    final store = useTagPlayStore();
    store.set(store.state.copyWith(
      activeViewTagId: tag.id,
      ignoreScenario: true,
    ));

    await pumpSheet(tester);
    expect(tester.takeException(), isNull);

    // The tag's own membership is playable once the scenario is ignored.
    final button = tester.widget<IconButton>(
      find.byKey(ValueKey('tagRowActivate-${tag.id}')),
    );
    expect(button.onPressed, isNotNull);
  });

  testWidgets('the operator is freely editable after the prefill',
      (tester) async {
    await pumpSheet(tester, initialCommand: '+');
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '');
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.controller?.text, '');
  });

  testWidgets('an invalid submit clears the digits and keeps the operator',
      (tester) async {
    await pumpSheet(tester, initialCommand: '+');
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '+.');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('至少输入一个 tag 序号'), findsOneWidget);

    // The line is cleared for a fresh attempt, but the operator the shortcut
    // pre-selected survives — only the unusable digits are dropped.
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.controller?.text, '+');
  });

  testWidgets('an invalid submit with no operator clears the whole line',
      (tester) async {
    await pumpSheet(tester);
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '42');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    final field = tester.widget<TextField>(
      find.byKey(const ValueKey('tagInputField')),
    );
    expect(field.controller?.text, '');
  });

  testWidgets('typing after an error clears the message', (tester) async {
    await pumpSheet(tester, initialCommand: '+');
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '+.');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(find.text('至少输入一个 tag 序号'), findsOneWidget);

    await tester.enterText(find.byKey(const ValueKey('tagInputField')), '+1');
    await tester.pumpAndSettle();
    expect(find.text('至少输入一个 tag 序号'), findsNothing);
  });

  testWidgets('desktop: focusing must NOT select the prefilled operator',
      (tester) async {
    // EditableText.selectAllOnFocus defaults to TRUE on Windows/desktop and
    // false elsewhere; flutter_test's default platform is android, so the
    // desktop behavior only reproduces under an explicit override. Reset it in
    // a finally: the binding asserts foundation debug vars are unset before
    // its own teardown runs.
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    try {
      await pumpViaPopup(tester, initialCommand: '+');
      expect(tester.takeException(), isNull);

      final field = tester.widget<TextField>(
        find.byKey(const ValueKey('tagInputField')),
      );
      // A caret at the end lets the next keystroke APPEND ('+' → '+1'); a
      // select-all would make it overwrite the operator ('+' → '1').
      expect(field.controller?.selection.isCollapsed, isTrue);
      expect(field.controller?.selection.baseOffset, 1);
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  testWidgets('closing the hint banner can hide it permanently',
      (tester) async {
    await pumpSheet(tester);
    expect(find.byKey(const ValueKey('tagInputHintBanner')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tagInputHintClose')));
    await tester.pumpAndSettle();
    expect(find.text('关闭此提示？'), findsOneWidget);

    await tester.tap(find.text('不再显示'));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputHintBanner')), findsNothing);
    expect(useTagPlayStore().state.inputHintEnabled, isFalse);
  });

  testWidgets('closing the hint banner for this session keeps it persisted',
      (tester) async {
    await pumpSheet(tester);
    await tester.tap(find.byKey(const ValueKey('tagInputHintClose')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('仅本次'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('tagInputHintBanner')), findsNothing);
    expect(TagPlayStore.sessionHintHidden, isTrue);
    // Not persisted: the setting stays on, so the next launch shows it again.
    expect(useTagPlayStore().state.inputHintEnabled, isTrue);
  });

  // ── Desktop-only chrome stays off phones ──

  testWidgets('the hint banner stays hidden on phones, bar opted out',
      (tester) async {
    // The banner advertises the desktop `*/+-` command grammar; a phone
    // without the opt-in command bar must never see it.
    debugIsMobilePlatformOverride = true;
    try {
      await pumpSheet(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tagInputHintBanner')), findsNothing);
    } finally {
      debugIsMobilePlatformOverride = null;
    }
  });

  testWidgets('the hint banner stays hidden on phones, bar opted in',
      (tester) async {
    // A phone with the opt-in command bar types commands on a software
    // keyboard, so the hardware-key banner is still wrong there.
    debugIsMobilePlatformOverride = true;
    try {
      await useTagPlayStore().setInputBarEnabled(true);
      await pumpSheet(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tagInputField')), findsOneWidget);
      expect(find.byKey(const ValueKey('tagInputHintBanner')), findsNothing);
    } finally {
      debugIsMobilePlatformOverride = null;
    }
  });

  testWidgets('desktop keeps the Escape hint on the close button',
      (tester) async {
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    final close = tester.widget<IconButton>(
      find.byKey(const ValueKey('tagSheetClose')),
    );
    expect(close.tooltip, '关闭（Esc）');
  });

  testWidgets('the close button tooltip drops the Escape hint on phones',
      (tester) async {
    debugIsMobilePlatformOverride = true;
    try {
      await pumpSheet(tester);
      expect(tester.takeException(), isNull);
      final close = tester.widget<IconButton>(
        find.byKey(const ValueKey('tagSheetClose')),
      );
      expect(close.tooltip, '关闭');
    } finally {
      debugIsMobilePlatformOverride = null;
    }
  });

  // ── Auto-close after a shortcut command (desktop only) ──

  /// Submits [text] from the command bar and lets the outcome settle.
  Future<void> submitText(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('tagInputField')), text);
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
  }

  testWidgets('the auto-close checkbox shows on desktop, default off',
      (tester) async {
    await pumpSheet(tester);
    expect(tester.takeException(), isNull);
    final toggle = tester.widget<CheckboxListTile>(
      find.byKey(const ValueKey('tagAutoCloseToggle')),
    );
    expect(toggle.value, isFalse);
  });

  testWidgets('the auto-close checkbox is hidden on phones', (tester) async {
    // `isDesktop` is a compile-time constant on the test host; the mobile
    // branch is only reachable through the runtime interaction seam. Reset it
    // inside the body — the binding asserts debug vars are unset before its own
    // teardown runs, so addTearDown would be too late.
    debugIsMobilePlatformOverride = true;
    try {
      await pumpSheet(tester);
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('tagAutoCloseToggle')), findsNothing);
    } finally {
      debugIsMobilePlatformOverride = null;
    }
  });

  testWidgets('toggling the auto-close checkbox persists the preference',
      (tester) async {
    await pumpSheet(tester);
    final toggle = find.byKey(const ValueKey('tagAutoCloseToggle'));
    // The sheet is a short phone-sized popup; the row may sit below the fold.
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(useTagPlayStore().state.autoCloseOnSubmit, isTrue);
  });

  testWidgets('a shortcut command closes the sheet when auto-close is on',
      (tester) async {
    await useTagPlayStore().setAutoCloseOnSubmit(true);
    await pumpViaPopup(
      tester,
      initialCommand: '+',
      openViaShortcut: true,
    );
    await submitText(tester, '*0');
    expect(tester.takeException(), isNull);
    // The whole point: the user does not have to dismiss it by hand.
    expect(find.byKey(const ValueKey('tagInputField')), findsNothing);
  });

  testWidgets('a shortcut command stays open when auto-close is off',
      (tester) async {
    await pumpViaPopup(
      tester,
      initialCommand: '+',
      openViaShortcut: true,
    );
    await submitText(tester, '*0');
    expect(tester.takeException(), isNull);
    // Default off → unchanged multi-shot behavior.
    expect(find.byKey(const ValueKey('tagInputField')), findsOneWidget);
  });

  testWidgets('a More-menu command never auto-closes, even with the option on',
      (tester) async {
    await useTagPlayStore().setAutoCloseOnSubmit(true);
    await pumpViaPopup(tester);
    await submitText(tester, '*0');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputField')), findsOneWidget);
  });

  testWidgets('a failed shortcut command keeps the sheet open with the option on',
      (tester) async {
    await useTagPlayStore().setAutoCloseOnSubmit(true);
    await pumpViaPopup(
      tester,
      initialCommand: '+',
      openViaShortcut: true,
    );
    await submitText(tester, '+.');
    expect(tester.takeException(), isNull);
    // The user must see why it failed and be able to fix the line.
    expect(find.byKey(const ValueKey('tagInputField')), findsOneWidget);
    expect(find.text('至少输入一个 tag 序号'), findsOneWidget);
  });

  // ── Production-path reproduction (real factory, UI toggle) ──

  /// Opens the sheet through the REAL [openTagPlaySheet] factory — the exact
  /// production wiring that derives `openViaShortcut` from `initialCommand`.
  Future<void> openViaFactory(WidgetTester tester, {String? initialCommand}) async {
    late BuildContext hostContext;
    await tester.pumpWidget(
      _storeScope(
        MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: Builder(
              builder: (context) {
                hostContext = context;
                return const SizedBox.shrink();
              },
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    unawaited(openTagPlaySheet(
      hostContext,
      initialCommand: initialCommand,
      // Skip the first-use command guide modal; this test exercises the sheet.
      showCommandGuide: false,
    ));
    await tester.pumpAndSettle();
  }

  testWidgets('REPRO: the toggle updates its own checkbox in the UI',
      (tester) async {
    await openViaFactory(tester, initialCommand: '+');
    final toggle = find.byKey(const ValueKey('tagAutoCloseToggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<CheckboxListTile>(toggle).value, isFalse);

    await tester.tap(toggle);
    await tester.pumpAndSettle();

    // The visible control must reflect the new preference, not just the store.
    expect(useTagPlayStore().state.autoCloseOnSubmit, isTrue);
    expect(tester.widget<CheckboxListTile>(toggle).value, isTrue);
  });

  testWidgets('REPRO: real shortcut door + UI-enabled toggle closes on Enter',
      (tester) async {
    await openViaFactory(tester, initialCommand: '+');

    final toggle = find.byKey(const ValueKey('tagAutoCloseToggle'));
    await tester.ensureVisible(toggle);
    await tester.pumpAndSettle();
    await tester.tap(toggle);
    await tester.pumpAndSettle();

    await submitText(tester, '*0');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputField')), findsNothing);
  });

  testWidgets('the sheet exposes an explicit X close button', (tester) async {
    await openViaFactory(tester, initialCommand: '+');
    final close = find.byKey(const ValueKey('tagSheetClose'));
    expect(close, findsOneWidget);

    await tester.tap(close);
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('tagInputField')), findsNothing);
    expect(find.byKey(const ValueKey('tagSheetClose')), findsNothing);
  });
}
