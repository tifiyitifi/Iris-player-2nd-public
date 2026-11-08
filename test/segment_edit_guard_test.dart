import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/model/domain/segment_edit_draft.dart';
import 'package:iris/features/background_playback/model/enum/mapping_action.dart';
import 'package:iris/features/background_playback/resolver/segment_span_math.dart';
import 'package:iris/features/background_playback/services/segment_edit_guard.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

SegmentEditDraft _draft() => const SegmentEditDraft(
      action: MappingAction.playMedia,
      span: SegmentSpan(fgStartMs: 10000, fgEndMs: 40000, bgOffsetMs: -10000),
      bgStorageId: 'local',
      bgPath: 'B.mp4',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  group('SegmentEditGuard transport freeze', () {
    // The guard reads the SINGLETON store (as production does), so the test
    // drives that same instance rather than a detached one.
    late BackgroundPlaybackStore store;

    setUp(() async {
      store = useBackgroundPlaybackStore();
      await store.initialized;
      store.exitSegmentEdit();
      await store.disable();
      await store.enableWithQueue([_f('a'), _f('b'), _f('c')]);
      store.set(store.state.copyWith(
        shuffle: false,
        queue: [_f('a'), _f('b'), _f('c')],
      ));
    });

    tearDown(() {
      store.exitSegmentEdit();
    });

    test('entering the editor freezes and pauses 副音', () {
      expect(SegmentEditGuard.transportFrozen, isFalse);
      store.enterSegmentEdit(_draft());
      expect(SegmentEditGuard.transportFrozen, isTrue);
      expect(store.state.segmentEditMode, isTrue);
      expect(store.state.bgAutoPlay, isFalse);
    });

    test('bg prev/next is a no-op while frozen', () async {
      store.enterSegmentEdit(_draft());
      final before = store.state.currentIndex;
      final moved = await store.step(forward: true);
      expect(moved, isFalse);
      expect(store.state.currentIndex, before);
    });

    test('fg end-of-media is reported handled (pause) while frozen', () async {
      store.enterSegmentEdit(_draft());
      final result = await PlaybackProviderRegistry.advanceOnComplete(Repeat.all);
      expect(result.handled, isTrue);
      // Handled but nothing advanced: the caller must release its per-item tail
      // latch, otherwise the finished media can never be stepped again.
      expect(result.advanced, isFalse);
    });

    test('exiting the editor restores transport', () async {
      store.enterSegmentEdit(_draft());
      store.exitSegmentEdit();
      expect(SegmentEditGuard.transportFrozen, isFalse);
      expect(store.state.segmentEditDraft, isNull);
      // The queue steps again.
      final before = store.state.currentIndex;
      await store.step(forward: true);
      expect(store.state.currentIndex, isNot(before));
    });

    test('disable() clears the editor session', () async {
      store.enterSegmentEdit(_draft());
      await store.disable();
      expect(store.state.segmentEditMode, isFalse);
      expect(store.state.segmentEditDraft, isNull);
    });
  });
}
