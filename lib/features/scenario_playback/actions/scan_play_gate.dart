import 'dart:async';

import 'package:flutter/material.dart';
import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';
import 'package:iris/features/media_library/scan/model/scan_rescan_reminder.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/probe/scan_probe_preference.dart';
import 'package:iris/features/media_library/scan/service/recursive_scan_service.dart';
import 'package:iris/features/media_library/scan/store/recursive_scan_store.dart';
import 'package:iris/features/scenario_playback/actions/media_revision_actions.dart';
import 'package:iris/features/scenario_playback/actions/pending_play_intent.dart';
import 'package:iris/features/media_library/scan/view/scan_options_dialog.dart';
import 'package:iris/features/media_library/scan/view/scan_info_dialog.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_common.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_error.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/db/storage_path_codec.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_copyable_error_dialog.dart';

/// Per-directory scan gate status (decision output of [classifyDirScanStatus]).
enum DirScanGateStatus { unscanned, scanning, done, error, stale }

/// Result of the scan gate for ONE play action.
///
/// [proceed] is true when the caller may play right now (fresh directories, or
/// the user chose play-anyway). Otherwise the action was aborted — either by a
/// cancel, or because a scan took over: [scanSettled] then names the run THIS
/// action must wait for (the batch just started, plus any already-running scan
/// covering a gated root). That anchor is per action by construction, so a
/// concurrent action's scan settling first can never steal it.
///
/// The anchor completes with whether ANY gated root actually produced playable
/// rows. A totally failed batch must not resume the play: the batch itself
/// raises the one scan-error prompt, and a resume would only stack a misleading
/// "nothing to play" dialog on top of it.
@immutable
class ScanGateOutcome {
  const ScanGateOutcome._({required this.proceed, this.scanSettled});

  /// Playback may proceed immediately.
  const ScanGateOutcome.proceed() : this._(proceed: true);

  /// The action was aborted and nothing will resume it.
  const ScanGateOutcome.cancelled() : this._(proceed: false);

  /// A scan took over; resume the action when [settled] completes with `true`.
  const ScanGateOutcome.scanning(Future<bool> settled)
      : this._(proceed: false, scanSettled: settled);

  final bool proceed;

  /// Non-null when a scan took over this action. Completes when every run this
  /// action depends on has settled (`done` / `stopped` / `error`), with `true`
  /// when at least one of them produced playable rows.
  final Future<bool>? scanSettled;
}

/// Classifies one directory's persisted scan status against the reminder
/// window. Pure — no IO — so it is unit-testable.
///
/// - `state == null` (row missing) or `'notScan'` → unscanned.
/// - `'scanning'` → scanning; `'error'` → error.
/// - `'scanDone'`: fresh (within [reminderMinutes]) → done; older → stale.
///   A `scanDone` row without `lastScanAt` is treated as done (corrupt rows
///   must not block playback). `reminderMinutes == 0` disables staleness.
DirScanGateStatus classifyDirScanStatus({
  required String? state,
  required DateTime? lastScanAt,
  required DateTime now,
  required int reminderMinutes,
}) {
  switch (state) {
    case null:
    case 'notScan':
      return DirScanGateStatus.unscanned;
    case 'scanning':
      return DirScanGateStatus.scanning;
    case 'error':
      return DirScanGateStatus.error;
    case 'scanDone':
      if (reminderMinutes <= 0 || lastScanAt == null) {
        return DirScanGateStatus.done;
      }
      final age = now.difference(lastScanAt);
      return age.inMinutes >= reminderMinutes
          ? DirScanGateStatus.stale
          : DirScanGateStatus.done;
    default:
      // Unknown persisted value → treat as unscanned (fail open to a dialog).
      return DirScanGateStatus.unscanned;
  }
}

/// Human-readable staleness, e.g. English `2h 05m` / `45m` / `30h`,
/// Chinese `2小时05分` / `45分` / `30小时`.
String formatStaleness(Duration age, AppLocalizations t) {
  final h = age.inHours;
  final m = age.inMinutes.remainder(60);
  final hs = '$h';
  final ms = m.toString().padLeft(2, '0');
  if (h > 0 && m > 0) return t.gate_stale_hm(hs, ms);
  if (h > 0) return t.gate_stale_h(hs);
  return t.gate_stale_m('$m');
}

