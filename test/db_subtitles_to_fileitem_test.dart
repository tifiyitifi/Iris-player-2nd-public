import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/playback/scenario_playback_provider.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';

/// The last hop of the v50 subtitle plumbing: a DB-resolved node must reach the
/// player as a `FileItem` carrying the persisted associations. Without it the
/// track panel offers no external track even though the row knows them — the
/// exact "scenario/queue entry has no subtitles while the browse does" bug.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  setUp(() async {
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
  });

  const subs = <Subtitle>[
    Subtitle(
      name: 'Show.S01E01.zh-ru.ass',
      uri: 'http://h/Show.S01E01.zh-ru.ass',
    ),
    Subtitle(
      name: 'Show.S01E01.zh-ru.srt',
      uri: 'http://h/Show.S01E01.zh-ru.srt',
    ),
  ];

  test('scenario-resolved FileItem carries the persisted subtitles', () {
    final provider = ScenarioPlaybackProvider(store: usePlaybackScenarioStore());
    final node = MediaNode.file(
      id: 'st1:Show.S01E01.mp4',
      storageId: 'st1',
      path: const ['Show.S01E01.mp4'],
      name: 'Show.S01E01.mp4',
      mediaType: MediaType.video,
      subtitles: subs,
    );

    expect(provider.fileOf(node).subtitles, subs);
  });

  test('a node with UNKNOWN associations maps to an empty list', () {
    final provider = ScenarioPlaybackProvider(store: usePlaybackScenarioStore());
    final node = MediaNode.file(
      id: 'st1:a.mp4',
      storageId: 'st1',
      path: const ['a.mp4'],
      name: 'a.mp4',
      mediaType: MediaType.video,
    );

    expect(provider.fileOf(node).subtitles, isEmpty);
  });
}
