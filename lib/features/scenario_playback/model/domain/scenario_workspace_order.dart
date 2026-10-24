import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';

/// The canonical "age" order of internal workspace rows.
///
/// ONE rule, two implementations: [ScenariosDao.getByType] expresses it in SQL
/// (`ORDER BY createdAt ASC, rowid ASC LIMIT 1`) and the scenario store applies
/// [oldestOfType] to the already-loaded list. They must agree — the primary
/// window's playing workspace is "the oldest `systemPlaying` row", and a
/// disagreement would let `ensureSystemPlayingScenario` (repository) and the
/// scenario mirror (store) point at different queues.
///
/// `createdAt` alone is not a total order: two rows minted in the same
/// millisecond tie, and the SQL pick would then be free to return either of
/// them. The DAO's shared order therefore appends `rowid` (insertion order),
/// which is the order this list comes back in, so ties resolve to "first in the
/// list" on both sides. Do not add `id` as a sort key: it is a random UUID, so it
/// would reorder same-millisecond rows arbitrarily per install and could move
/// the primary window off its historical row after an upgrade.
int compareWorkspaceAge(Scenario a, Scenario b) {
  final at = a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  final bt = b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
  return at.compareTo(bt);
}

/// The oldest row of [kind] in [scenarios], or null.
///
/// Strictly `<` keeps the FIRST minimum, mirroring `LIMIT 1` over an
/// `ORDER BY createdAt ASC` scan.
Scenario? oldestOfType(Iterable<Scenario> scenarios, ScenarioKind kind) {
  Scenario? oldest;
  for (final scenario in scenarios) {
    if (scenario.type != kind) continue;
    if (oldest == null || compareWorkspaceAge(scenario, oldest) < 0) {
      oldest = scenario;
    }
  }
  return oldest;
}