/// Reclassifies a persisted `scanning` stamp that no live scan backs.
///
/// The stamp is cleared only when a scan completes successfully over that whole
/// subtree, so a failed child listing, a stopped run or a run superseded by a
/// newer one leaves it behind. Claiming "being scanned" for it is doubly wrong:
/// nothing is running, and that dialog hides the rescan button — the directory
/// then can never be repaired from the gate. Never-fully-scanned is the honest
/// reading, and it offers the full rescan.
DirScanGateStatus resolveLiveScanStatus(
  DirScanGateStatus status, {
  required bool scanLive,
}) {
  if (status != DirScanGateStatus.scanning || scanLive) return status;
  return DirScanGateStatus.unscanned;
}

/// True while the shared scan store is actually scanning [dir]'s root.
///
/// Liveness is ROOT-scoped, not storage-scoped: the store is single-flight but a
/// run scans one specific root set (`depthPaths`), so scanning `D:/A` must not
/// mark a sibling `D:/B` on the same storage as live — that would skip `D:/B`'s
/// scan-now and silently abort the play (the same-storage multi-root hazard).
bool _scanIsLiveFor(ScenarioSourceSpec dir) {
  final store = useRecursiveScanStore();
  return isScanLiveForState(
    isScanning: store.isScanning,
    runningStorageId: store.state.storageId,
    runningRoots: store.state.depthPaths[0] ?? const <String>[],
    storageId: dir.storageId,
    root: _effectiveScanRoot(dir),
  );
}

/// The absolute domain root a gate dir scans: its own path, or the storage base
/// for the whole-storage (`''`) marker.
///
/// A spec path may be storage-relative (media-library sources) or
/// base-inclusive (drag-drop / node selections); both are normalized to the
/// absolute form the scan service and the running-root comparison expect.
String _effectiveScanRoot(ScenarioSourceSpec dir) {
  final storage = useStorageStore().findById(dir.storageId);
  if (dir.path.isEmpty) {
    return storage == null ? '' : storage.basePath.join('/');
  }
  return StoragePathCodec.absolutize(dir.storageId, canonicalDbPath(dir.path));
}

/// Pure liveness check: [root] is live only when [runningStorageId] matches AND
/// one of the [runningRoots] actually COVERS it.
///
/// Covers = ancestor-or-equal: a running `D:/A` covers `D:/A` and `D:/A/sub`
/// but not a sibling `D:/B`. A null running id (transient inside `startScan`)
/// and an empty root set are never live.
@visibleForTesting
bool isScanLiveForState({
  required bool isScanning,
  required String? runningStorageId,
  required List<String> runningRoots,
  required String storageId,
  required String root,
}) {
  if (!isScanning) return false;
  if (runningStorageId == null || runningStorageId != storageId) return false;
  if (runningRoots.isEmpty) return false;
  return runningRoots.any((r) => _gatePathCovers(r, root));
}

/// Roots that are NOT backed by a live scan (i.e. safe to start now).
///
/// Pure and `@visibleForTesting`. The shared scan store is single-flight, so
/// re-scanning a root already covered by the running scan would reset its
/// progress and interleave DB writes; the gate dialog still counts live roots,
/// but execution must skip them.
@visibleForTesting
List<ScenarioSourceSpec> filterLiveScanRoots(
  List<ScenarioSourceSpec> dirs,
  bool Function(ScenarioSourceSpec dir) isLive,
) {
  return dirs.where((d) => !isLive(d)).toList(growable: false);
}

/// Ancestor-collapses the gate scopes per storage so one recursive scan can
/// cover several dropped folders (a parent marks every descendant `scanDone`).
///
/// Pure and `@visibleForTesting`. Non-recursive scopes never gate and are
/// dropped from the result. The storage root (`''`) covers its whole storage.
List<ScenarioSourceSpec> collapseGateDirs(List<ScenarioSourceSpec> dirs) {
  final byStorage = <String, List<String>>{};
  for (final dir in dirs) {
    if (!dir.recursive) continue;
    byStorage.putIfAbsent(dir.storageId, () => []).add(dir.path);
  }
  final out = <ScenarioSourceSpec>[];
  for (final entry in byStorage.entries) {
    final sorted = [...entry.value]
      ..sort((a, b) => a.length.compareTo(b.length));
    final kept = <String>[];
    for (final path in sorted) {
      if (kept.any((k) => _gatePathCovers(k, path))) continue;
      kept.add(path);
    }
    for (final path in kept) {
      out.add((
        storageId: entry.key,
        path: path,
        recursive: true,
        kind: ScenarioSourceKind.folder,
      ));
    }
  }
  return out;
}

