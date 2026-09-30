import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_scope_dialog.dart';
import 'package:iris/features/background_playback/view/bg_quick_panel_host.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

final FileItem _fgFile =
    FileItem(name: 'fg.mp4', uri: 'file:///fg.mp4', path: ['fg.mp4']);

/// The 作用范围 picker shared by the quick bar and the 副音 menu. Since the
/// 4th-round rework it is a NON-MODAL draggable card hosted in the player
/// Stack, so the test renders the host too.
Widget _harness() {
  return InheritedProvider<StoreLocator>.value(
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
      home: Scaffold(
        body: Stack(
          children: [
            const BgQuickPanelHost(),
            Align(
              alignment: Alignment.topLeft,
              child: Builder(
                builder: (context) => ElevatedButton(
                  onPressed: () => showBackgroundScopeDialog(context),
                  child: const Text('open'),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUp(() {
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          useLegacyStoragePersistence: false,
        ));
  });

  tearDown(() => StoreLocator().delete(BackgroundPlaybackStore));
  // (the play-queue singleton is app-wide; it is only read here)

  testWidgets('shows the three scopes with the current one selected',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: true));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('bg_quick_panel')), findsOneWidget);
    expect(find.text('Scope'), findsOneWidget);
    expect(find.text('This video'), findsOneWidget);
    expect(find.text('Smart'), findsOneWidget);
    expect(find.text('All videos'), findsOneWidget);
    expect(find.text('Keep across restarts'), findsOneWidget);
    // Non-modal: every barrier is transparent, so no scrim dims the video.
    final barriers = tester.widgetList<ModalBarrier>(find.byType(ModalBarrier));
    expect(barriers.every((b) => b.color == null), isTrue,
        reason: 'a modal scrim would dim the video');
    // The scope description for the current selection is visible.
    expect(
      find.textContaining('Only the video playing now uses Sub Audio'),
      findsOneWidget,
    );
  });

  testWidgets('switching 全部 → 仅当前 re-anchors the live run to this media',
      (tester) async {
    // 「全部」 carries NO anchor by design, so a run started under it has none.
    // Picking 仅当前 means "from now on only the media on screen", which is
    // exactly an anchor on the current media — without it the pair would read
    // as out of scope until the gate was re-opened.
    final pq = usePlayQueueStore();
    await pq.initialized;
    await pq.update(
      playQueue: [PlayQueueItem(file: _fgFile, index: 0)],
      index: 0,
    );
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(
      enabled: true,
      gateOpen: true,
      applyScope: BgApplyScope.all,
      scopeAnchorKey: null,
    ));

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('This video'));
    await tester.pumpAndSettle();

    expect(bg.state.applyScope, BgApplyScope.currentOnly);
    expect(
      bg.state.scopeAnchorKey,
      canonicalProgressKey(_fgFile.storageId, _fgFile.path, uri: _fgFile.uri),
    );
  });

  testWidgets('picking a scope writes it; the checkbox toggles persistence',
      (tester) async {
    final bg = useBackgroundPlaybackStore();
    await bg.initialized;
    bg.set(bg.state.copyWith(enabled: true));
    expect(bg.state.applyScope, BgApplyScope.currentOnly);

    await tester.pumpWidget(_harness());
    await tester.pumpAndSettle();
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Smart'));
    await tester.pumpAndSettle();
    expect(bg.state.applyScope, BgApplyScope.smart);
    expect(
      find.textContaining('auto-play saved Sub Audio'),
      findsOneWidget,
    );

    expect(bg.state.scopePersist, isTrue);
    await tester.tap(find.text('Keep across restarts'));
    await tester.pumpAndSettle();
    expect(bg.state.scopePersist, isFalse);
  });
}
