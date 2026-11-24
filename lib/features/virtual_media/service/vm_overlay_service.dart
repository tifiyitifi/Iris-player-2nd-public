import 'package:flutter/foundation.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/resolver/vm_preflight.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/service/vm_membership_pin.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';

final _log = AreaKeyLog(LogKeys.mediaProbe);

/// Global Virtual Merge coordination: enabled-rule access + rule-change
/// propagation. Deliberately holds NO media data — grouping in playback is
/// derived from each scenario's own effective stream (scenario-first, see
/// vm_stream_merge.dart), so there is no merge-layer snapshot to own or
/// invalidate.
///
/// Orthogonal to tag_play: nothing here mutates scenario definitions.
class VirtualMediaService {
  VirtualMediaService._();

  static final VirtualMediaService instance = VirtualMediaService._();

  int _revision = 0;

  /// Monotonic counter bumped on every invalidation; part of the playback
  /// signature so provider position caches drop when rules change.
  int get revision => _revision;

  List<VirtualMediaRule>? _rulesCache;

  /// Latest preflight failure attribution by canonical mediaKey, published by
  /// the scenario resolver alongside each merged page. The list UI reads it
  /// synchronously to render the yellow warning mark; failed members play as
  /// ordinary single files. Guarded by [failRevision]: entries are only valid
  /// for the resolve revision that produced them.
  Map<String, VmFailInfo> _lastFailByKey = const {};
  int _failRevision = 0;

  Map<String, VmFailInfo> get lastFailByKey => _lastFailByKey;

  /// Revision of the published fail map; bumped on every set/append/clear so
  /// future readers can detect stale snapshots.
  int get failRevision => _failRevision;

  /// Infeasible groups by scopeKey from the latest resolve pass — segment
  /// source for the duration-scan flow (scan exactly the failed group).
  Map<String, VirtualMediaItem> _failedGroupsByScope = const {};

  VirtualMediaItem? failedGroupForScope(String scopeKey) =>
      _failedGroupsByScope[scopeKey];

  /// Sync check for list tiles: non-null when [mediaKey] failed preflight and
  /// was degraded to a normal single item.
  VmFailInfo? failInfoFor(String mediaKey) => _lastFailByKey[mediaKey];

  /// Publishes the fail map derived from the current resolve pass.
  void setLastFail(
    Map<String, VmFailInfo> failByKey, {
    List<VirtualMediaItem> failedGroups = const [],
  }) {
    _lastFailByKey = Map.unmodifiable(failByKey);
    _failRevision++;
    _failedGroupsByScope = {
      for (final g in failedGroups) g.scopeKey: g,
    };
    _publishFailFingerprint();
    if (failByKey.isNotEmpty) {
      // Sample-only logging: full key lists for 100+ item groups spammed
      // the log on every resolve pass.
      final sample = failByKey.entries
          .take(3)
          .map((e) => '${e.key}(${e.value.reason.name})')
          .join(',');
      final more =
          failByKey.length > 3 ? ' +${failByKey.length - 3} more' : '';
      _log.w('vm preflight degraded ${failByKey.length} item(s) to normal: '
          '$sample$more');
    }
  }

  /// Merges extra failures discovered by the blocking playback preflight
  /// (DB re-check / probe at tap time) into the published map so tiles
  /// yellow-mark immediately and the provider falls back to normal play.
  void appendFail(Map<String, VmFailInfo> extra) {
    if (extra.isEmpty) return;
    _lastFailByKey = Map.unmodifiable({..._lastFailByKey, ...extra});
    _failRevision++;
    _publishFailFingerprint();
    final sample = extra.entries
        .take(3)
        .map((e) => '${e.key}(${e.value.reason.name})')
        .join(',');
    final more = extra.length > 3 ? ' +${extra.length - 3} more' : '';
    _log.w('vm preflight(play-time) degraded ${extra.length} item(s): '
        '$sample$more');
  }

  /// Removes failure attribution for [keys] (e.g. after a duration scan
  /// filled them in) so tiles un-mark and the next resolve merges again.
  void removeFailFor(Set<String> keys) {
    if (keys.isEmpty || _lastFailByKey.isEmpty) return;
    final next = Map.of(_lastFailByKey)..removeWhere((k, _) => keys.contains(k));
    if (next.length == _lastFailByKey.length) return;
    _lastFailByKey = Map.unmodifiable(next);
    _failRevision++;
    _publishFailFingerprint();
  }

  /// Content-stable fingerprint of the published fail map (sorted keys +
  /// reasons). Unlike [failRevision] — which bumps on every publish, even a
  /// re-resolve of identical content — equal content yields an equal
  /// fingerprint, so open lists can refresh on real changes without
  /// self-triggering through the fetch→resolve→setLastFail cycle.
  String get failFingerprint => _failFingerprint.value;

