import 'package:iris/features/media_library/model/db/repositories/sub/progress_write_guard.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/media_progress_claim.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/logger.dart';

// The head-window guard lives next to the write funnel it also protects
// (progress_write_guard.dart); re-exported here so existing importer patterns
// keep working.
export 'package:iris/features/media_library/model/db/repositories/sub/progress_write_guard.dart';

final areaKeyLog = AreaKeyLog(LogKeys.legacyScenario);

/// Global per-file playback progress helpers (uniform across all scenarios).
///
/// Progress is stored on the media_nodes row, NOT per scenario. Entries without
/// a media node (URLs, SAF URIs) fall back to HistoryStore, so these helpers
/// return false / null for those.
///
/// NOTE: the media scanner's upsert never overwrites playback_* columns
/// (rescan-preserving rule), so writes here survive rescans.

/// Safe resume margin: saved positions within this distance of the media end
/// are clamped back to the tail instead of being restored verbatim.
/// Resuming at/after the tail makes the player immediately emit `completed`
/// and auto-advance past the file ("jump to end" bug). Mirrors the 5s rule
/// already used by the HistoryStore fallback in the player hooks.
const int resumeEndSafetyMs = 5000;

/// Returns the resume target (ms) for a media of [durationMs], or `null` when
/// there is nothing to restore (callers then fall back to HistoryStore).
///
/// Positions at/after the end (or within the last [resumeEndSafetyMs]) are
/// clamped to `durationMs - resumeEndSafetyMs` so playback plays the final
/// seconds and completes normally instead of instantly completing on open.
int? clampResumePosition(int? positionMs, int durationMs) {
  if (positionMs == null || positionMs <= 0) return null;
  if (durationMs <= 0) return positionMs;
  final tailStart = durationMs - resumeEndSafetyMs;
  if (positionMs >= tailStart) return tailStart.clamp(0, durationMs);
  return positionMs;
}

/// Head-window guard thresholds and the head write guard itself live in
/// progress_write_guard.dart (re-exported above).

/// Landing tolerance: after a seek, the player must be OBSERVED once within
/// this window of the locked target before progress writes resume.
const int positionLockLandingToleranceMs = 2000;

/// How far PAST the locked target the position must have played before the
/// landing counts as REAL.
///
/// A sample sitting on the target is not proof: mpv reports `last_seek_pts`
/// (the requested position) through `time-pos` as soon as a seek is queued,
/// before a single frame is decoded. Accepting that echo is what let a media
/// which restarted at the head — the Android video output attaches ~1s after
/// the resume seek and re-inits the track — unlock its write window and then
/// persist the head position. Real decoding is only proven once playback has
/// moved past the intent (the end of the media counts too, see
/// [isLandingConfirmed]).
const int positionLockLandingAdvanceMs = 400;

/// A sample this far BEHIND the locked target, AFTER a landing-shaped sample
/// was already observed, means the engine restarted the media from the head
/// instead of playing on from the seek target (field log: `lock landed
/// pos=319799ms` then `watch t=2 pos=580ms playing=true` with the picture back
/// at the beginning while the DB still held 319799).
const int positionLockRestartDropMs = 3000;

/// How many times a detected restart may be answered with a re-issued intent
/// seek before the lock gives up. Bounded on purpose: a save must never stay
/// frozen for the rest of the session.
const int positionLockMaxRestartSeeks = 3;

/// Landing window for a head target (a from-the-beginning open starts at 0
/// and its first ticks report a few hundred ms).
const int positionLockHeadLandingMaxMs = 2500;

/// Fail-open timeouts: a pending lock (target not yet decided) releases
/// after this long without a duration/resume decision; a locked lock
/// re-issues its seek once after [positionLockLockedTimeout] and releases
/// after another window without a landing.
const Duration positionLockPendingTimeout = Duration(seconds: 8);
const Duration positionLockLockedTimeout = Duration(seconds: 5);

/// How long a restart is watched for after an intent is armed.
///
/// The Android video output attaches ~1s after the resume seek, so the watch
/// only has to outlive that attach plus a stalled seek landing. It must NOT be
/// tied to the write lock: the lock releases on a paused landing (immediately)
/// and the captured restart happened while paused.
const Duration positionLockWatchWindow = Duration(seconds: 12);