/// Whether [path] rides a case-insensitive filesystem, so its gate scopes must
/// fold case when deciding ancestor coverage.
///
/// Only Windows volume paths fold: drive-letter (`C:/...`) and UNC
/// (`//server/share/...`) forms ride NTFS/SMB. POSIX paths, Android SAF tree
/// prefixes (`content://...`) and remote-server paths are case-sensitive —
/// folding them would collapse two genuinely distinct folders differing only by
/// case and silently drop one from the chained scan batch (the "one dropped
/// folder is never scanned" hazard). Shared with the rescan presence check
/// ([pathRidesCaseInsensitiveFs]).
bool _gatePathFoldsCase(String path) => pathRidesCaseInsensitiveFs(path);

bool _gatePathCovers(String ancestor, String path) {
  if (ancestor.isEmpty) return true; // storage root covers everything
  final fold = _gatePathFoldsCase(ancestor);
  final a = fold ? ancestor.toLowerCase() : ancestor;
  final p = fold ? path.toLowerCase() : path;
  return p == a || p.startsWith('$a/');
}

/// Whether a top-level play action should run the scan gate.
///
/// The resume path ([skipGate] true) re-runs an action's tail AFTER its chained
/// scan batch finished. The user already chose 立即完整扫描, so the gate must not
/// run again: a root whose scan failed would otherwise re-open the same dialog
/// on every resume (the "scan never seems to take effect" loop).
bool shouldRunScanGate({
  required bool skipGate,
  required bool hasRecursiveDirs,
}) =>
    !skipGate && hasRecursiveDirs;

/// Playback gate: checks every recursive directory against its scan status.
///
/// Returns an outcome describing whether playback may proceed now, or — when a
/// scan took over — the future that settles when THAT work is done, so the
/// caller can resume its own action against it.
///
/// Fresh (`done`) directories pass silently. ONE dialog covers the whole gated
/// set, and its scan-now scans every gated root (chained), so a drop of many
/// unscanned folders never stacks dialogs.
///
/// The returned resume anchor is bound to the ONE action that asked: it is the
/// chain of the freshly started batch AND any already-running scan that covers
/// a gated root. Reading a shared/global slot at completion time is what used to
/// lose the play (a concurrent or superseded run settled first and consumed it).
///
/// [silentUnscanned] makes a merely-never-scanned batch increment silently: the
/// action that triggered the gate cannot be answered without those rows anyway,
/// and the scan is scoped to exactly those roots, so asking "scan the whole
/// folder first?" on every newly-touched path is friction, not a decision. Only
/// a batch whose every gated root is `notScan` takes this path — a
/// stale/errored/live root is still a real choice and keeps the dialog. The
/// silent run is chained through the SAME settle anchor, so the caller's resume
/// is unchanged.
///
/// [ask] false makes the whole gate silent (`playback.dropAutoScan`): ANY status
/// — unscanned, stale, errored or already live — skips the dialog and is either
/// scanned now or awaited. Use it only where the triggering gesture was already
/// the play request (the desktop drop). A batch that cannot start a scan gets
/// one error prompt instead of the dialog, and the action stays aborted (a
/// resume would only stack a "nothing to play" dialog).
Future<ScanGateOutcome> ensureDirsScannedDetailed(
  BuildContext context,
  List<ScenarioSourceSpec> dirs, {
  bool silentUnscanned = false,
  bool ask = true,
}) async {
  final reminder = await scanReminderMinutes();
  final now = DateTime.now();
  final gated = <ScenarioSourceSpec, DirScanGateStatus>{};

  for (final dir in collapseGateDirs(dirs)) {
    final status = resolveLiveScanStatus(
      await _statusOf(dir, now, reminder),
      scanLive: _scanIsLiveFor(dir),
    );
    if (status == DirScanGateStatus.done) continue;
    gated[dir] = status;
  }
  if (gated.isEmpty) return const ScanGateOutcome.proceed();
  if (!context.mounted) return const ScanGateOutcome.cancelled();

  final silentAll = !ask;
  if (silentAll ||
      (silentUnscanned &&
          gated.values.every((s) => s == DirScanGateStatus.unscanned))) {
    final start = await _startScansFor(
      context,
      gated.keys.toList(growable: false),
      silentOptions: true,
    );
    if (start != null) return ScanGateOutcome.scanning(start.settled);
    // Nothing could start (no resolvable storage / user cancelled a prompt that
    // a live run still needed).
    if (silentAll) {
      // No dialogs by policy, but silently doing nothing is worse: state the
      // reason and abort. A resume here would only stack a second "nothing to
      // play" prompt on top of this one.
      if (context.mounted) {
        final t = getLocalizations(context);
        await showCopyableErrorDialog(
          context,
          title: t.scan_error_title,
          message: t.scan_cannot_start,
        );
      }
      return const ScanGateOutcome.cancelled();
    }
    // silentUnscanned: fall through to the dialog rather than leaving the action
    // silently dead.
  }
  if (!context.mounted) return const ScanGateOutcome.cancelled();

  // One dialog for the whole batch: prefer an actionable status (unscanned /
  // error / stale) so scan-now can cover every not-yet-scanned root; only when
  // a live scan already owns every root do we show the non-actionable
  // `scanning` dialog (which hides scan-now).
  final actionable =
      gated.entries.where((e) => e.value != DirScanGateStatus.scanning);
  final entry = actionable.isNotEmpty ? actionable.first : gated.entries.first;
  final liveCount =
      gated.values.where((s) => s == DirScanGateStatus.scanning).length;
  return _showGateDialog(
    context,
    entry.key,
    entry.value,
    roots: gated.keys.toList(growable: false),
    liveCount: liveCount,
  );
}