  /// Fires only when [failFingerprint] actually changes (ValueNotifier drops
  /// identical consecutive values). Shell-support bookkeeping
  /// ([markShellUnsupported]) never touches it.
  ValueListenable<String> get failFingerprintListenable => _failFingerprint;

  final ValueNotifier<String> _failFingerprint = ValueNotifier<String>('');

  static String _failFingerprintOf(Map<String, VmFailInfo> fail) {
    if (fail.isEmpty) return '';
    final keys = fail.keys.toList()..sort();
    return keys.map((k) => '$k:${fail[k]!.reason.name}').join('|');
  }

  void _publishFailFingerprint() {
    _failFingerprint.value = _failFingerprintOf(_lastFailByKey);
  }

  /// MediaKeys whose Windows Shell property handler is known-empty this
  /// session (duration reads come back VT_EMPTY — only a demux can read
  /// them). Shell scans fail these fast without a probe round-trip; the slow
  /// harvest path is unaffected. Cleared on [invalidate].
  final Set<String> _shellUnsupported = {};

  bool isShellUnsupported(String mediaKey) =>
      _shellUnsupported.contains(mediaKey);

  /// Snapshot for scan `skipKeys` (the scan intersects it with its own
  /// segments, so passing the whole set is safe).
  Set<String> get shellUnsupportedKeys =>
      Set<String>.unmodifiable(_shellUnsupported);

  void markShellUnsupported(Iterable<String> keys) {
    _shellUnsupported.addAll(keys);
  }

  /// ScopeKeys whose scan prompt the user dismissed this session ("取消合并，
  /// 普通播放"). The yellow mark stays; only the scan-or-cancel dialog is
  /// suppressed. Cleared on [invalidate] so rule changes re-arm the prompt.
  final Set<String> _dismissedScanScopes = {};

  bool isScanDismissed(String scopeKey) =>
      _dismissedScanScopes.contains(scopeKey);

  void dismissScanScope(String scopeKey) {
    _dismissedScanScopes.add(scopeKey);
  }

  /// Drops the rule cache. Does NOT touch the scenario store —
  /// use [notifyRulesChanged] for the full propagation.
  void invalidate() {
    _revision++;
    _rulesCache = null;
    _lastFailByKey = const {};
    _failRevision++;
    _failedGroupsByScope = const {};
    _dismissedScanScopes.clear();
    _shellUnsupported.clear();
    _publishFailFingerprint();
    // A rule edit (the caller of the full-propagation path) is one of the four
    // legitimate re-group triggers: drop any delete-time boundary freeze so the
    // next resolve derives fresh chunks.
    VmMembershipPin.instance.clear();
  }

  /// Test seam: how many full fan-outs ran since a test reset it. Assert-only,
  /// so it exists solely in debug/test builds.
  @visibleForTesting
  static int debugNotifyCount = 0;

  /// Full rule-change propagation: drop the rule cache AND bump BOTH
  /// re-resolution signals, so every open surface moves immediately
  /// ("一旦激活改变，立刻更新 scenario play 列表").
  ///
  /// Two signals are required because the consumers differ: `playbackVersion`
  /// re-resolves the player chrome and the locate caches, while OPEN QUEUE
  /// surfaces (the always-mounted desktop dock, the floating queue popup, the
  /// storagedb queue page) only re-fetch on `sourceScanRevision` — they
  /// deliberately ignore `playbackVersion`, whose other call sites fetch
  /// explicitly. Sending only the first signal left the dock rendering the
  /// pre-change rows until it was reopened (the reported desktop bug).
  Future<void> notifyRulesChanged() async {
    // Test seam: one folder action must produce exactly ONE fan-out. Counted
    // only while asserts are on, so a release build carries no counter.
    assert(() {
      debugNotifyCount++;
      return true;
    }());
    invalidate();
    // An ACTIVE tag view holds its own snapshot of the merge groups: re-resolve
    // it FIRST so the queue refetch below observes the new shape. Late-bound
    // because the playback layer imports this service through the resolver.
    try {
      await tagViewRuleChangeRefresher?.call();
    } catch (e) {
      _log.w('vm notifyRulesChanged tag refresh failed: $e');
    }
    try {
      await usePlaybackScenarioStore().bumpPlaybackVersion();
    } catch (e) {
      _log.w('vm notifyRulesChanged bump failed: $e');
    }
    try {
      await usePlaybackScenarioStore().notifyQueueRefetch();
    } catch (e) {
      _log.w('vm notifyRulesChanged queue refetch failed: $e');
    }
  }

  /// Installed by the playback layer (see `PlaybackProviderRegistry.init`):
  /// re-resolves an active tag view after a rule change. Null until then (unit
  /// tests, early startup), where it is simply a no-op.
  static Future<void> Function()? tagViewRuleChangeRefresher;