/// Pure decision: has the player been observed at/near the locked target?
bool isLandingAt({
  required int posMs,
  required int targetMs,
  required int durationMs,
}) {
  // The very end of the file counts as reached-or-passed for any target: a
  // lock stuck there would block the completed-path writes.
  if (durationMs > 0 && posMs >= durationMs - 500) return true;
  if (targetMs <= 0) {
    return posMs >= 0 && posMs <= positionLockHeadLandingMaxMs;
  }
  return posMs >= targetMs - positionLockLandingToleranceMs &&
      posMs <= targetMs + positionLockLandingToleranceMs;
}

/// Whether a tolerated sample CONFIRMS the landing, i.e. proves that the
/// player is really decoding from the intent rather than merely echoing the
/// seek request (`last_seek_pts`).
///
/// * a head intent (target within the landing tolerance) has nothing to
///   decode past — the first tolerated sample confirms it;
/// * the very end of the media confirms any target (see [isLandingAt]);
/// * otherwise playback must have advanced past the target by
///   [positionLockLandingAdvanceMs].
bool isLandingConfirmed({
  required int posMs,
  required int targetMs,
  required int durationMs,
}) {
  if (!isLandingAt(posMs: posMs, targetMs: targetMs, durationMs: durationMs)) {
    return false;
  }
  if (durationMs > 0 && posMs >= durationMs - 500) return true;
  if (targetMs <= positionLockLandingToleranceMs) return true;
  return posMs >= targetMs + positionLockLandingAdvanceMs;
}

/// Whether a `completed` event that was suppressed during a scrub may be
/// flushed now that the finger/pointer state changed.
///
/// A drag can touch the media end (100%) at any moment, raising `completed`,
/// then return to a mid position before release. Both backends reset their
/// completion flag on every `seek`, so a stale latch would otherwise advance to
/// the next segment/file even though the release target is NOT the end (the
/// "touch 100%, come back to 50%, still jumps" defect). Honouring the latch
/// only while the media is STILL completed makes the release position decide
/// playback: mid-file releases continue there, a release on the end advances.
bool shouldFlushSuppressedCompletion({
  required bool pendingCompleted,
  required bool holding,
  required bool completed,
}) =>
    pendingCompleted && !holding && completed;

/// Sanitized position for display/persistence: clamped to [0, dur], and
/// large backward regressions (position-source glitches for files with
/// broken timestamps) are rejected unless a user seek just happened or this
/// is the first sample.
///
/// While a position-intent lock is in flight ([inFlightTargetMs] != null)
/// the raw sample may legitimately lag the intent (pre-land ticks) or lead
/// it (a stale high watermark left by an earlier tick, e.g. a scrubber's
/// throttled live target superseded by the release commit). The legacy flat
/// 2s rule pinned whichever came first and surfaces visibly jumped on
/// release. With the target known, raw on the way from [lastSane] to the
/// target (either direction) is accepted; everything else keeps the legacy
/// guard. The landing check ([PlaybackPositionLock.checkLanding]) remains
/// the sole validator that releases the lock.
int sanePlaybackPos(
  int? lastSane,
  int raw,
  int dur, {
  required bool userSeeked,
  int? inFlightTargetMs,
}) {
  final int clamped = raw.clamp(0, dur);
  if (userSeeked) return clamped;
  final int? target = inFlightTargetMs;
  if (lastSane == null) {
    // First sample of a media. While an intent is in flight the player is still
    // reporting its pre-land head position (the seek target is echoed only
    // later), so this sample must never become the anchor: it used to seed
    // `lastSane` with ~580ms, and every following tick then followed it — the
    // progress UI reset to 0 while the DB row still held the real position
    // (field log: `t=1 pos=277156ms`, `t=2 pos=580ms`, no glitch line at all).
    if (target != null &&
        target > 0 &&
        clamped < target - positionLockLandingToleranceMs) {
      return target;
    }
    return clamped;
  }
  if (target != null) {
    final int lo = lastSane < target ? lastSane : target;
    final int hi = lastSane < target ? target : lastSane;
    if (clamped >= lo && clamped <= hi) return clamped;
  }
  if (clamped >= lastSane - 2000) return clamped;
  return lastSane;
}

/// Lock lifecycle: no intent (writes flow) → pending (open started, target
/// not yet decided, writes blocked) → locked (target known, writes blocked
/// until landing) → unlocked.
enum PositionLockPhase { pending, locked, unlocked }