Future<DirScanGateStatus> _statusOf(
  ScenarioSourceSpec dir,
  DateTime now,
  int reminderMinutes,
) async {
  final row =
      await DbModule.mediaNodesDao.dirScanStatus(dir.storageId, dir.path);
  return classifyDirScanStatus(
    state: row?.state,
    lastScanAt: row?.lastScanAt,
    now: now,
    reminderMinutes: reminderMinutes,
  );
}

Future<ScanGateOutcome> _showGateDialog(
  BuildContext context,
  ScenarioSourceSpec dir,
  DirScanGateStatus status, {
  required List<ScenarioSourceSpec> roots,
  int liveCount = 0,
}) async {
  final t = getLocalizations(context);
  final label = _dirLabel(dir, t);
  // A drop of several unscanned folders shows ONE dialog: a generic count
  // message when more than one root is gated (scan-now scans them all).
  // Mixed batches (actionable + live) keep scan-now but warn that starting
  // now interrupts the live scan — the store is single-flight, so the live
  // roots are skipped by execution yet still aborted by the reset.
  final (title, body) = roots.length > 1 &&
          status != DirScanGateStatus.scanning
      ? (
          t.gate_multi_title,
          liveCount > 0
              ? '${t.gate_multi_body(roots.length)}\n\n'
                  '${t.gate_multi_interrupt_warn(liveCount)}'
              : t.gate_multi_body(roots.length),
        )
      : switch (status) {
          DirScanGateStatus.unscanned => (
              t.gate_unscanned_title,
              t.gate_unscanned_body(label),
            ),
          DirScanGateStatus.scanning => (
              t.gate_scanning_title,
              t.gate_scanning_body(label),
            ),
          DirScanGateStatus.error => (
              t.gate_error_title,
              t.gate_error_body(label),
            ),
          DirScanGateStatus.stale => (
              t.gate_stale_title,
              t.gate_stale_body(
                  label, formatStaleness(await _stalenessOf(dir), t)),
            ),
          DirScanGateStatus.done => ('', ''),
        };
  if (!context.mounted) return const ScanGateOutcome.cancelled();

  final choice = await showDialog<DirScanGateChoice>(
    context: context,
    builder: (_) => buildScanGateDialog(
      title: title,
      body: body,
      status: status,
      playAnywayLabel: t.gate_play_anyway,
      cancelLabel: t.cancel,
      scanNowLabel: t.gate_scan_now,
      onChoice: (choice) => Navigator.of(context).pop(choice),
    ),
  );

  switch (choice) {
    case DirScanGateChoice.playAnyway:
      return const ScanGateOutcome.proceed();
    case DirScanGateChoice.scanNow:
      if (!context.mounted) return const ScanGateOutcome.cancelled();
      final start = await _startScansFor(context, roots);
      // Only hand back a resume anchor when scan work is genuinely in flight.
      // If the user cancelled the options dialog (or no storage could be
      // resolved), no scan took over — arming a resume would later play
      // something the user never confirmed.
      if (start == null) return const ScanGateOutcome.cancelled();
      return ScanGateOutcome.scanning(start.settled);
    case DirScanGateChoice.cancel:
    case null:
      return const ScanGateOutcome.cancelled();
  }
}

