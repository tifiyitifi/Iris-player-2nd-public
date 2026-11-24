import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';
import 'package:iris/models/player.dart';
import 'package:iris/pages/player/video_view.dart';
import 'package:provider/provider.dart';
// Test-only StoreLocator host (see pubspec dev_dependencies comment).
import 'package:zustand/zustand.dart';

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
  late MediaPlayer player;

  setUp(() {
    useVideoTransformStore().resetAll();
    // The store is a process-wide singleton; drop the media tracker so each
    // case starts from "no media reported yet".
    useVideoTransformStore().forgetMediaKey();
    player = MediaPlayer(
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
  });

  Future<void> pumpView(WidgetTester tester, {String? mediaKey}) async {
    await tester.pumpWidget(providerScope(
      Provider<MediaPlayer>.value(
        value: player,
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 320,
                height: 180,
                child: VideoView(fit: BoxFit.contain, mediaKey: mediaKey),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  Finder mirrorTransform() => find.byWidgetPredicate(
        (Widget w) =>
            w is Transform &&
            (w.transform.storage[0] == -1 || w.transform.storage[5] == -1),
      );

  testWidgets('video view leaves the surface untouched when neutral',
      (tester) async {
    await pumpView(tester);

    expect(find.byType(RotatedBox), findsNothing);
    expect(mirrorTransform(), findsNothing);
  });

  testWidgets('video view applies a RotatedBox for quarter-turn rotation',
      (tester) async {
    useVideoTransformStore().setRotation(VideoRotation.cw90);
    await pumpView(tester);

    final RotatedBox rotated = tester.widget<RotatedBox>(
      find.byType(RotatedBox),
    );
    expect(rotated.quarterTurns, 1);
    expect(mirrorTransform(), findsNothing);
  });

  testWidgets('video view applies a mirror Transform only when flipped',
      (tester) async {
    useVideoTransformStore().setFlipHorizontal(true);
    await pumpView(tester);

    expect(find.byType(RotatedBox), findsNothing);
    expect(mirrorTransform(), findsOneWidget);
  });

  testWidgets('changing the media resets the adjustment', (tester) async {
    await pumpView(tester, mediaKey: 'a');
    useVideoTransformStore().setFlipHorizontal(true);
    expect(useVideoTransformStore().state.flipHorizontal, isTrue);

    // The next media must start from the untouched picture. Assert the store,
    // because the select -> rebuild chain does not deliver under the
    // widget-test FakeAsync zone (see video_transform_panel_test).
    await pumpView(tester, mediaKey: 'b');
    await tester.pump();
    expect(useVideoTransformStore().state.isNeutral, isTrue);
  });

  testWidgets('a media change while the surface is unmounted still resets',
      (tester) async {
    useVideoTransformStore().setRotation(VideoRotation.cw90);
    await pumpView(tester, mediaKey: 'a');
    expect(useVideoTransformStore().state.rotation, VideoRotation.cw90);

    // A backend switch unmounts the surface; a media that changed meanwhile
    // must not leak its transform into the new file.
    await tester.pumpWidget(const SizedBox());
    await pumpView(tester, mediaKey: 'b');
    await tester.pump();
    expect(useVideoTransformStore().state.isNeutral, isTrue);
  });

  testWidgets('a surface remount keeps the adjustment for the same media',
      (tester) async {
    useVideoTransformStore().setRotation(VideoRotation.cw90);
    await pumpView(tester, mediaKey: 'a');
    expect(find.byType(RotatedBox), findsOneWidget);

    // Re-reporting the SAME key after an unmount must not reset.
    await tester.pumpWidget(const SizedBox());
    await pumpView(tester, mediaKey: 'a');
    expect(useVideoTransformStore().state.rotation, VideoRotation.cw90);
  });

  testWidgets('a null media gap does not drop the adjustment', (tester) async {
    useVideoTransformStore().setRotation(VideoRotation.cw90);
    await pumpView(tester, mediaKey: 'a');
    expect(useVideoTransformStore().state.rotation, VideoRotation.cw90);

    // A stop / queue rebuild reports "no media" before the same file returns.
    await pumpView(tester, mediaKey: null);
    expect(useVideoTransformStore().state.rotation, VideoRotation.cw90);

    await pumpView(tester, mediaKey: 'a');
    expect(useVideoTransformStore().state.rotation, VideoRotation.cw90);
  });
}
