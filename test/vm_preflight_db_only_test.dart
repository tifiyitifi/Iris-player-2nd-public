import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/service/vm_preflight_coordinator.dart';
import 'package:iris/l10n/app_localizations.dart';

VirtualSegment seg(String name, {int? durationMs}) {
  return VirtualSegment(
    mediaKey: 'st1:Shorts/$name',
    storageId: 'st1',
    path: ['Shorts', name],
    name: name,
    parentPath: 'Shorts',
    durationMs: durationMs,
  );
}

VirtualMediaItem group(List<VirtualSegment> segs) {
  return VirtualMediaItem(
    ruleId: 'r1',
    scopeKey: 'r1|Shorts|#1',
    rootPath: 'Shorts',
    displayIndex: 1,
    displayName: 'item',
    segments: segs,
  );
}

MediaNode fileNode(String name, {int? durationMs}) {
  return MediaNode.file(
    id: 'n-$name',
    storageId: 'st1',
    path: ['Shorts', name],
    name: name,
    mediaType: MediaType.video,
    durationMs: durationMs,
  );
}

class CountingProbe implements MediaProbeService {
  int calls = 0;

  @override
  Future<ProbeResult> probeFile(String target) async {
    calls++;
    return const ProbeResult(durationMs: 60000);
  }

  @override
  Future<List<ProbeResult>> probeFiles(List<String> targets) async {
    calls += targets.length;
    return List.filled(targets.length, const ProbeResult(durationMs: 60000));
  }
}

Future<NavigatorState> pumpNavigator(WidgetTester tester) async {
  late NavigatorState navigator;
  await tester.pumpWidget(MaterialApp(
    locale: const Locale('zh'),
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Builder(builder: (context) {
      navigator = Navigator.of(context);
      return const Scaffold(body: Text('home'));
    }),
  ));
  await tester.pumpAndSettle();
  return navigator;
}

void main() {
  test('verify is DB-only: never touches the probe service', () async {
    final probe = CountingProbe();
    final outcome = await verifyVmGroupForPlayback(
      group([seg('1.mp4'), seg('2.mp4')]),
      probeService: probe,
      nodeReader: (s) async => fileNode(s.name, durationMs: 60000),
    );
    expect(outcome.ok, isTrue);
    expect(probe.calls, 0);
  });

  test('verify marks DB-unknown durations without probing', () async {
    final probe = CountingProbe();
    final outcome = await verifyVmGroupForPlayback(
      group([seg('1.mp4'), seg('bad.mp4')]),
      probeService: probe,
      nodeReader: (s) async =>
          s.name == 'bad.mp4' ? fileNode(s.name) : fileNode(s.name, durationMs: 1000),
    );
    expect(outcome.ok, isFalse);
    expect(probe.calls, 0);
    expect(outcome.extraFail.keys, contains('st1:Shorts/bad.mp4'));
  });

  test('verify honours cancellation and reports cancelled', () async {
    final outcome = await verifyVmGroupForPlayback(
      group([seg('1.mp4'), seg('2.mp4'), seg('3.mp4')]),
      nodeReader: (s) async {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        return fileNode(s.name, durationMs: 60000);
      },
      shouldCancel: () => true,
    );
    expect(outcome.cancelled, isTrue);
    expect(outcome.ok, isFalse);
  });

  testWidgets('preflight progress dialog has a cancel action', (tester) async {
    final navigator = await pumpNavigator(tester);
    final g = group([seg('1.mp4'), seg('2.mp4')]);
    final future = verifyWithProgressDialog(
      navigator,
      g,
      (onProgress, isCancelled) async {
        for (var i = 0; i < 100 && !isCancelled(); i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
        return VmVerifyOutcome(
          ok: false,
          extraFail: const {},
          elapsed: Duration.zero,
          cancelled: isCancelled(),
        );
      },
    );
    await tester.pumpAndSettle();
    expect(find.text('虚拟合播预检'), findsOneWidget);
    // Cancel must exist (aborts the whole playback, not fallback).
    expect(find.text('取消播放'), findsOneWidget);
    await tester.tap(find.text('取消播放'));
    await tester.pumpAndSettle();
    final outcome = await future;
    expect(outcome.cancelled, isTrue);
    expect(find.text('home'), findsOneWidget);
  });
}