enum PositionLockTimeoutAction { none, retrySeek, released }

/// Per-open position-intent lock (位置意图锁).
///
/// Replaces the issue-time [OpenResumeGate] semantics: while an explicit
/// position intent exists (open-resume target, VM pre-write, user seek, drag
/// release), ALL progress writes for the file are blocked until the player
/// has been OBSERVED once at the intended position — not merely until the
/// seek was issued. A failed or late seek can therefore never leave the
/// write window open for pre-land head samples (the "switch plays from
/// head" root cause), and a bounded timeout keeps a stuck lock from freezing
/// saves for the whole session.
class PlaybackPositionLock {
  PositionLockPhase _phase = PositionLockPhase.unlocked;
  int? _targetMs;
  DateTime? _phaseSince;
  bool _retryUsed = false;
  /// Restart-watch target and its window start.
  ///
  /// Deliberately independent of [_phase]: a paused open parks ON the target
  /// and never advances, so the write lock can only be released by the paused
  /// rule below — yet the engine still restarts the media about a second later
  /// (the Android video output attaches after the resume seek). Tying the watch
  /// to the write lock would either miss that restart or freeze saves for the
  /// whole fail-open window.
  int? _watchTargetMs;
  DateTime? _watchSince;
  /// The intent has been ANSWERED at least once (a sample inside the landing
  /// tolerance was seen). Only then can a far-behind sample be read as "the
  /// engine restarted", instead of "the seek has not landed yet".
  bool _landingSeen = false;
  /// Pending re-issue request, drained by [takeRestartSeek].
  bool _restartPending = false;
  int _restartSeeks = 0;

  PositionLockPhase get phase => _phase;
  int? get targetMs => _targetMs;
  /// The target a drained [takeRestartSeek] request must re-issue.
  ///
  /// Unlike [targetMs] this survives the write-lock release, which is exactly
  /// when a paused restart is detected.
  int? get restartSeekTargetMs => _watchTargetMs;
  /// The position the progress sanitizer should anchor on: the write-lock
  /// target, or the restart-watch target once the lock released but the engine
  /// is still being watched.
  ///
  /// The paused rule releases the write lock on the target echo, before any
  /// frame is decoded, so the sanitizer must keep anchoring on the resume point
  /// — otherwise a restarted head sample would seed the high-water mark.
  int? get intentTargetMs => _targetMs ?? _watchTargetMs;
  bool get watchingRestart => _watchTargetMs != null;
  bool get blocksWrites => _phase != PositionLockPhase.unlocked;

  void _resetLanding() {
    _landingSeen = false;
    _restartPending = false;
    _restartSeeks = 0;
  }

  void _clearWatch() {
    _watchTargetMs = null;
    _watchSince = null;
  }

  /// Open started, intent target not yet decided (DB read pending). Writes
  /// are blocked from this moment so a pre-decision sample can never land.
  void armPending({DateTime? now}) {
    _phase = PositionLockPhase.pending;
    _targetMs = null;
    _phaseSince = now ?? DateTime.now();
    _retryUsed = false;
    _clearWatch();
    _resetLanding();
  }

  /// The intent target is known (resume decision, VM pre-write, user seek,
  /// drag release). Writes stay blocked until a landing is observed.
  void armTarget(int targetMs, {DateTime? now}) {
    final at = now ?? DateTime.now();
    _phase = PositionLockPhase.locked;
    _targetMs = targetMs;
    _phaseSince = at;
    _retryUsed = false;
    _watchTargetMs = targetMs;
    _watchSince = at;
    _resetLanding();
  }

  /// Releases the write lock. The restart WATCH deliberately survives: the
  /// engine can restart AFTER the write window is gone (a paused open releases
  /// on the paused rule and is restarted a second later).
  void unlock() {
    _phase = PositionLockPhase.unlocked;
    _targetMs = null;
    _phaseSince = null;
    _retryUsed = false;
  }

