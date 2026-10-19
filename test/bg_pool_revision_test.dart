import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/bg_pool_revision.dart';
import 'package:iris/features/tag_play/services/tag_membership_revision.dart';

void main() {
  late TagMembershipRevision source;
  late List<int> probed;
  late BgPoolRevision revision;

  /// A relevance predicate that treats `relevant` ids as readable sources.
  BgPoolRevision build(Set<int> relevant, {Duration? window}) {
    probed = [];
    return BgPoolRevision(
      source: source,
      relevanceOf: (tagId) async {
        probed.add(tagId);
        return relevant.contains(tagId);
      },
      coalesce: window ?? const Duration(milliseconds: 10),
    );
  }

  setUp(() {
    source = TagMembershipRevision.detached();
  });

  tearDown(() {
    revision.dispose();
    source.dispose();
  });

  /// Lets the coalescing timer fire and the (async) relevance probe settle.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 60));

  test('a relevant membership write bumps the revision', () async {
    revision = build({7});
    revision.start();

    source.bump(7);
    await settle();

    expect(revision.revision, 1);
  });

  test('an irrelevant tag never bumps it', () async {
    revision = build({7});
    revision.start();

    source.bump(42);
    await settle();

    expect(revision.revision, 0,
        reason: 'an unrelated tag must not re-resolve the candidate pool');
  });

  test('a burst of writes is coalesced into a single bump', () async {
    revision = build({7}, window: const Duration(milliseconds: 40));
    revision.start();

    // A settings import / `+N` tag command writes members one row at a time.
    for (var i = 0; i < 50; i++) {
      source.bump(7);
    }
    await settle();

    expect(probed.length, 1, reason: 'one probe per batch, not per write');
    expect(revision.revision, 1);
  });

  test('a write that lands mid-probe is not lost', () async {
    final probedIds = <int>[];
    revision = BgPoolRevision(
      source: source,
      relevanceOf: (tagId) async {
        probedIds.add(tagId);
        if (probedIds.length == 1) {
          // A second write arrives while the first probe is still awaiting.
          source.bump(9);
        }
        return true;
      },
      coalesce: const Duration(milliseconds: 5),
    );
    revision.start();

    source.bump(7);
    await settle();

    expect(probedIds.length, greaterThanOrEqualTo(2),
        reason: 'the second batch must be probed, not dropped');
    expect(revision.revision, 2);
  });

  test('a failing probe does not wedge the signal', () async {
    var calls = 0;
    revision = BgPoolRevision(
      source: source,
      relevanceOf: (tagId) async {
        calls++;
        if (calls == 1) throw StateError('db gone');
        return true;
      },
      coalesce: const Duration(milliseconds: 5),
    );
    revision.start();

    source.bump(7);
    await settle();
    expect(revision.revision, 0, reason: 'a failed probe means "no verdict"');

    source.bump(7);
    await settle();
    expect(revision.revision, 1, reason: 'the next write must still work');
  });

  test('start is idempotent', () async {
    revision = build({7});
    revision.start();
    revision.start();

    source.bump(7);
    await settle();

    expect(revision.revision, 1);
    expect(probed.length, 1, reason: 'a second listener would double-probe');
  });

  test('the notifier fires once per relevant batch', () async {
    revision = build({7});
    var notifications = 0;
    revision.notifier.addListener(() => notifications++);
    revision.start();

    source.bump(7);
    await settle();

    expect(notifications, 1);
  });

  test('reset detaches the listener so it stops probing', () async {
    revision = build({7});
    revision.start();
    revision.reset();

    source.bump(7);
    await settle();

    expect(probed, isEmpty, reason: 'reset must stop listening');
    expect(revision.revision, 0);
  });

  test('a later start refreshes the relevance probe', () async {
    final calls = <String>[];
    revision = BgPoolRevision(
      source: source,
      relevanceOf: (tagId) async {
        calls.add('first');
        return false;
      },
      coalesce: const Duration(milliseconds: 5),
    );
    revision.start();
    revision.start(relevanceOf: (tagId) async {
      calls.add('second');
      return true;
    });

    source.bump(7);
    await settle();

    expect(calls, ['second'], reason: 'the refreshed probe must decide');
    expect(revision.revision, 1);
  });
}