/// The scan-gate decision dialog for [status].
///
/// Extracted and visible so the widget test can pump every status directly
/// (no DB fixture): every status must offer 取消 — including `scanning`, where
/// the user must be able to back out instead of being forced to "play anyway".
/// "立即完整扫描" is meaningless while a scan is already running, so it stays
/// hidden for [DirScanGateStatus.scanning].
@visibleForTesting
Widget buildScanGateDialog({
  required String title,
  required String body,
  required DirScanGateStatus status,
  required String playAnywayLabel,
  required String cancelLabel,
  required String scanNowLabel,
  required ValueChanged<DirScanGateChoice> onChoice,
}) {
  return AlertDialog(
    title: Text(title),
    content: Text(body),
    actions: [
      TextButton(
        onPressed: () => onChoice(DirScanGateChoice.playAnyway),
        child: Text(playAnywayLabel),
      ),
      TextButton(
        onPressed: () => onChoice(DirScanGateChoice.cancel),
        child: Text(cancelLabel),
      ),
      if (status != DirScanGateStatus.scanning)
        FilledButton(
          onPressed: () => onChoice(DirScanGateChoice.scanNow),
          child: Text(scanNowLabel),
        ),
    ],
  );
}

Future<Duration> _stalenessOf(ScenarioSourceSpec dir) async {
  final row =
      await DbModule.mediaNodesDao.dirScanStatus(dir.storageId, dir.path);
  final last = row?.lastScanAt;
  if (last == null) return Duration.zero;
  return DateTime.now().difference(last);
}

/// Result of [_startScansFor]: the settle anchor of the scan work that is now
/// in flight.
///
/// A wrapper (rather than a bare `Future<Future<void>?>`) is deliberate:
/// `await` FLATTENS a future that completes with another future, so a nested
/// return silently degenerated to `null` — the pending play was then never
/// armed and the drop that triggered a scan never resumed. Keeping the future
/// inside a plain object makes the value unambiguous.
class _ScanStart {
  const _ScanStart(this.settled);

  /// Completes with `true` when at least one root this action waited for
  /// produced playable rows.
  final Future<bool> settled;
}