  /// A user-initiated seek that does NOT arm the write lock (a ←/→ step: its
  /// keyframe landing is deliberately off-target) takes over the position
  /// intent.
  ///
  /// The write lock is released — the user's landing is authoritative — and the
  /// restart watch is dropped: a step lands on the PREVIOUS keyframe, seconds
  /// behind the pre-seek position, so "far behind the anchor" no longer proves
  /// an engine restart. Keeping the watch made a rewind inside the resume
  /// window get answered with a re-seek back to the old target (the rewind
  /// silently undid itself).
  void noteUserSeek() {
    _phase = PositionLockPhase.unlocked;
    _targetMs = null;
    _phaseSince = null;
    _retryUsed = false;
    _clearWatch();
    _resetLanding();
  }

  /// Returns true when THIS observation proved the landing and unlocked.
  ///
  /// A sample merely sitting on the target is NOT accepted while playing (see
  /// [isLandingConfirmed]): mpv echoes the requested position before decoding
  /// a frame, and accepting the echo let a media that restarted at the head
  /// unlock its write window. A PAUSED player can never advance past the
  /// target, so there a tolerated sample is the best proof available — the
  /// restart watch (not the lock) then guards the late restart.
  bool checkLanding(int posMs, int durationMs,
      {bool playing = true, DateTime? now}) {
    final at = now ?? DateTime.now();
    // The restart watch runs FIRST and independently of the write lock: it is
    // the only protection once the lock has been released.
    _detectRestart(posMs, durationMs, at);

    final target = _targetMs;
    if (_phase != PositionLockPhase.locked || target == null) return false;
    if (isLandingAt(
        posMs: posMs, targetMs: target, durationMs: durationMs)) {
      _landingSeen = true;
      if (playing &&
          !isLandingConfirmed(
              posMs: posMs, targetMs: target, durationMs: durationMs)) {
        return false;
      }
      unlock();
      return true;
    }
    return false;
  }

  /// Restart-watch half of [checkLanding]: once the intent has been ANSWERED,
  /// a sample far BEHIND the watched target means the engine restarted the
  /// media instead of playing on from it (the Android video output attaches
  /// after the resume seek and re-inits the track). Ask the caller to re-issue
  /// the intent seek rather than letting the restart stand.
  void _detectRestart(int posMs, int durationMs, DateTime at) {
    final watch = _watchTargetMs;
    final since = _watchSince;
    if (watch == null || since == null) return;
    // Fail-open: an unreachable target must not re-seek for the whole session.
    if (at.difference(since) > positionLockWatchWindow) {
      _clearWatch();
      return;
    }
    // The very end of the media counts as reached-or-passed for any target.
    if (durationMs > 0 && posMs >= durationMs - 500) {
      _clearWatch();
      return;
    }
    if (isLandingAt(posMs: posMs, targetMs: watch, durationMs: durationMs)) {
      _landingSeen = true;
      // A head intent has nothing to fall behind, and once playback really
      // moved past the target there is no restart left to catch.
      if (watch <= positionLockLandingToleranceMs ||
          posMs >= watch + positionLockLandingAdvanceMs) {
        _clearWatch();
      }
      return;
    }
    if (!_landingSeen) return; // the seek has not been answered yet
    if (watch <= positionLockLandingToleranceMs) {
      _clearWatch();
      return;
    }
    if (posMs < watch - positionLockRestartDropMs &&
        _restartSeeks < positionLockMaxRestartSeeks) {
      _restartSeeks++;
      _landingSeen = false;
      _restartPending = true;
      // Give the re-seek a fresh window to be observed in.
      _watchSince = at;
      if (_phase == PositionLockPhase.locked) {
        // The re-seek IS this window's retry: keep the fail-open window fresh
        // and stop [tickTimeout] from firing a second seek on top of it.
        _phaseSince = at;
        _retryUsed = true;
      }
    }
  }

  /// Consumes a "the engine restarted from the head — re-issue the intent
  /// seek" request. True exactly once per detected restart.
  bool takeRestartSeek() {
    if (!_restartPending) return false;
    _restartPending = false;
    return true;
  }