  /// Lighter propagation for a duration heal (scan/harvest wrote durations for
  /// existing files). The RULES did not change, so the rule cache and the
  /// per-session scan bookkeeping ([_shellUnsupported], [_dismissedScanScopes])
  /// must survive — clearing them here re-enabled fast-scan probing of files
  /// already known to be Shell-empty. Only the scenario playback version is
  /// bumped so open lists re-resolve and pick up the now-mergeable group; the
  /// fail map itself is updated by [removeFailFor] before this call.
  Future<void> notifyDurationsChanged() async {
    // Durations can change chunking (duration cap), so this is a re-group
    // trigger that must also drop a delete-time boundary freeze.
    VmMembershipPin.instance.clear();
    try {
      final store = usePlaybackScenarioStore();
      await store.bumpPlaybackVersion();
      // Durations feed duration sorts and VM duration caps, so the derived
      // index is stale too: bumpSourceScanRevision persists the media content
      // revision the index signature keys on (and refetches an open queue).
      await store.bumpSourceScanRevision();
    } catch (e) {
      _log.w('vm notifyDurationsChanged bump failed: $e');
    }
  }

  /// Lighter propagation for a change in the ACTIVE 虚拟剪播 plan (activate /
  /// close). The RULES did not change, so this must NOT go through
  /// [notifyRulesChanged]: that fan-out drops the rule cache, the fail map, the
  /// Shell-empty marks and the dismissed scan prompts, which made a cut toggle
  /// re-arm probing for unrelated files (ADR 0035).
  ///
  /// What DOES change is admission — the merged rows and their durations — so:
  /// bump the VM revision (the derived-index signature includes it, forcing an
  /// in-memory rebuild), drop the delete-time boundary freeze, refresh an active
  /// tag view FIRST (its snapshot holds the groups the feed and list read), then
  /// send both re-resolve signals: `playbackVersion` for the player chrome /
  /// locate caches, `notifyQueueRefetch` for OPEN queue surfaces.
  Future<void> notifyCutPlanChanged() async {
    _revision++;
    VmMembershipPin.instance.clear();
    try {
      await tagViewRuleChangeRefresher?.call();
    } catch (e) {
      _log.w('vm notifyCutPlanChanged tag refresh failed: $e');
    }
    try {
      await usePlaybackScenarioStore().bumpPlaybackVersion();
    } catch (e) {
      _log.w('vm notifyCutPlanChanged bump failed: $e');
    }
    try {
      await usePlaybackScenarioStore().notifyQueueRefetch();
    } catch (e) {
      _log.w('vm notifyCutPlanChanged queue refetch failed: $e');
    }
  }

  /// Enabled rules (drift `vm_rules`), cached until the next rule change.
  /// One small DB read per rule edit — never per resolve page. Empty when
  /// the feature is gated off, the master switch is paused, or nothing is
  /// enabled.
  Future<List<VirtualMediaRule>> enabledRules() async {
    final cached = _rulesCache;
    if (cached != null) return cached;
    if (!VirtualMediaGate.enabled) {
      _log.w('vm gate DISABLED: legacy=${useAppStore().state.useLegacyStoragePersistence} '
          'meta=${useAppStore().state.useMetadataSettings}');
      return _rulesCache = const [];
    }
    if (!await VmPrefs.masterEnabled()) {
      _log.i('vm master switch OFF: merge paused (rules kept)');
      return _rulesCache = const [];
    }
    try {
      final rules = await DbModule.virtualMediaRepo.loadRules();
      final enabled = rules.where((r) => r.enabled).toList();
      _log.i('vm enabledRules: total=${rules.length} enabled=${enabled.length}');
      return _rulesCache = List.unmodifiable(enabled);
    } catch (e) {
      _log.w('vm enabledRules load failed: $e');
      return _rulesCache = const [];
    }
  }

  /// The enabled rule whose scope covers (storageId, path), or null.
  /// Single-entry point check shared with the batch resolver
  /// ([vmRuleCoversFile]).
  Future<VirtualMediaRule?> coveringRuleFor(
      String storageId, String path) async {
    final rules = await coveringRulesFor(storageId, path);
    return rules.isEmpty ? null : rules.first;
  }

  /// EVERY enabled rule whose scope covers (storageId, path).
  ///
  /// Overlapping rules are allowed to claim the same file, so the desktop
  /// physical-delete path must freeze the boundaries of ALL rules the deleted
  /// file participates in — not just the first (`coveringRuleFor`).
  Future<List<VirtualMediaRule>> coveringRulesFor(
      String storageId, String path) async {
    final rules = await enabledRules();
    if (rules.isEmpty) return const [];
    final segs = pathConv(path);
    final probe = VirtualSegment(
      mediaKey: canonicalKey(storageId, path),
      storageId: storageId,
      path: segs,
      name: segs.isEmpty ? '' : segs.last,
      parentPath: canonicalPath(segs.length <= 1
          ? ''
          : segs.sublist(0, segs.length - 1).join('/')),
    );
    return [
      for (final rule in rules)
        if (vmRuleCoversFile(rule, probe)) rule,
    ];
  }
}