/// Starts background recursive scans for every gated [dirs] root, chained so
/// the shared scan store stays single-flight.
///
/// Live roots (backed by the running scan) are skipped — re-scanning one
/// would reset its progress and interleave DB writes.
///
/// Returns the settle anchor (see [_ScanStart]) of every run this action now
/// depends on — the freshly started batch AND any already-running scan that
/// covers a gated root ([RecursiveScanStore.playableSettled]) — or null when no
/// scan work is in flight at all (nothing live, no resolvable storage, or the
/// user cancelled the scan-options dialog). Callers must NOT resume on null.
///
/// The fresh batch contributes one anchor PER ROOT: a multi-folder action
/// resumes when its last root is playable, not when the first one is.
///
/// Waiting for an already-live run instead of returning null is deliberate: the
/// store's phase stamp can lag a just-started run (the DB row is still
/// `notScan`), so the gate offers scan-now while that run is already refreshing
/// the same root. Returning null there silently swallowed the user's play.
///
/// One options dialog covers the whole batch (probe default ON). The scan
/// mutates `media_nodes`; each storage is announced as its scan finishes so the
/// derived queue index and any open queue view pick up the new content.
///
/// [silentOptions] skips that dialog (silent incremental scans reuse the last
/// confirmed probe choice) so a drop never stacks a second prompt on top of the
/// play it already asked for.
///
/// FAILURES ARE NEVER SILENT: every started run is playback-originated, hence
/// quiet, and a quiet run deliberately never opens the overlay's error dialog
/// (it would interrupt the video). The batch therefore reports its own failure
/// once — [showCopyableErrorDialog] — and the anchor completes with `false` when
/// NO root produced playable rows, so the caller skips the resume instead of
/// stacking a misleading "nothing to play" dialog on the error.
Future<_ScanStart?> _startScansFor(
  BuildContext context,
  List<ScenarioSourceSpec> dirs, {
  bool silentOptions = false,
}) async {
  final pending = filterLiveScanRoots(dirs, _scanIsLiveFor);
  // Anchor to the runs already in flight BEFORE starting anything new: a new
  // run resets the store and would complete (release) the previous waiter.
  final liveSettled = <Future<void>>[
    for (final dir in dirs)
      if (_scanIsLiveFor(dir)) useRecursiveScanStore().playableSettled,
  ];
  if (pending.isEmpty) {
    // Nothing to start — every gated root is already covered by a running scan.
    // Hand back those runs so the action resumes when they settle.
    if (liveSettled.isEmpty) return null;
    return _ScanStart(
      Future.wait<void>(liveSettled).then((_) => true),
    );
  }
  final resolvable = <(Storage, ScenarioSourceSpec)>[];
  for (final dir in pending) {
    final storage = useStorageStore().findById(dir.storageId);
    if (storage != null) resolvable.add((storage, dir));
  }
  if (resolvable.isEmpty) return null; // cannot scan without a storage

  // Same options dialog as manual scans, probe default ON (see dialog).
  //
  // A silent incremental scan must not stack a second dialog on top of the
  // action it was triggered by: it reuses the last confirmed probe choice
  // (default ON) instead of asking again.
  final bool probe;
  if (silentOptions) {
    probe = (await ScanProbePreference.load()) ?? true;
  } else {
    final choice = await showScanOptionsDialog(
      context,
      storage: resolvable.first.$1,
      scope: ScanInfoScope.sources,
    );
    if (choice == null || !context.mounted) return null; // cancelled → no scan
    probe = choice;
  }

  final scanStore = useRecursiveScanStore();
  // Resume anchor: EVERY resolvable root's "playable" point, i.e. metadata-
  // complete for a small local scope and enumeration-complete for a large /
  // network one. It is captured from each run itself (the service fires
  // `onScanStarted` once it is registered), never from a shared global slot.
  //
  // Waiting for the first root only was wrong for a multi-folder action: the
  // batch is chained, so the queue was built from a partial list (and, when the
  // first folder happened to be empty, the play reported "no playable content"
  // although a later root had files). A root whose run never registers or
  // throws is classified by the per-root fallbacks below.
  //
  // The anchor carries the batch's OUTCOME, not just its completion: a totally
  // failed drop must not resume (the failure prompt below already explains why
  // nothing plays), and a partial one must still play what was indexed.
  final playable = Completer<bool>();
  final playablePending = resolvable.length;
  var playableReached = 0;
  var playableSuccesses = 0;
  var failures = 0;
  String? failureMessage;

  void releaseAnchor() {
    if (!playable.isCompleted) playable.complete(playableSuccesses > 0);
  }

  /// Counts one root exactly once for the resume anchor and records whether it
  /// produced playable rows.
  void accountRoot({required bool failed, String? error}) {
    if (failed) {
      failures++;
      failureMessage ??= error;
    } else {
      playableSuccesses++;
    }
    playableReached++;
    if (playableReached >= playablePending) releaseAnchor();
  }

  /// One prompt per batch, deduped: the playable-time and batch-end checks must
  /// never stack two dialogs. A quiet run's own overlay never prompts, so this
  /// is the ONLY place a failed drop-scan is announced.
  var failurePrompted = false;
  Future<void> promptFailureOnce() async {
    if (failurePrompted || failures == 0) return;
    failurePrompted = true;
    if (!context.mounted) return;
    final t = getLocalizations(context);
    await showCopyableErrorDialog(
      context,
      title: t.scan_error_title,
      message: t.scan_status_error(
        // NOT `scanStore.state.error`: the store is shared, so by the time the
        // batch ends it may already describe a NEWER run and the prompt would
        // blame the wrong one (or lose the message). Each root captured its own
        // error when it was classified.
        failureMessage ?? t.scan_error_unknown,
      ),
    );
  }

  final batch = () async {
    for (final (storage, dir) in resolvable) {
      // A root may be classified twice: at its playable point and again after
      // its run returns. Only the first classification counts.
      var accounted = false;
      void accountOnce({required bool failed, String? error}) {
        if (accounted) return;
        accounted = true;
        accountRoot(failed: failed, error: error);
      }

      final service = RecursiveScanService(
        storage: storage,
        scanStore: scanStore,
        nodesDao: DbModule.mediaNodesDao,
        sourcesDao: DbModule.mediaLibSourcesDao,
        probeService: probe ? createMediaProbeService() : null,
        playbackOriginated: true,
        onScanStarted: () {
          // Rows are final at `playableSettled` (metadata for a small scope,
          // enumeration otherwise). Announce THEN so the derived queue index
          // and any open queue view are rebuilt from the new rows before the
          // action resumes — the batch's own announce only happens at full
          // completion, which a large scope deliberately does not wait for.
          scanStore.playableSettled.then((_) async {
            // Classify BEFORE awaiting the announce: the anchor must not wait
            // on a DB write, and a failed run is already `error` here.
            accountOnce(
              failed: scanStore.state.phase == ScanPhase.error,
              error: scanStore.state.error,
            );
            try {
              await MediaRevisionActions.mediaNodesChanged([storage.id]);
            } catch (_) {
              // Never swallow the resume on a failed announce.
            } finally {
              // Playback is about to start: the panel has served its purpose and
              // must not stay over the video while the aggregate / metadata tail
              // finishes.
              scanStore.dismissQuietPanel();
            }
          });
        },
      );
      final rootPath = _effectiveScanRoot(dir);
      if (!context.mounted) return;
      try {
        final runner = debugScanRunner;
        if (runner != null) {
          await runner(service, [rootPath], context);
        } else {
          await service.scanRecursively(
              rootPaths: [rootPath], context: context);
        }
      } catch (e) {
        // One failed root must not stop the rest of the batch, but it must be
        // reported rather than swallowed.
        accountOnce(failed: true, error: e.toString());
      }
      // Covers a run that never fired `onScanStarted` (nothing started / a test
      // runner replaced the scan): its terminal state is the only signal left.
      if (!accounted) {
        accountOnce(
          failed: scanStore.state.phase == ScanPhase.error,
          error: scanStore.state.error,
        );
      }
      await MediaRevisionActions.mediaNodesChanged([storage.id]);
    }
  }();
  // Fallback: a run that never registers still releases the anchor when the
  // batch is over. The batch also owns the quiet panel's dismissal: quiet runs
  // never count down (one panel for the whole batch, no flicker between chained
  // roots).
  unawaited(batch.whenComplete(() {
    releaseAnchor();
    _dismissQuietCompletion(scanStore);
    unawaited(promptFailureOnce());
  }));

  Future<bool> anchor() async {
    final anyFreshPlayable = await playable.future;
    if (liveSettled.isEmpty) return anyFreshPlayable;
    await Future.wait<void>(liveSettled);
    // An already-running scan is presumed to produce the rows this action
    // waits for; its own batch surfaces its own failure.
    return true;
  }

  return _ScanStart(anchor());
}