  /// Bounded fail-open: a pending lock releases after
  /// [positionLockPendingTimeout]; a locked lock re-issues its seek once
  /// ([PositionLockTimeoutAction.retrySeek]) and releases after another
  /// window without a landing. Also expires the restart watch.
  PositionLockTimeoutAction tickTimeout({DateTime? now}) {
    final at = now ?? DateTime.now();
    final watchSince = _watchSince;
    if (_watchTargetMs != null &&
        watchSince != null &&
        at.difference(watchSince) > positionLockWatchWindow) {
      _clearWatch();
    }
    final since = _phaseSince;
    if (_phase == PositionLockPhase.unlocked || since == null) {
      return PositionLockTimeoutAction.none;
    }
    if (_phase == PositionLockPhase.pending) {
      if (at.difference(since) < positionLockPendingTimeout) {
        return PositionLockTimeoutAction.none;
      }
      unlock();
      return PositionLockTimeoutAction.released;
    }
    if (at.difference(since) < positionLockLockedTimeout) {
      return PositionLockTimeoutAction.none;
    }
    if (!_retryUsed) {
      _retryUsed = true;
      _phaseSince = at;
      return PositionLockTimeoutAction.retrySeek;
    }
    unlock();
    return PositionLockTimeoutAction.released;
  }
}

/// Open-resume decision for a file being opened.
enum OpenResumeDecision {
  /// Seek to the carried target — the DB row is authoritative.
  seekDb,

  /// The DB row exists and explicitly says "at the beginning" (0): start
  /// from the head and do NOT resurrect a stale HistoryStore entry.
  fromBeginningExplicit,

  /// No usable DB position AND the row still holds history-restore budget:
  /// consult HistoryStore (bounded by the budget).
  fallbackHistory,
}

/// Decides the open-resume action from the file's DB position [dbPosMs] and
/// its remaining history-restore budget [restoreBudget].
///
/// A PRESENT positive position is authoritative. A row at/below 0 is:
///   * fallbackHistory when [restoreBudget] > 0 — the row was momentarily
///     cleared or raced to 0 (a quick prev/next cycle) and history still has
///     a chance to restore it;
///   * fromBeginningExplicit when [restoreBudget] == 0 — an explicit "from
///     the beginning" (a VM sequential-advance pre-write) that must never
///     resurrect a stale HistoryStore entry.
/// An ABSENT row (no media node position at all) always falls back to
/// history — there is no explicit from-the-beginning signal to respect.
(OpenResumeDecision, int) resolveOpenResume(
    int? dbPosMs, int durationMs, int restoreBudget) {
  if (dbPosMs == null) return (OpenResumeDecision.fallbackHistory, 0);
  final resumeAt = clampResumePosition(dbPosMs, durationMs);
  if (resumeAt != null && resumeAt > 0) {
    return (OpenResumeDecision.seekDb, resumeAt);
  }
  if (restoreBudget > 0) {
    return (OpenResumeDecision.fallbackHistory, 0);
  }
  return (OpenResumeDecision.fromBeginningExplicit, 0);
}

