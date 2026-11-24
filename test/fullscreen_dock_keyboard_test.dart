import 'dart:ui' show KeyEventDeviceType;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';
import 'package:iris/hooks/use_keyboard.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/player.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/player_ui_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// The DEFAULT desktop scheme is `potplayer`, which routes keys through
/// `PotPlayerKeyExecutor` — not the legacy switch. In picture fullscreen the
/// queue is a transient overlay, so its queue key (F6) and Esc there must act
/// on THAT panel and never on the persisted windowed dock flag (DOCK-13).
Widget _harness({required Widget Function(BuildContext) builder}) {
  return InheritedProvider<StoreLocator>.value(
    value: StoreLocator(),
    startListening: (InheritedContext<StoreLocator?> e, StoreLocator value) {
      final sub = value.changes.listen((_) => e.markNeedsNotifyDependents());
      return sub.cancel;
    },
    lazy: false,
    child: Provider<MediaPlayer>.value(
      value: _player(),
      child: MaterialApp(
        locale: const Locale('en'),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: Builder(builder: builder)),
      ),
    ),
  );
}

MediaPlayer _player() => MediaPlayer(
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close());

  setUp(() {
    final app = useAppStore();
    app.set(app.state.copyWith(
      useMetadataSettings: true,
      useLegacyStoragePersistence: false,
      keyboardShortcutScheme: KeyboardShortcutScheme.potplayer,
      playlistPanelMode: PlaylistPanelMode.dockedRight,
      playlistPanelVisible: false,
    ));
    usePlayerUiStore().set(
      const PlayerUiState(isFullScreen: true, isShowControl: false),
    );
    useScreenLockStore().unlock();
  });

  Future<KeyboardEvent> pumpHarness(WidgetTester tester) async {
    late KeyboardEvent handler;
    await tester.pumpWidget(_harness(
      builder: (context) => HookBuilder(builder: (context) {
        handler = useKeyboard(
          showControl: () {},
          showControlForHover: (future) => future,
          showProgress: () {},
        );
        return const SizedBox.shrink();
      }),
    ));
    await tester.pumpAndSettle();
    return handler;
  }

  PhysicalKeyboardKey physicalOf(LogicalKeyboardKey key) => switch (key) {
        LogicalKeyboardKey.escape => PhysicalKeyboardKey.escape,
        LogicalKeyboardKey.f6 => PhysicalKeyboardKey.f6,
        _ => PhysicalKeyboardKey.f6,
      };

  KeyEvent down(LogicalKeyboardKey key) => KeyDownEvent(
        deviceType: KeyEventDeviceType.keyboard,
        logicalKey: key,
        physicalKey: physicalOf(key),
        timeStamp: Duration.zero,
      );

  testWidgets('the queue key toggles the transient overlay, not the dock flag',
      (tester) async {
    final handler = await pumpHarness(tester);
    usePlayerUiStore().hideFullscreenDock();
    await tester.pump();
    final bool windowedBefore = useAppStore().state.playlistPanelVisible;

    handler(down(LogicalKeyboardKey.f6));
    await tester.pump();
    expect(usePlayerUiStore().isFullscreenDockShown, isTrue,
        reason: 'F6 reveals the picture-fullscreen queue');

    handler(down(LogicalKeyboardKey.f6));
    await tester.pump();
    expect(usePlayerUiStore().isFullscreenDockShown, isFalse,
        reason: 'the same key conceals it again — transient, not sticky');
    expect(useAppStore().state.playlistPanelVisible, windowedBefore,
        reason: 'picture fullscreen must not rewrite the windowed dock flag');
  });

  testWidgets('Esc closes the shown overlay before leaving fullscreen',
      (tester) async {
    final handler = await pumpHarness(tester);
    usePlayerUiStore().showFullscreenDock();
    await tester.pump();

    handler(down(LogicalKeyboardKey.escape));
    await tester.pump();

    expect(usePlayerUiStore().isFullscreenDockShown, isFalse,
        reason: 'Esc is spent closing the panel');
    expect(usePlayerUiStore().state.isFullScreen, isTrue,
        reason: 'the panel closes first; fullscreen is left by a second Esc');
  });
}
