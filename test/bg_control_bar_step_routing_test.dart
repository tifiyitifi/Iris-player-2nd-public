import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/controller/background_playback_router.dart';
import 'package:iris/features/background_playback/model/enum/control_target.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/next_previous_buttons.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

import 'helpers/sqlite3_loader.dart';

/// The shared control bar's prev/next buttons must hand a 副音 step to the
/// registered router, which is the ONE place that supplies the foreground
/// double-play guard (`excludedKey`) and the manual-switch mark
/// (`userInitiated`). Calling the background store directly let a step land on
/// the file the foreground was already playing — two engines on one file, and
/// the position mirror then dragged the video to the wrong place.
class _RecordingRouter implements BackgroundPlaybackRouter {
  bool target = true;
  final List<bool> steps = <bool>[];

  @override
  bool get targetIsBackground => target;

  @override
  Future<void> step({required bool forward}) async => steps.add(forward);

  @override
  Future<void> toggleShuffle() async {}

  @override
  Future<void> toggleRepeat() async {}

  @override
  Future<void> stop() async {}
}

Widget _scope(Widget child) => InheritedProvider<StoreLocator>.value(
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
        home: Scaffold(body: Center(child: child)),
      ),
    );

FileItem _f(String name) =>
    FileItem(name: name, uri: 'file:///$name', path: <String>[name]);

void _noop() {}

void main() {
  ensureSqlite3Loaded();
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  // Rendering the button resolves the queue total, which initializes the
  // scenario store and needs a live DB (as in production).
  late AppDatabase db;
  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
  });
  tearDownAll(() => db.close());

  tearDown(() {
    PlaybackProviderRegistry.registerBackgroundRouter(null);
    StoreLocator().delete(BackgroundPlaybackStore);
  });

  testWidgets('the control-bar next button routes a bg step through the router',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      controlTarget: ControlTarget.background,
      bgOutOfScope: false,
      bgExhausted: false,
      bgQueueEnded: false,
      queue: <FileItem>[_f('a'), _f('b')],
    ));
    final router = _RecordingRouter();
    PlaybackProviderRegistry.registerBackgroundRouter(router);

    expect(bg.state.bgOwnsControls, isTrue);
    expect(bg.state.queue.length, 2);

    await tester.pumpWidget(_scope(NextButton(showControl: _noop)));
    // The app's localizations load deferred: settle before the button body can
    // resolve its labels (otherwise MaterialApp renders the placeholder).
    await tester.pumpAndSettle();

    expect(find.byType(NextButton), findsOneWidget);
    await tester.tap(find.byIcon(Icons.skip_next_rounded));
    await tester.pump();

    expect(router.steps, <bool>[true],
        reason: 'the control bar must route through the router, which owns the '
            'foreground double-play guard and the user-switch mark');
  });

  testWidgets('the control-bar prev button routes a bg step through the router',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      controlTarget: ControlTarget.background,
      bgOutOfScope: false,
      bgExhausted: false,
      bgQueueEnded: false,
      queue: <FileItem>[_f('a'), _f('b')],
    ));
    final router = _RecordingRouter();
    PlaybackProviderRegistry.registerBackgroundRouter(router);

    expect(bg.state.bgOwnsControls, isTrue);
    expect(bg.state.queue.length, 2);

    await tester.pumpWidget(_scope(PrevButton(showControl: _noop)));
    await tester.pumpAndSettle();

    expect(find.byType(PrevButton), findsOneWidget);
    await tester.tap(find.byIcon(Icons.skip_previous_rounded));
    await tester.pump();

    expect(router.steps, <bool>[false],
        reason: 'prev must share the same router path as next, not a direct '
            'store call');
  });
}