/// Persists the resume position of [file] to its media node.
///
/// Returns true when a media node existed and the write happened; false when
/// the file has no media node (callers should keep the HistoryStore fallback).
///
/// [completed] is nullable: when omitted, the existing `playback_completed`
/// value is preserved. This keeps a just-completed file flagged as completed
/// when the file-change cleanup / periodic save rewrites its position —
/// otherwise the flag is clobbered back to false and the file re-jumps on
/// every reopen (see the "jump to end" bug). Playback-position writes (the
/// live periodic/switch saves) therefore pass [completed] explicitly to
/// decide whether the file is being resumed or finished.
///
/// [restoreBudgetMs] overrides the stored history-restore budget:
///   * a positive value grants the row that many extra history-fallback opens
///     (a real video restored from history that must survive a quick
///     prev/next cycle before its own next save lands a real position);
///   * 0 forbids the fallback outright (a VM sequential advance — explicit
///     from-the-beginning);
///   * null keeps the stored budget untouched (an ordinary live save must
///     never silently re-arm a budget that was deliberately spent or set).
///
/// [durationMs] enables the head-window guard: when the DB row already holds
/// a large progress and the incoming sample is a small pre-seek head (open
/// → duration arrival → resume seek leaves a ~1-2s window reporting ~533ms),
/// the write is skipped so a next/prev tap inside the window cannot clobber
/// the real progress. Null disables the guard (VM pre-write / explicit
/// finish paths that carry no duration).
/// [userSeekToHead] bypasses the guard for a genuine user seek back to the
/// head — hook callers thread their seek flag through here.
///
/// [userSeek] marks ANY deliberate user seek (slider tap/drag, rewind/forward,
/// chapter jump), not just a seek to the head. It classifies the write as
/// [ProgressWriteIntent.userSeek] so the funnel's monotonic lock lets the
/// smaller target land, and it makes an explicit seek-to-0 actually clear the
/// stored position instead of being dropped by the spurious-zero guard.
///
/// [sourceTimeline] marks a 简播 write: [position] was projected from the VIRTUAL
/// cut timeline onto the SOURCE axis. Such a value may legitimately move
/// BACKWARD (out-of-order / repeated ranges), so the funnel's live monotonic
/// lock must not drop it; it is treated like an explicit user decision (verbatim
/// landing) without touching the completed flag.
Future<bool> persistPlaybackProgress({
  required FileItem file,
  required Duration position,
  bool? completed,
  int? restoreBudgetMs,
  int? durationMs,
  bool userSeekToHead = false,
  bool userSeek = false,
  bool sourceTimeline = false,
  String? writeTag,
}) async {
  final dbPath = file.path.join('/');
  if (dbPath.isEmpty) return false;
  // Multi-instance ownership: the first window to open the file persists its
  // progress; a later opener keeps it in memory only (see MediaProgressClaim).
  final claim = await MediaProgressClaim.instance.claim(
    storageId: file.storageId,
    path: dbPath,
  );
  if (claim == ProgressClaimResult.denied) {
    MediaProgressClaim.instance.remember(
      storageId: file.storageId,
      path: dbPath,
      // A finished file restarts from the head, never from the tail.
      positionMs: completed == true ? 0 : position.inMilliseconds,
      completed: completed,
    );
    areaKeyLog.i('Progress kept in memory (owned by another window): '
        '${file.name} ${position.inMilliseconds}ms');
    return true;
  }
  final bool takeover = claim == ProgressClaimResult.takeover;
  final explicitUserSeek = userSeek || userSeekToHead || sourceTimeline;
  try {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: file.storageId,
      path: file.path,
    );
    if (node == null) return false;
    final playCount = node.maybeMap(
      file: (f) => f.playCount + (position == Duration.zero ? 0 : 1),
      orElse: () => 0,
    );
    final existingPos = node.maybeMap(
      file: (f) => f.playbackPositionMs,
      orElse: () => null,
    );
    // Ordinary playback-position saves must never DESTROY a real saved
    // position with a spurious 0. The first 1s tick after an open reports
    // live position 0 before the duration arrival has had a chance to seek
    // the file to its saved position — writing that 0 would wipe the DB
    // progress and make the next open start from the head (the "prev/next
    // loses progress" regression). A 0 write is only meaningful when the DB
    // row genuinely has no usable position yet (first-ever play from the
    // head) — or when the caller explicitly marks the file finished
    // ([completed] true, e.g. scenario stop / watched-to-end), which MUST
    // clear any stored progress.
    final positionMs = position.inMilliseconds;
    final hasPositiveProgress = existingPos != null && existingPos > 0;
    final forceClear = completed == true;
    if (!takeover &&
        durationMs != null &&
        shouldGuardHeadWrite(
          existingPosMs: existingPos,
          incomingPosMs: positionMs,
          durationMs: durationMs,
          forceClear: forceClear,
          userSeekToHead: explicitUserSeek,
        )) {
      areaKeyLog.i(
          'Head-guard skip for ${file.name}: existing=$existingPos incoming=$positionMs');
      return true;
    }
    final writePosition = (positionMs > 0 ||
            !hasPositiveProgress ||
            forceClear ||
            explicitUserSeek)
        ? positionMs
        : null;
    // A mid-file position save onto a row that still shows no usable
    // position means the current open landed via the history fallback (the
    // row was cleared / raced to 0). Re-arm the fallback budget so a quick
    // prev/next cycle that opens this file again before this save's real
    // position is durable can still restore it — otherwise the next open
    // sees a 0 row and the DB-authoritative semantics start from the head.
    int? budget;
    if (restoreBudgetMs != null) {
      budget = restoreBudgetMs;
    } else if (completed == null &&
        writePosition != null &&
        writePosition > 0 &&
        !hasPositiveProgress) {
      budget = 2;
    }
    await DbModule.mediaNodeRepo.updatePlaybackProgress(
      storageId: file.storageId,
      path: dbPath,
      positionMs: writePosition,
      completed: completed,
      lastPlayedAt: DateTime.now(),
      playCount: playCount,
      historyRestoreBudgetMs: budget,
      // Explicit decisions outrank the handover: a user seek back to the head
      // (or an explicit finish) must land verbatim even right after a takeover;
      // only a LIVE takeover sample is clamped forward.
      intent: forceClear
          ? ProgressWriteIntent.explicitClear
          : (explicitUserSeek
              ? ProgressWriteIntent.userSeek
              : (takeover
                  ? ProgressWriteIntent.takeover
                  : ProgressWriteIntent.live)),
      writeTag: writeTag ?? 'persist',
    );
    return true;
  } catch (e) {
    areaKeyLog.e('Error persisting playback progress '
        '${file.storageId}:$dbPath pos=${position.inMilliseconds} '
        'tag=${writeTag ?? 'persist'}: $e');
    return false;
  }
}