/// Closes the progress panel a playback-originated run left behind.
///
/// Quiet runs never auto-close, so the batch that started them owns the
/// cleanup. The panel itself is usually already hidden by the time playback
/// resumed ([RecursiveScanStore.dismissQuietPanel]); this still resets the run
/// state so no `done` panel is left for the next action to inherit.
///
/// An `error` panel is deliberately kept: the user has to see why the scan
/// failed.
void _dismissQuietCompletion(RecursiveScanStore scanStore) {
  if (!scanStore.quietCompletion) return;
  final phase = scanStore.state.phase;
  if (phase == ScanPhase.done || phase == ScanPhase.stopped) {
    unawaited(scanStore.resetScan());
  }
}

/// Test seam: runs one root's scan.
///
/// Production leaves this null and uses [RecursiveScanService.scanRecursively]
/// directly; tests replace it to drive a deterministic scan (no filesystem, no
/// probe) while exercising the real gate/resume wiring.
@visibleForTesting
Future<void> Function(
  RecursiveScanService service,
  List<String> rootPaths,
  BuildContext context,
)? debugScanRunner;

String _dirLabel(ScenarioSourceSpec dir, AppLocalizations t) =>
    dir.path.isEmpty ? t.gate_storage_root : dir.path;

/// The user's answer in [buildScanGateDialog]: proceed with the play, start a
/// full scan first, or abort. Public so the dialog builder can be tested.
enum DirScanGateChoice { playAnyway, scanNow, cancel }

