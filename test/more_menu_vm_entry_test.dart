import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/globals.dart' show moreMenuKeyNotifier;
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/more_menu_button.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// StoreScope-equivalent that does NOT dispose the global StoreLocator on
/// unmount (mirrors more_menu_rate_fallback_test.providerScope).
Widget providerScope(Widget child) {
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

MediaPlayer _player() {
  return MediaPlayer(
    isInitializing: false,
    isPlaying: false,
    externalSubtitles: const [],
    position: Duration.zero,
    duration: const Duration(minutes: 1),
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
}

/// The Virtual Media manager door belongs to the live More menu and must
/// follow the feature gate (metadata stack on, drift storage).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  late AppState original;

  setUp(() {
    debugIsMobilePlatformOverride = true;
    original = useAppStore().state;
  });

  tearDown(() {
    useAppStore().set(original);
    debugIsMobilePlatformOverride = null;
  });

  void configure({required bool gate}) {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: gate,
          useLegacyStoragePersistence: false,
          runtimeOrientation: ScreenOrientation.device,
        ));
  }

  Future<void> openMoreMenu(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1400, 800);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(providerScope(
      Provider<MediaPlayer>.value(
        value: _player(),
        child: MaterialApp(
          locale: const Locale('zh'),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(
            body: MoreMenuButton(
              showControl: () {},
              showControlForHover: (f) async => await f,
            ),
          ),
        ),
      ),
    ));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(moreMenuKeyNotifier.value!));
    await tester.pumpAndSettle();
  }

  testWidgets('gate ON exposes the virtual media manager entry',
      (tester) async {
    configure(gate: true);
    await openMoreMenu(tester);

    expect(find.text('虚拟媒体'), findsOneWidget);
  });

  testWidgets('gate OFF hides the virtual media manager entry', (tester) async {
    configure(gate: false);
    await openMoreMenu(tester);

    expect(find.text('虚拟媒体'), findsNothing);
  });
}
