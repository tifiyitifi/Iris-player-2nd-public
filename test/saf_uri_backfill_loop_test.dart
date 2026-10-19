import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/saf_uri_backfill_service.dart';

/// The chunked SAF URI backfill must terminate on progress, not on a
/// lifetime-healed counter: a full chunk of rows that cannot be healed
/// (renamed / deleted / permission revoked) used to keep the loop fetching the
/// same batch forever once ANY earlier round had healed something.
void main() {
  List<SafBackfillRow> fullChunk() =>
      List.generate(200, (i) => (path: 'p$i.mp4', name: 'p$i.mp4'));

  test('a full chunk that heals nothing stops after one round', () async {
    var fetches = 0;
    final stats = await runSafBackfillLoop(
      limit: 200,
      fetch: () async {
        fetches++;
        return fullChunk();
      },
      heal: (_) async => false,
    );

    expect(fetches, 1, reason: 'no progress in a round must break the loop');
    expect(stats.done, 200);
    expect(stats.healed, 0);
  });

  test('keeps going while each full chunk makes progress, then stops',
      () async {
    var roundsLeft = 3;
    var fetches = 0;
    final stats = await runSafBackfillLoop(
      limit: 200,
      fetch: () async {
        fetches++;
        if (roundsLeft <= 0) return const [];
        roundsLeft--;
        return fullChunk();
      },
      heal: (_) async => true,
    );

    expect(stats.healed, 600);
    // 3 healing rounds + 1 final empty fetch.
    expect(fetches, 4);
  });

  test('a short chunk ends the pass without another fetch', () async {
    var fetches = 0;
    final stats = await runSafBackfillLoop(
      limit: 200,
      fetch: () async {
        fetches++;
        return List.generate(3, (i) => (path: 'p$i', name: 'p$i'));
      },
      heal: (_) async => true,
    );

    expect(fetches, 1);
    expect(stats.done, 3);
    expect(stats.healed, 3);
  });
}
