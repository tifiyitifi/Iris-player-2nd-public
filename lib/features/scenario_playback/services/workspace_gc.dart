import 'dart:convert';

import 'package:iris/features/app_identity/model/domain/app_identity_entry.dart';
import 'package:iris/features/app_identity/store/use_app_identity_store.dart';
import 'package:iris/features/scenario_playback/model/db/repositories/scenario_repository.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario_workspace_order.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyScenario);

/// Startup sweep of internal workspace rows whose owning window can never claim
/// them again.
///
/// Multi-window design recap: every extra window plays in its OWN
/// `systemPlaying` / entry workspace row and remembers the id in its SESSION
/// scope (see `PlaybackScenarioStore`). Those rows intentionally outlive the
/// process so a window's queue survives a restart — so the sweep must only
/// remove rows that nothing can ever point at again:
///
///   * the OLDEST `systemPlaying` row is always kept (the primary's workspace),
///   * the single default `background` row is never touched,
///   * any row a desktop entry points at (fg or bg) is kept,
///   * any row claimed by ANY slot's session scope is kept,
///   * only rows older than [minimumAge] are considered.
///
/// The age gate is what makes the sweep safe against a window that is starting
/// right now: it has not written its claim yet, and an upgrade must not eat the
/// queues of windows that merely happen to be closed at the moment.
abstract final class WorkspaceGc {
  /// How old an unclaimed row must be before it is reclaimed.
  static const Duration minimumAge = Duration(days: 30);

  /// Primary-only entry point used by startup. Never throws.
  static Future<int> sweepAtStartup() async {
    if (!AppInstance.isPrimary) return 0;
    if (!DbModule.isReady) return 0;
    try {
      final claims = await collectClaims(getKvStore());
      final identity = useAppIdentityStore();
      // A FAILED identity load leaves `entries` empty, which looks exactly like
      // "no desktop entries" — but the entry's workspace refs are what keeps
      // that workspace (and its definition rows) alive. Never sweep on a
      // partial view: the purge is irreversible, and the entry would survive
      // pointing at a workspace that no longer exists.
      if (!identity.loaded) {
        _log.w('workspace GC skipped: app-identity entries did not load');
        return 0;
      }
      final refs = entryWorkspaceRefs(identity.state.entries);
      return await sweep(
        repo: DbModule.scenarioRepo,
        claimedWorkspaceIds: claims,
        referencedWorkspaceIds: refs,
        now: DateTime.now(),
      );
    } catch (e) {
      _log.w('workspace GC failed: $e');
      return 0;
    }
  }

  /// Every workspace id claimed by any slot's session scope.
  ///
  /// Slot 1 writes unprefixed keys; every other slot writes `s<n>.` (see
  /// `getSessionKvStore`). Reading them through the SHARED store is deliberate:
  /// the sweep runs in one window but must see what the other windows claimed.
  static Future<Set<String>> collectClaims(
    KvStore baseStore, {
    int maxSlots = AppInstance.maxSlots,
  }) async {
    final ids = <String>{};
    for (var slot = 1; slot <= maxSlots; slot++) {
      await _collectSlot(baseStore, slot == 1 ? '' : 's$slot.', ids);
    }
    return ids;
  }

  static Future<void> _collectSlot(
    KvStore store,
    String prefix,
    Set<String> into,
  ) async {
    try {
      final claims = await store.read(key: prefix + KvKeys.workspaceClaims);
      if (claims != null) {
        final decoded = json.decode(claims);
        if (decoded is Map) {
          for (final value in decoded.values) {
            if (value is String && value.isNotEmpty) into.add(value);
          }
        }
      }
    } catch (e) {
      _log.w('workspace GC: reading claims for $prefix failed: $e');
    }
    try {
      final raw = await store.read(
        key: prefix + KvKeys.playbackScenarioActiveId,
      );
      if (raw == null) return;
      final decoded = json.decode(raw);
      if (decoded is Map) {
        final id = decoded['instanceWorkspaceId'];
        if (id is String && id.isNotEmpty) into.add(id);
      }
    } catch (e) {
      _log.w('workspace GC: reading session workspace for $prefix failed: $e');
    }
  }

  /// Workspace ids an existing desktop entry still points at (fg + bg).
  static Set<String> entryWorkspaceRefs(Iterable<AppIdentityEntry> entries) {
    final refs = <String>{};
    for (final entry in entries) {
      final fg = entry.workspaceScenarioId;
      if (fg != null && fg.isNotEmpty) refs.add(fg);
      final bg = entry.backgroundWorkspaceScenarioId;
      if (bg != null && bg.isNotEmpty) refs.add(bg);
    }
    return refs;
  }

  /// The sweep itself. All inputs are explicit so it can be tested without a
  /// KV backend or a live window.
  static Future<int> sweep({
    required ScenarioRepository repo,
    required Set<String> claimedWorkspaceIds,
    required Set<String> referencedWorkspaceIds,
    required DateTime now,
    Duration age = minimumAge,
  }) async {
    final all = await repo.getAllScenarios();
    final oldestSystemPlaying =
        oldestOfType(all, ScenarioKind.systemPlaying)?.id;

    var removed = 0;
    for (final scenario in all) {
      if (scenario.type != ScenarioKind.systemPlaying &&
          scenario.type != ScenarioKind.entryWorkspace &&
          scenario.type != ScenarioKind.entryBackground) {
        continue;
      }
      if (scenario.id == oldestSystemPlaying) continue;
      if (claimedWorkspaceIds.contains(scenario.id)) continue;
      if (referencedWorkspaceIds.contains(scenario.id)) continue;
      final created = scenario.createdAt;
      // Unknown age: never delete what we cannot date.
      if (created == null) continue;
      if (now.difference(created) < age) continue;
      try {
        await repo.purgeInternalWorkspace(scenario.id);
        removed++;
      } catch (e) {
        _log.w('workspace GC: purging ${scenario.id} failed: $e');
      }
    }
    if (removed > 0) {
      _log.i('workspace GC reclaimed $removed orphaned workspace(s)');
    }
    return removed;
  }
}