/// Reads the last resume position (ms) of [file] from its media node.
///
/// Returns null when there is no media node or no saved position.
///
/// Claiming ownership here (rather than only on the first write) makes
/// "first window to open the file wins" literal: whichever instance reaches
/// this open-time read first owns the row. A denied instance gets its
/// memory-only position back, so its own reopens resume where it left off.
Future<int?> readPlaybackProgress(FileItem file) async {
  final dbPath = file.path.join('/');
  if (dbPath.isEmpty) return null;
  await MediaProgressClaim.instance.claim(
    storageId: file.storageId,
    path: dbPath,
  );
  final int? memory = MediaProgressClaim.instance.memoryPosition(
    storageId: file.storageId,
    path: dbPath,
  );
  if (memory != null) return memory;
  try {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: file.storageId,
      path: file.path,
    );
    if (node == null) return null;
    final pos = node.maybeMap(
      file: (f) => f.playbackPositionMs,
      orElse: () => null,
    );
    return pos;
  } catch (e) {
    areaKeyLog.e('Error reading playback progress: $e');
    return null;
  }
}

/// Reads the remaining history-restore budget of [file]'s media node.
///
/// Returns 0 when there is no media node / no stored budget (no fallback).
Future<int> readHistoryRestoreBudget(FileItem file) async {
  final dbPath = file.path.join('/');
  if (dbPath.isEmpty) return 0;
  try {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: file.storageId,
      path: file.path,
    );
    if (node == null) return 0;
    return node.maybeMap(
      file: (f) => f.historyRestoreBudget,
      orElse: () => 0,
    );
  } catch (e) {
    areaKeyLog.e('Error reading history restore budget: $e');
    return 0;
  }
}

/// Decrements [file]'s history-restore budget by one (one fallback open was
/// consumed). Never raises the stored value; guards against negative counts.
Future<void> spendHistoryRestoreBudget(FileItem file) async {
  final dbPath = file.path.join('/');
  if (dbPath.isEmpty) return;
  try {
    final budget = await readHistoryRestoreBudget(file);
    if (budget <= 0) return;
    await DbModule.mediaNodeRepo.updatePlaybackProgress(
      storageId: file.storageId,
      path: dbPath,
      historyRestoreBudgetMs: budget - 1,
    );
  } catch (e) {
    areaKeyLog.e('Error spending history restore budget: $e');
  }
}

/// Whether the media node for [file] carries a parsed duration, i.e. the file
/// has been successfully opened at least once (the player hook writes
/// duration on first decode). A failed open leaves durationMs null/0.
Future<bool> hasParsedDuration(FileItem file) async {
  final dbPath = file.path.join('/');
  if (dbPath.isEmpty) return false;
  try {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: file.storageId,
      path: file.path,
    );
    if (node == null) return false;
    final dur = node.maybeMap(file: (f) => f.durationMs, orElse: () => null);
    return dur != null && dur > 0;
  } catch (e) {
    areaKeyLog.e('Error reading media duration: $e');
    return false;
  }
}

/// Whether the media completed playback (used to skip resume on replays).
Future<bool> readPlaybackCompleted(FileItem file) async {
  final dbPath = file.path.join('/');
  if (dbPath.isEmpty) return false;
  try {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: file.storageId,
      path: file.path,
    );
    if (node == null) return false;
    return node.maybeMap(file: (f) => f.playbackCompleted, orElse: () => false);
  } catch (e) {
    areaKeyLog.e('Error reading playback completed: $e');
    return false;
  }
}
