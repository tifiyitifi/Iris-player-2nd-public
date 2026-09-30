import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/hooks/use_gesture_mode.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:provider/provider.dart';
import 'package:zustand/zustand.dart';

/// StoreScope-equivalent that does NOT dispose the global StoreLocator on
/// unmount (mirrors gesture_guide_overlay_test.providerScope).
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    useAppStore();
    await useAppStore().initialized;
  });

  tearDown(() async {
    useAppStore()
        .set(useAppStore().state.copyWith(useMetadataSettings: false));
  });

  // Regression for the phone bug: the old overlay cached gestureMode in a
  // useMemoized keyed on [profiles, orientation, isMobile]. The async store
  // load flipped useMetadataSettings AFTER the first frame, but none of the
  // keys changed — so phones stayed on the classic engine (no Tag regions)
  // until an orientation flip happened to force a recompute. The hook must
  // resolve the verdict from the CURRENT state on every build.
  testWidgets(
      'gesture mode flips classic -> region when the meta gate lands (no remount)',
      (tester) async {
    GestureMode? captured;
    // Forced rebuild valve: flutter_zustand's select()→rebuild chain does not
    // deliver under the widget-test FakeAsync zone (probe-verified in the
    // guide tests), so the subtree is rebuilt explicitly after the flip. The
    // memoized implementation would STILL return classic here — its keys
    // never changed — while the per-build hook resolves region.
    final rebuild = ValueNotifier(0);

    // Install default is gate ON — this test pins the OFF→ON flip, so seed
    // OFF before the first frame.
    useAppStore().set(useAppStore().state.copyWith(useMetadataSettings: false));

    await tester.pumpWidget(providerScope(MaterialApp(
      home: ValueListenableBuilder<int>(
        valueListenable: rebuild,
        builder: (_, __, ___) => Scaffold(
          body: HookBuilder(
            builder: (context) {
              captured = useGestureMode(
                orientation: Orientation.landscape,
                isPhone: true,
              );
              return const SizedBox.shrink();
            },
          ),
        ),
      ),
    )));

    expect(captured, GestureMode.classic,
        reason: 'gate OFF (default state) must resolve classic on a phone');

    // Pin the region profile explicitly: this case pins the classic → region
    // flip itself, not whatever profile a fresh install defaults to.
    useAppStore().set(useAppStore().state.copyWith(
          useMetadataSettings: true,
          landscapeGestureProfile: LandscapeGestureProfile.region,
        ));
    rebuild.value++;
    await tester.pump();

    expect(captured, GestureMode.region,
        reason: 'the verdict must follow the live gate — no restart, no '
            'orientation flip');

    // And back: turning the gate OFF returns to classic immediately.
    useAppStore()
        .set(useAppStore().state.copyWith(useMetadataSettings: false));
    rebuild.value++;
    await tester.pump();

    expect(captured, GestureMode.classic);
  });
}
