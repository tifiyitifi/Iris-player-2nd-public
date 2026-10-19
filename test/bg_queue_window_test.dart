import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/services/background_scenario_pool.dart';
import 'package:iris/features/background_playback/services/background_tag_pool.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/browser/paged_background_media_data_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart' show SortDirection;
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/model/domain/playback_occurrence_id.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_view_state.dart';
import 'package:iris/features/tag_play/model/enum/tag_play_sort_field.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

/// The 副音 queue is a WINDOW over its scenario, not the whole list: a huge list
/// must never be materialized. Step/jump walk the window and SLIDE it (resolve
/// the containing page) whenever the target index falls outside.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  late AppDatabase db;

  const int count = 450; // > one window (defaultCap 400)
  final names = [
    for (var i = 0; i < count; i++)
      'n${i.toString().padLeft(4, '0')}.mp4',
  ];

  String keyOf(String name) => canonicalKey('s1', ['Anime', name].join('/'));

  setUpAll(() async {
    db = AppDatabase(NativeDatabase.memory());
    await DbModule.init(db);
    await DbModule.scenarioRepo.ensureSystemPlayingScenario();
    usePlaybackScenarioStore();
    await usePlaybackScenarioStore().initialized;
    await usePlaybackScenarioStore().ensureReady();
    usePlayQueueStore();
    await usePlayQueueStore().initialized;
    useAppStore();
    await useAppStore().initialized;
    useStorageStore();
    await useStorageStore().initialized;
    useAppIdentityStore();
    useBackgroundPlaybackStore();

    for (final n in names) {
      await DbModule.mediaNodesDao.insertNode(MediaNode.file(
        id: 's1:Anime/$n',
        storageId: 's1',
        path: ['Anime', n],
        name: n,
        mediaType: MediaType.video,
      ));
    }
    final tags = await DbModule.tagPlayRepo.ensureReservedTags();
    final tagId = tags
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
    // Deterministic order for the window math: the 副音 view sorts by the
    // reserved tag's own view state (name asc here).
    await DbModule.tagPlayRepo.saveState(TagPlayViewState(
      tagId: tagId,
      sortField: TagPlaySortField.name,
      sortDirection: SortDirection.asc,
    ));
    // Membership order (addedAt desc) is deliberately the REVERSE of the name
    // asc view order, so the raw membership index and the resolved stream
    // position can never be confused (the H1 regression guard).
    for (var i = 0; i < names.length; i++) {
      await DbModule.tagPlayRepo.addMember(
        tagId: tagId,
        storageId: 's1',
        pathSegments: ['Anime', names[i]],
        at: DateTime.utc(2026, 1, 1).add(Duration(seconds: i)),
      );
    }
  });

  tearDownAll(() async {
    await db.close();
  });

  test('the pool resolves a window, not the whole list', () async {
    // Deterministic slice: 副音's default shuffle would permute the stream.
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false, shuffleSeed: 0));
    final window = await BackgroundScenarioPool.shared.window();
    expect(window.total, count);
    expect(window.files.length, BackgroundScenarioPool.defaultCap);
    expect(window.start, 0);
    expect(window.files.first.name, names.first);
  });

  test('a jump far outside the window slides onto it', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    await bg.enableWithQueue(
        (await BackgroundScenarioPool.shared.window()).files);
    expect(bg.state.queueWindowStart, 0);

    // The last item lives on the second page, so the window must slide.
    final last = count - 1;
    final outcome = await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    expect(outcome, BgJumpOutcome.jumped);
    expect(bg.state.queueWindowStart, 400);
    expect(bg.state.currentIndex, last - 400);
    expect(bg.currentFile!.name, names[last]);
  });

  test('step wraps across the window boundary and slides back', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false, bgRepeat: Repeat.all));
    await bg.enableWithQueue(
        (await BackgroundScenarioPool.shared.window()).files);

    final last = count - 1;
    await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    expect(bg.state.queueWindowStart, 400);

    // One more forward step wraps to global 0 -> the window slides back.
    expect(await bg.step(forward: true), isTrue);
    expect(bg.state.queueWindowStart, 0);
    expect(bg.state.currentIndex, 0);
    expect(bg.currentFile!.name, names.first);
  });

  test('enableWithQueue resumes a position beyond the first window', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));

    // Remember a position on the second page.
    final scenario = await ensureBackgroundPlaybackWorkspace();
    final last = count - 1;
    await usePlaybackScenarioStore().setCurrentItemFor(
      scenario.id,
      occurrence: PlaybackOccurrenceId(
        storageId: 's1',
        path: canonicalOccurrencePath(['Anime', names[last]].join('/')),
        occurrenceIndex: 0,
      ),
    );

    await bg.enableWithQueue(
      (await BackgroundScenarioPool.shared.window()).files,
      window: await BackgroundScenarioPool.shared.window(),
    );
    expect(bg.state.queueWindowStart, 400,
        reason: 'the window is centred on the remembered file');
    expect(bg.currentFile!.name, names[last]);
  });

  test('windowAt resolves the page that contains a global index', () async {
    final window = await BackgroundScenarioPool.shared.windowAt(420);
    expect(window.start, 400);
    expect(window.total, count);
    expect(window.files.first.name, names[400]);
  });

  test('window(around:) centres on the LIVE item and still reports the '
      'remembered key', () async {
    // A system move (lock rollover / tiled entrance) advances the queue without
    // writing an occurrence, so the reconcile must resolve the page around what
    // is playing — a page centred on the remembered item would slide the window
    // away from the current file.
    final scenario = await ensureBackgroundPlaybackWorkspace();
    final last = count - 1;
    await usePlaybackScenarioStore().setCurrentItemFor(
      scenario.id,
      occurrence: PlaybackOccurrenceId(
        storageId: 's1',
        path: canonicalOccurrencePath(['Anime', names[0]].join('/')),
        occurrenceIndex: 0,
      ),
    );

    final w = await BackgroundScenarioPool.shared.window(around: last);
    expect(w.start, 400, reason: 'the page follows the live index');
    expect(w.files.first.name, names[400]);
    expect(w.focusIndex, -1, reason: 'the remembered item is on another page');
    expect(w.focusKey, keyOf(names[0]),
        reason: 'the remembered key is still reported, for the preference list');
  });

  test('a lock rollover records the position for the next launch', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    await bg.enableWithQueue(
        (await BackgroundScenarioPool.shared.window()).files);

    await bg.requestLockTarget(index: 3, targetMs: 1000);

    final scenario = await ensureBackgroundPlaybackWorkspace();
    final occ = (await usePlaybackScenarioStore().getState(scenario.id))
        ?.currentPlaybackOccurrence;
    expect(occ, isNotNull,
        reason: 'a system move must update the recorded position');
    expect(occ!.storageId, 's1');
    expect(occ.path,
        canonicalOccurrencePath(['Anime', names[3]].join('/')));
  });

  test('openGate(stepForward) slides the window when it wraps', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false, bgRepeat: Repeat.all));
    await bg.enableWithQueue(
        (await BackgroundScenarioPool.shared.window()).files);

    final last = count - 1;
    await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    expect(bg.state.queueWindowStart, 400);
    bg.stopGate();

    // 下一首 re-activation wraps to global 0 -> the window slides back.
    await bg.openGate(mediaKey: 'fg', stepForward: true);
    expect(bg.state.gateOpen, isTrue);
    expect(bg.state.queueWindowStart, 0);
    expect(bg.state.currentIndex, 0);
    expect(bg.currentFile!.name, names.first);
  });

  test('two presses at a page boundary advance two tracks', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false, bgRepeat: Repeat.all));
    // The window must carry the real TOTAL, or the step candidates wrap inside
    // the page instead of sliding onto the next one.
    final firstPage = await BackgroundScenarioPool.shared.window();
    await bg.enableWithQueue(firstPage.files, window: firstPage);

    // Land on the last item of the first page so the next step must slide.
    await bg.jumpToOccurrence(
      virtualIndex: 399,
      mediaKey: keyOf(names[399]),
      userInitiated: true,
    );
    expect(bg.state.currentIndex, 399);
    expect(bg.state.queueWindowStart, 0);

    // Both presses are issued before either slide resolve lands: without the
    // move chain they resolve the SAME target and advance one track.
    final first = bg.step(forward: true);
    final second = bg.step(forward: true);
    await Future.wait([first, second]);

    expect(bg.state.queueWindowStart + bg.state.currentIndex, 401);
    expect(bg.currentFile!.name, names[401]);
  });

  test('a jump whose row no longer holds the tapped file is refused', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    final page = await BackgroundScenarioPool.shared.window();
    await bg.enableWithQueue(page.files, window: page);
    final before = bg.currentFile!.name;

    // The panel rendered row 5 for names[5]; between that resolve and the tap a
    // membership write shifted the stream, so index 5 now holds a neighbour. The
    // caller's mediaKey is the row it actually displayed, and playing a
    // different track because of a one-row shift is worse than refusing.
    final outcome = await bg.jumpToOccurrence(
      virtualIndex: 5,
      mediaKey: keyOf(names[6]),
    );

    expect(outcome, BgJumpOutcome.ignored);
    expect(bg.currentFile!.name, before, reason: 'the queue did not move');
  });

  test('openGate without stepForward keeps the loaded file', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    await bg.enableWithQueue(
        (await BackgroundScenarioPool.shared.window()).files);

    final last = count - 1;
    await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    bg.stopGate();

    await bg.openGate(mediaKey: 'fg');
    expect(bg.state.queueWindowStart, 400);
    expect(bg.state.currentIndex, last - 400);
    expect(bg.currentFile!.name, names[last]);
  });

  test('replaceQueue adopts the window offsets and keeps the window valid',
      () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    await bg.enableWithQueue(
        (await BackgroundScenarioPool.shared.window()).files);

    // Move the current file onto the second page, then reconcile onto THAT page
    // — the shape the append-mode growth folds into. The queue must adopt the
    // window offsets and stay a VALID window (no flat-list tail that step/jump
    // could not reach), which a bare `set(queue: appended)` could not promise.
    final last = count - 1;
    await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    final w = await BackgroundScenarioPool.shared.windowAt(last);
    await bg.replaceQueue(w.files, window: w);

    expect(bg.state.queueWindowStart, 400);
    expect(bg.state.queueTotal, count);
    expect(bg.state.currentIndex, last - 400);
    expect(bg.currentFile!.name, names[last]);
    expect(
      bg.state.queueWindowStart + bg.state.queue.length <= bg.state.queueTotal,
      isTrue,
      reason: 'the queue must stay a window (start + length <= total)',
    );
  });

  test('every candidate virtualIndex is its position in the resolved stream',
      () async {
    final all = await resolveBackgroundCandidates(scenarioId: 'bg');
    expect(all.length, count);
    // The view is name asc while the membership order is the reverse, so a raw
    // membership index would fail this for every row but the middle.
    for (var i = 0; i < all.length; i++) {
      expect(all[i].virtualIndex, i,
          reason: 'virtualIndex must index the resolved stream, not membership');
      expect(all[i].media.name, names[i]);
    }
  });

  test('tapping a row plays the file the view shows at that position',
      () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    final w = await BackgroundScenarioPool.shared.window();
    await bg.enableWithQueue(w.files, window: w);

    final all = await resolveBackgroundCandidates(scenarioId: 'bg');
    const target = 7;
    final outcome = await bg.jumpToOccurrence(
      virtualIndex: all[target].virtualIndex,
      mediaKey: canonicalKey(
        all[target].occurrenceId.storageId,
        all[target].occurrenceId.path,
      ),
      userInitiated: true,
    );
    expect(outcome, BgJumpOutcome.jumped);
    expect(bg.currentFile!.name, names[target]);
  });

  test('window(aroundKey:) follows the item across an order change', () async {
    // The order changed under a numeric anchor: after a shuffle toggle the
    // playing file's OLD index points at unrelated content, so the page must be
    // centred on its KEY instead (regression: >1 page + shuffle dropped the
    // playing file and fell back to the page head).
    final remembered = await ensureBackgroundPlaybackWorkspace();
    await usePlaybackScenarioStore().setCurrentItemFor(
      remembered.id,
      occurrence: PlaybackOccurrenceId(
        storageId: 's1',
        path: canonicalOccurrencePath(['Anime', names[0]].join('/')),
        occurrenceIndex: 0,
      ),
    );

    final last = count - 1;
    // The numeric anchor points at page 0 while the key now lives on page 1.
    final w = await BackgroundScenarioPool.shared.window(
      around: 0,
      aroundKey: keyOf(names[last]),
    );
    expect(w.start, 400, reason: 'the KEY wins over a stale numeric anchor');
    expect(w.files.first.name, names[400]);

    // An unresolvable key falls back to the numeric anchor (and then focus).
    final fallback = await BackgroundScenarioPool.shared.window(
      around: last,
      aroundKey: 's1:no/such/file.mp4',
    );
    expect(fallback.start, 400);
  });

  test('toggleShuffle keeps the playing file across the order change', () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    final firstPage = await BackgroundScenarioPool.shared.window();
    await bg.enableWithQueue(firstPage.files, window: firstPage);

    // Land on the last item, so the run holds a GLOBAL index on page 1 (449).
    final last = count - 1;
    await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    expect(bg.state.queueWindowStart, 400);
    expect(bg.currentFile!.name, names[last]);

    // Deterministic order flip: mark the run shuffled (so the next toggle turns
    // it OFF, keeping the sort) and reverse the tag view's order underneath it.
    // In the reversed order names[last] sits at global 0, while the stale
    // numeric anchor (400 + 49) still points at page 1 — and page 1 no longer
    // holds it. The old code dropped to the page head (names[49]).
    bg.set(bg.state.copyWith(shuffle: true));
    final tags = await DbModule.tagPlayRepo.ensureReservedTags();
    final tagId = tags
        .firstWhere(
            (t) => t.systemKind == TagSystemKind.backgroundVoiceCandidate)
        .id;
    await DbModule.tagPlayRepo.saveState(TagPlayViewState(
      tagId: tagId,
      sortField: TagPlaySortField.name,
      sortDirection: SortDirection.desc,
    ));

    await bg.toggleShuffle();

    expect(bg.state.shuffle, isFalse);
    expect(bg.state.queueWindowStart, 0);
    expect(bg.state.currentIndex, 0);
    expect(bg.currentFile!.name, names[last],
        reason: 'the playing file survives the order change');

    // Restore the shared view state for the other tests in this file.
    await DbModule.tagPlayRepo.saveState(TagPlayViewState(
      tagId: tagId,
      sortField: TagPlaySortField.name,
      sortDirection: SortDirection.asc,
    ));
  });

  test('resolveCurrentItemIndex is a GLOBAL position, not a page row',
      () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    final w = await BackgroundScenarioPool.shared.window();
    await bg.enableWithQueue(w.files, window: w);

    final last = count - 1;
    await bg.jumpToOccurrence(
      virtualIndex: last,
      mediaKey: keyOf(names[last]),
      userInitiated: true,
    );
    expect(bg.currentFile!.name, names[last]);

    final ds = PagedBackgroundMediaDataSource(scenarioId: 'bg');
    addTearDown(ds.dispose);
    await ds.fetchPage(0, ds.pageSize);
    expect(ds.currentPage, 0);

    final index = await ds.resolveCurrentItemIndex();
    expect(index, last,
        reason: 'the whole-list position, not a row inside page 0');
    expect(ds.pageForIndex(index!), 400 ~/ ds.pageSize);
  });

  test('resolveCurrentItemIndex stays global when the item is on a later page',
      () async {
    final bg = useBackgroundPlaybackStore();
    bg.set(bg.state.copyWith(shuffle: false));
    final w = await BackgroundScenarioPool.shared.window();
    await bg.enableWithQueue(w.files, window: w);

    const target = 60;
    await bg.jumpToOccurrence(
      virtualIndex: target,
      mediaKey: keyOf(names[target]),
      userInitiated: true,
    );

    final ds = PagedBackgroundMediaDataSource(scenarioId: 'bg');
    addTearDown(ds.dispose);
    // Twice: the constructor's unawaited page-0 fetch may still be in flight.
    await ds.fetchPage(1, ds.pageSize);
    await ds.fetchPage(1, ds.pageSize);
    expect(ds.currentPage, 1);

    final index = await ds.resolveCurrentItemIndex();
    expect(index, target);
  });
}