/// Runs the scan gate for a playback action and keeps a [PendingPlayIntent]
/// that resumes the interrupted playback once the scan settles.
///
/// This is the fix for "override play is lost after an on-demand scan": a
/// playback action blocked by an unscanned directory must survive the scan —
/// otherwise the user's tap does nothing after scanning completes.
///
/// No confirmation is asked afterwards: the play request was already explicit,
/// and a second "continue playing?" prompt is exactly the friction a drop or a
/// folder tap must not have. A merely never-scanned batch skips the gate dialog
/// too ([silentUnscanned]) — it is not a decision, just a first increment;
/// stale/errored/live roots still ask, because "scan this again?" is a real
/// choice.
///
/// [dirs] are the recursive scopes that gate playback; [playOnScanNow] repeats
/// the original action with the SAME captured parameters. Rerunning after the
/// scan naturally passes the gate (the directory is now `scanDone`), so no
/// force flag is needed.
///
/// The intent is bound to THIS action's own settle future ([ScanGateOutcome.
/// scanSettled]) and held in a local closure — never in a shared slot — so a
/// concurrent (or superseded) scan settling first can neither consume nor clear
/// it.
///
/// Returns true when playback may proceed immediately (fresh dirs, or the user
/// chose play-anyway); false when the scan took over (caller must NOT play now).
/// Alias of [ensureDirsScannedWithAutoPlay] kept for call-site intent (the
/// override/append actions vs the desktop drop).
///
/// The two converged when the silent increment was unified — a merely
/// never-scanned root is not a decision on either path — so this must delegate
/// rather than fork again; a fix applied to one of them has to reach both.
Future<bool> ensureDirsScannedWithPendingPlay(
  BuildContext context,
  List<ScenarioSourceSpec> dirs, {
  required Future<void> Function() playOnScanNow,
}) =>
    ensureDirsScannedWithAutoPlay(
      context,
      dirs,
      playOnScanNow: playOnScanNow,
    );

/// Silent variant for the desktop drag-drop path, where the drop itself was the
/// explicit user gesture: it increments a merely-unindexed folder without the
/// gate dialog and resumes straight into playback once the scan settles.
///
/// Asking again after the scan only risks losing the play (the reported "drop
/// triggers a scan but never plays; dropping again works").
///
/// It ALSO increments silently: a dropped folder that was simply never indexed
/// (a new subdirectory, or one the user never visited) is scanned on the spot
/// instead of opening the "scan fully now?" gate — every different path of the
/// same storage used to demand that dialog even though the scan it starts only
/// covers that dropped root.
///
/// [ask] false drops the gate dialog for EVERY status (see
/// [ensureDirsScannedDetailed]); the desktop drop reads
/// `AppState.dropAutoScan` and passes `!dropAutoScan` so a modern, few-second
/// local scan no longer costs the user a decision.
Future<bool> ensureDirsScannedWithAutoPlay(
  BuildContext context,
  List<ScenarioSourceSpec> dirs, {
  required Future<void> Function() playOnScanNow,
  bool ask = true,
}) =>
    _gateWithResume(
      context,
      dirs,
      resume: playOnScanNow,
      silentUnscanned: true,
      ask: ask,
    );

Future<bool> _gateWithResume(
  BuildContext context,
  List<ScenarioSourceSpec> dirs, {
  required Future<void> Function() resume,
  bool silentUnscanned = false,
  bool ask = true,
}) async {
  final outcome = await ensureDirsScannedDetailed(
    context,
    dirs,
    silentUnscanned: silentUnscanned,
    ask: ask,
  );
  final settled = outcome.scanSettled;
  if (settled != null) {
    final intent = PendingPlayIntent(resume: resume);
    // A scan run can surface a storage failure; nothing may escape as an
    // unhandled async error, and `catchError` normalizes a thrown anchor to
    // `false`. A `false` anchor means NO root produced playable rows: the batch
    // already raised the one scan-error prompt, so resuming would only stack a
    // misleading "nothing to play" dialog on top of it.
    unawaited(settled.catchError((Object _) => false).then((ok) {
      if (!ok) return;
      if (!context.mounted) return; // caller already left the screen
      unawaited(_resumePending(context, intent));
    }));
  }
  return outcome.proceed;
}

/// Runs a pending intent, surfacing a failure as the uniform copyable error
/// dialog instead of an unhandled async error.
///
/// A resume re-runs the ORIGINAL action with `force:false`, so it can
/// legitimately throw [PlaybackUnavailableException] when the completed scan
/// still leaves the scope empty (e.g. a folder with no in-scope media).
Future<void> _resumePending(
  BuildContext context,
  PendingPlayIntent intent,
) async {
  try {
    await intent.resume();
  } catch (e) {
    if (!context.mounted) return;
    final t = getLocalizations(context);
    final message = e is PlaybackUnavailableException
        ? e.displayMessage(t)
        : t.dlg_play_failed_prefix('$e');
    await showCopyableErrorDialog(
      context,
      title: t.dlg_copy_error_title,
      message: message,
    );
  }
}
