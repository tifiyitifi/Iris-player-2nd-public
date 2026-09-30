import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/engine/bg_tag_sync_logic.dart';
import 'package:iris/features/background_playback/model/enum/bg_queue_sync_mode.dart';
import 'package:iris/models/file.dart';

FileItem _f(String key) => FileItem(name: key, uri: 'file:///$key', path: [key]);

List<String> _names(List<FileItem> files) =>
    [for (final f in files) f.name];

void main() {
  final a = _f('a');
  final b = _f('b');
  final c = _f('c');

  group('resolveBgTagSyncAction', () {
    BgTagSyncAction resolve({
      required BgQueueSyncMode mode,
      required List<FileItem> queue,
      required List<FileItem> candidates,
      bool enabled = true,
      bool gateOpen = true,
      bool shuffled = false,
    }) =>
        resolveBgTagSyncAction(
          mode: mode,
          queue: queue,
          candidates: candidates,
          enabled: enabled,
          gateOpen: gateOpen,
          shuffled: shuffled,
        );

    test('a stopped or disabled run is never rewritten', () {
      for (final mode in BgQueueSyncMode.values) {
        expect(
          resolve(mode: mode, queue: [a], candidates: [a, b], enabled: false),
          BgTagSyncAction.none,
        );
        expect(
          resolve(mode: mode, queue: [a], candidates: [a, b], gateOpen: false),
          BgTagSyncAction.none,
        );
      }
    });

    test('an empty resolve never empties a live queue', () {
      for (final mode in BgQueueSyncMode.values) {
        expect(
          resolve(mode: mode, queue: [a, b], candidates: const []),
          BgTagSyncAction.none,
        );
      }
    });

    test('rebuild replaces the queue when the pool gained a member', () {
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [a, b],
          candidates: [c, b, a],
        ),
        BgTagSyncAction.rebuild,
      );
    });

    test('rebuild replaces the queue when a member was removed', () {
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [a, b],
          candidates: [a],
        ),
        BgTagSyncAction.rebuild,
      );
    });

    test('rebuild is a no-op when the pool holds exactly the queue', () {
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [a, b],
          candidates: [a, b],
        ),
        BgTagSyncAction.none,
      );
    });

    test('rebuild still fires when only the order changed', () {
      // The rules own the order, so a reordered pool is a real change even
      // though the membership is identical.
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [a, b],
          candidates: [b, a],
        ),
        BgTagSyncAction.rebuild,
      );
    });

    test('a shuffled queue ignores pool order', () {
      // With shuffle on, the queue order is random and carries no meaning, so
      // comparing entry-for-entry would report a difference on EVERY write and
      // re-shuffle the whole list (plus a secure-storage write) for nothing.
      // The rules' order is only authoritative when shuffle is off.
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [b, a],
          candidates: [a, b],
          shuffled: true,
        ),
        BgTagSyncAction.none,
      );
    });

    test('a shuffled queue still rebuilds when membership changed', () {
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [b, a],
          candidates: [a, b, c],
          shuffled: true,
        ),
        BgTagSyncAction.rebuild,
      );
    });

    test('a shuffled queue is unaffected by a reordered pool with the same '
        'members', () {
      // Same members, rules' order differs: under shuffle this is a no-op, and
      // membership is compared as a SET (duplicates in the queue are a real
      // difference because a set comparison cannot see them).
      expect(
        resolve(
          mode: BgQueueSyncMode.rebuild,
          queue: [a, a, b],
          candidates: [a, b, b],
          shuffled: true,
        ),
        BgTagSyncAction.rebuild,
      );
    });

    test('append only fires when the queue is missing something', () {
      expect(
        resolve(
          mode: BgQueueSyncMode.append,
          queue: [a, b],
          candidates: [b, a],
        ),
        BgTagSyncAction.none,
      );
      expect(
        resolve(
          mode: BgQueueSyncMode.append,
          queue: [a, b],
          candidates: [a, b, c],
        ),
        BgTagSyncAction.append,
      );
    });

    test('append ignores a removed member (it only ever adds)', () {
      // A member that left the tag stays queued until a manual refresh; that
      // is the documented cost of the gentle mode.
      expect(
        resolve(
          mode: BgQueueSyncMode.append,
          queue: [a, b],
          candidates: [a],
        ),
        BgTagSyncAction.none,
      );
    });
  });

  group('appendedBgQueue', () {
    test('appends only what is missing, in resolved order', () {
      expect(
        _names(appendedBgQueue(queue: [a], candidates: [b, a, c])),
        ['a', 'b', 'c'],
      );
    });

    test('never queues the same physical media twice', () {
      final sameMedia = FileItem(name: 'renamed', uri: 'file:///a', path: ['a']);
      expect(
        _names(appendedBgQueue(queue: [a], candidates: [sameMedia, b])),
        ['a', 'b'],
      );
    });

    test('an empty candidate list leaves the queue untouched', () {
      expect(_names(appendedBgQueue(queue: [a, b], candidates: const [])),
          ['a', 'b']);
    });
  });

  group('queueMatchesPool', () {
    test('is entry-for-entry', () {
      expect(queueMatchesPool([a, b, c], [a, b, c]), isTrue);
      expect(queueMatchesPool([a, b, c], [c, b, a]), isFalse);
      expect(queueMatchesPool([a, b], [a]), isFalse);
    });

    test('matches on the media key, not the file name', () {
      final renamed = FileItem(name: 'renamed', uri: 'file:///a', path: ['a']);
      expect(queueMatchesPool([a, b], [renamed, b]), isTrue);
    });

    test('sees a different length as different', () {
      expect(queueMatchesPool([a, b], [a]), isFalse);
    });
  });
}
