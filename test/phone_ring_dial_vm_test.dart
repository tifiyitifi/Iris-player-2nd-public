import 'dart:typed_data';
import 'dart:ui' show ImageByteFormat;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/phone/one_handed_scrubber/view/phone_ring_dial_scrubber.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/models/player.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:provider/provider.dart';

/// Guards the VM-specific dial painting path: the equal-arc chunk ring, the
/// per-file progress ring and the numeric gap labels must all rebuild without
/// throwing while a virtual session is active, and an outer-ring tap must
/// route through an existing seek without error.
///
/// Also pins the segment-tick EXTENT contract. Regression: the chunk-ring
/// painter hardcoded a +/-9px tick and never received `vmMarkTickExtent`, so the
/// length setting silently did nothing on the phone dial even though it worked
/// on the linear and circle sliders — colour changed, length never did.
///
/// NOTE: `useVmPlaybackStore()` is created through the global `StoreLocator`,
/// which `StoreScope.dispose()` tears down asynchronously. A second test in
/// this file therefore cannot re-acquire a live VM store, so the VM-dependent
/// assertions all live in the single test below.
void main() {
  VirtualSegment seg(String path,
      {int? durationMs, bool estimated = false}) {
    final parts = path.split('/');
    return VirtualSegment(
      mediaKey: 'st1:$path',
      storageId: 'st1',
      path: parts,
      name: parts.last,
      parentPath:
          parts.length <= 1 ? '' : parts.sublist(0, parts.length - 1).join('/'),
      durationMs: durationMs,
      durationEstimated: estimated,
    );
  }

  VirtualMediaItem vmItemOf(List<VirtualSegment> segments) => VirtualMediaItem(
        ruleId: 'r',
        scopeKey: 'r|k|1',
        rootPath: 'k',
        displayIndex: 1,
        displayName: 'k',
        segments: segments,
      );

  /// Mounts the dial with a fixed clock so successive renders are comparable
  /// pixel-for-pixel. [vmDialCapture] is the RepaintBoundary the pixel
  /// assertions sample.
  Future<void> pumpDial(
    WidgetTester tester, {
    Duration position = const Duration(milliseconds: 500),
    Duration duration = const Duration(milliseconds: 3000),
  }) async {
    await tester.pumpWidget(StoreScope(
      child: Provider<MediaPlayer>.value(
        value: MediaPlayer(
          isInitializing: false,
          isPlaying: false,
          externalSubtitles: const [],
          position: position,
          duration: duration,
          buffer: position,
          width: 16,
          height: 9,
          saveProgress: () async {},
          play: () async {},
          pause: () async {},
          backward: (int s) async {},
          forward: (int s) async {},
          stepBackward: () async {},
          stepForward: () async {},
          seek: (Duration t) async {},
        ),
        child: MaterialApp(
          home: Scaffold(
            body: Center(
              child: RepaintBoundary(
                key: const ValueKey('vmDialCapture'),
                child: SizedBox(
                  width: 240,
                  height: 210,
                  child: PhoneRingDialScrubber(
                    showControl: () {},
                    color: Colors.white,
                    isLeftHanded: false,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
  }

  testWidgets(
      'VM dial paints equal-arc ring + labels, and the tick extent reaches the '
      'pixels', (tester) async {
    final item = vmItemOf([
      seg('k/1.mp4', durationMs: 1000),
      seg('k/2.mp4', durationMs: 2000),
      seg('k/3.mp4', durationMs: 500, estimated: true),
    ]);
    // 3 segments, total 3500ms.
    useVmPlaybackStore().replace(
      VmPlaybackState(
        item: item,
        segmentIndex: 1,
        queue: [item],
        queueIndex: 0,
      ),
    );

    Future<Uint8List> renderAt(int extent) async {
      useAppStore().set(useAppStore().state.copyWith(vmMarkTickExtent: extent));
      await pumpDial(
        tester,
        position: const Duration(milliseconds: 1500), // inside segment 1
        duration: Duration(milliseconds: item.totalDurationMs),
      );
      expect(tester.takeException(), isNull,
          reason: 'VM equal-arc ring + gap labels must paint cleanly');
      expect(find.byType(PhoneRingDialScrubber), findsOneWidget);
      final boundary = tester.renderObject<RenderRepaintBoundary>(
          find.byKey(const ValueKey('vmDialCapture')));
      // toImage completes on the raster thread, which the fake-async test zone
      // never pumps — without runAsync this await hangs forever.
      return (await tester.runAsync(() async {
        final image = await boundary.toImage(pixelRatio: 1.0);
        final data = await image.toByteData(format: ImageByteFormat.rawRgba);
        image.dispose();
        return data!.buffer.asUint8List();
      }))!;
    }

    // Control: the SAME setting twice must repaint byte-identically. Without
    // this the dial could be time-dependent and the difference asserted below
    // would not actually be attributable to the tick.
    final narrow1 = await renderAt(4);
    final narrow2 = await renderAt(4);
    expect(narrow2, orderedEquals(narrow1),
        reason: 'control: an unchanged setting must repaint identically');

    // The actual regression guard: a longer tick must paint differently.
    final wide = await renderAt(12);
    expect(wide, isNot(orderedEquals(narrow1)),
        reason: 'a 4px -> 12px tick must change what the dial paints');
  });

  testWidgets('dial painter takes the tick extent from the store',
      (tester) async {
    // The store -> painter half of the wiring. The extent is threaded
    // unconditionally (no VM session needed), and the field is public on a
    // private class, so `dynamic` reads it without widening the widget's API.
    int paintedExtent() {
      final paint = tester.widget<CustomPaint>(
          find.byKey(const ValueKey('vmDialPaint')));
      return (paint.painter as dynamic).vmTickExtent as int;
    }

    for (final extent in <int>[4, 12]) {
      useAppStore().set(useAppStore().state.copyWith(vmMarkTickExtent: extent));
      await pumpDial(tester);
      expect(tester.takeException(), isNull,
          reason: 'dial must paint cleanly at extent $extent');
      expect(paintedExtent(), extent,
          reason: 'painter must carry the stored extent, not a constant');
    }
  });
}
