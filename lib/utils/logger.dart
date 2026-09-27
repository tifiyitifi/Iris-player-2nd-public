import 'dart:developer' as dev;

import 'package:flutter/foundation.dart';
import 'package:iris/features/scenario_playback/logging/scenario_log_keys.dart';
import 'package:logging/logging.dart' as logging;

/// Logging facade built on `package:logging`.
///
/// ## Gating model
/// Every channel (a "key") is a hierarchical logger name like
/// `log.scenario.store`. A line prints only when BOTH hold:
///   1. mode gate — the build mode selects the DEFAULT set of enabled keys:
///      debug enables the scenario diag channels (see
///      `scenarioDiagLogsEnabled`) and `log.app`; release enables nothing.
///      `--dart-define=IRIS_LOG_KEYS=a,b` appends more keys at build time.
///   2. key gate  — the record's `Level` must be >= that key's configured
///      level (`package:logging` filters before anything reaches the sink).
///
/// ## Runtime control
/// ```dart
/// Log.setEnabled(ScenarioLogKeys.store, false);   // turn ONE key off
/// Log.setEnabled(ScenarioLogKeys.queue, true);    // turn ONE key on
/// Log.only([ScenarioLogKeys.resolve]);            // ONLY these keys print
/// Log.setLevel(ScenarioLogKeys.playback, Level.WARNING); // key threshold
/// ```
/// Setting a level on `log.scenario` applies to every `log.scenario.*` child
/// that does not set its own level (dot hierarchy).
///
/// Records are forwarded to `dart:developer log()` so DevTools / Logcat keep
/// working exactly as before.
abstract final class Log {
  static bool _initialized = false;

  /// Attaches the sink, flips the master switch to OFF and applies the
  /// build-mode + `--dart-define` defaults. Call once at startup.
  static void init() {
    if (_initialized) return;
    _initialized = true;

    // package:logging merges everything into the root unless hierarchical
    // logging is enabled — per-key levels (setEnabled/setLevel) would throw
    // `UnsupportedError` on non-root loggers without this.
    logging.hierarchicalLoggingEnabled = true;

    // Master switch: nothing prints unless a key opts in.
    logging.Logger.root.level = logging.Level.OFF;
    logging.Logger.root.onRecord.listen((r) {
      dev.log(
        r.message,
        name: r.loggerName,
        level: r.level.value,
        error: r.error,
        stackTrace: r.stackTrace,
      );
    });

    if (kDebugMode) {
      // Debug diag channels default ON for on-device verification; flip
      // `scenarioDiagLogsEnabled` to false once the feature is verified.
      // Only the playback channel is opened by default — store/queue/resolve
      // stay closed to keep the log focused on the current investigation.
      if (scenarioDiagLogsEnabled) {
        setEnabled(ScenarioLogKeys.group, true);
      }
      // Player diagnostics (open / duration / resume / completed / watchdog).
      if (playerDiagLogsEnabled) {
        setEnabled(LogKeys.player, true);
      }
      // Virtual-media merge diagnostics (rules loaded, stream size, groups):
      // `log.media_probe` channel — on by default in debug while the merge
      // feature is being verified. Flip off once verified.
      if (vmMergeDiagLogsEnabled) {
        setEnabled(LogKeys.mediaProbe, true);
      }
      // Scrub-surface diagnostics (slider tap/drag hit-test, drag state,
      // 副音 drag cooperation): `log.dial` — on by default in debug.
      if (dialDiagLogsEnabled) {
        setEnabled(LogKeys.dial, true);
      }
      // AXTree-corruption diagnostics (Windows #182444 investigation): dumps
      // the framework semantics tree so engine-reported node ids can be
      // mapped to concrete widgets. Flip off when the investigation ends.
      if (axtreeDiagLogsEnabled) {
        setEnabled(LogKeys.axtreeDiag, true);
      }
      // Legacy area logs (see [LogKeys.legacy]): INFO/FINE lines are silenced,
      // WARNING/SEVERE (errors via [logError]) still print.
      setLevel(LogKeys.legacy, logging.Level.WARNING);
      setEnabled('log.app', true);
    }

    // --dart-define=IRIS_LOG_KEYS=a,b,c appends channels in any build mode.
    const extra = String.fromEnvironment('IRIS_LOG_KEYS');
    if (extra.isNotEmpty) {
      for (final k in extra.split(',')) {
        final t = k.trim();
        if (t.isNotEmpty) setEnabled(t, true);
      }
    }
  }

  /// Enables or disables [key]. Enabled means `Level.ALL` in debug builds and
  /// `Level.WARNING` in release builds (only warnings/errors print there).
  static void setEnabled(String key, bool enabled) {
    logging.hierarchicalLoggingEnabled = true; // safe to call before init()
    logging.Logger(key).level = enabled
        ? (kDebugMode ? logging.Level.ALL : logging.Level.WARNING)
        : logging.Level.OFF;
  }

  /// Sets a per-key threshold directly (e.g. `Level.FINE`, `Level.WARNING`).
  static void setLevel(String key, logging.Level level) {
    logging.hierarchicalLoggingEnabled = true; // safe to call before init()
    logging.Logger(key).level = level;
  }

  /// Turns every channel OFF except the given [keys].
  static void only(List<String> keys) {
    logging.hierarchicalLoggingEnabled = true; // safe to call before init()
    logging.Logger.root.level = logging.Level.OFF;
    for (final k in keys) {
      setEnabled(k, true);
    }
  }
}

/// Central registry of log keys.
///
/// ## Naming
/// Channels are hierarchical logger names (`log.<domain>.<sub>`). A level set
/// on a parent applies to every child that does not set its own level, so
/// `log.legacy` gates every `log.legacy.*` area at once.
///
/// ### `log.legacy.*` — legacy area logs
/// ALL legacy one-arg `logger()` call sites route here (see [logger] /
/// [logError]). In debug builds the parent [legacy] is set to
/// `Level.WARNING`: informational (INFO) lines are silenced while
/// WARNING/SEVERE (errors) still print, so unrelated info spam stays off but
/// error visibility is preserved. Each area gets a concrete sub-channel
/// (`log.legacy.<area>`) so it can be re-enabled individually at build time:
/// ```text
/// --dart-define=IRIS_LOG_KEYS=log.legacy.player
/// ```
/// or at runtime: `Log.setEnabled(LogKeys.legacyPlayer, true);`.
///
/// Call sites MUST keep a concrete marker in the message itself (file name,
/// position, operation) so lines stay greppable even with the channel name
/// stripped from the sink output.
abstract final class LogKeys {
  static const String app = 'log.app';

  /// Player diagnostics (open / duration / resume / completed / watchdog).
  ///
  /// On by default in debug via [playerDiagLogsEnabled] while the
  /// "jumps to end" playback bug is being investigated.
  static const String player = 'log.player';

  // ── log.legacy.* — legacy area logs (see comment above) ──
  /// Parent gate for every legacy `logger()`/`logError()` area channel.
  static const String legacy = 'log.legacy';

  /// App entry / lifecycle / global startup.
  static const String legacyMain = 'log.legacy.main';

  /// Player hooks + player pages (open / resume / completed / controls).
  static const String legacyPlayer = 'log.legacy.player';

  /// Gesture & gesture-region handling.
  static const String legacyGesture = 'log.legacy.gesture';

  /// Zustand stores + persistence backends.
  static const String legacyStore = 'log.legacy.store';

  /// Drift DB layer, migrations, scan service, storage drivers.
  static const String legacyDb = 'log.legacy.db';

  /// Widgets / popups / dialogs / window & UI helpers.
  static const String legacyUi = 'log.legacy.ui';

  /// Device & misc utilities (brightness, volume, path, release check).
  static const String legacyUtil = 'log.legacy.util';

  /// Scenario-playback feature misc logs not already on a scenario channel.
  static const String legacyScenario = 'log.legacy.scenario';

  /// Fallback for call sites not yet assigned a concrete area.
  static const String legacyMisc = 'log.legacy.misc';

  /// Tag-play feature (tags, membership, tag view playback).
  static const String tagPlay = 'log.tag_play';

  /// Media info probing (scan-time probe / playback backfill).
  static const String mediaProbe = 'log.media_probe';

  /// Scrub-surface diagnostics: slider tap/drag hit-test resolution, drag
  /// state transitions and the 副音 drag-cooperation decisions.
  static const String dial = 'log.dial';

  /// WebDAV wildcard-host discovery (subnet enumeration, SSDP, probing,
  /// legacy serial scan).
  static const String webdav = 'log.webdav';

  /// App-identity feature (custom desktop entries: pin/update shortcuts,
  /// entry-bound playback activation, default-state backup/restore).
  static const String appIdentity = 'log.app_identity';

  /// Semantics-tree diagnostics for the Windows AXTree corruption
  /// (flutter/flutter #182444). Standalone channel (not under [legacy]) so
  /// its INFO-level tree dumps are gated independently.
  static const String axtreeDiag = 'log.axtree_diag';

  /// App-update feature (release lookup, asset selection, download, install).
  static const String appUpdate = 'log.app_update';
}

/// Development diag channel for the player "jumps to end" investigation is
/// enabled by default (debug builds) so it can be verified on-device. Set to
/// `false` once verified to silence `log.player` WITHOUT touching call sites.
// CLOSE_DEBUG_LOG: set to false to silence all log.player diag channels.
const bool playerDiagLogsEnabled = true;

/// Development diag channel that periodically serializes the framework
/// semantics tree (see `SemanticsTreeDumper`) so the raw node ids printed by
/// the engine's "Failed to update ui::AXTree" errors can be mapped to
/// concrete widgets.
///
/// The 2026-08 investigation is CONCLUDED: the corruption is engine-side
/// (flutter/flutter #182444 / #190344 / #98099 family — the Windows
/// embedder's two-phase AXTree batch apply), not app-side; the framework
/// tree was proven correct (byte-identical periodic dumps) while the engine
/// cache stayed poisoned for whole sessions. Mitigated by
/// `wrapPlatformSemantics` in `main.dart`. Flip back to `true` (together
/// with `SemanticsTreeDumper.startPeriodic`/`startFrameDiffWatcher` in
/// `main()`) only to reopen the investigation.
const bool axtreeDiagLogsEnabled = false;

/// Per-area logger bound to ONE channel key (see [LogKeys] / [ScenarioLogKeys]).
///
/// The ergonomic replacement for the verbose `logger(msg, key: ...)` /
/// `logError(msg, key: ...)` idiom: declare one instance per file/module, then
/// call a leveled method without repeating the key:
/// ```dart
/// final areaKeyLog = AreaKeyLog(LogKeys.legacyPlayer);
/// areaKeyLog.v('frame debug');        // FINEST  — verbose, deepest tracing
/// areaKeyLog.d('locate hit');         // FINE    — debug-level
/// areaKeyLog.i('Open file: $file');   // INFO    — regular info
/// areaKeyLog.w('stale hint');         // WARNING — warning
/// areaKeyLog.e('open failed: $e', e); // SEVERE  — errors / exceptions
/// areaKeyLog.log(logging.Level.CONFIG, 'cfg'); // arbitrary level
/// ```
///
/// Gating is purely level-based on [key] (see [Log.init]): with the `log.legacy`
/// parent at `Level.WARNING`, `.v/.d/.i` are silenced while `.w/.e` print;
/// scenario channels default to `Level.ALL` in debug so every level prints.
/// Methods are intentionally loose aliases of [Level] — pick the one that best
/// matches intent.
class AreaKeyLog {
  const AreaKeyLog(this.key);

  /// The channel key this logger emits to (e.g. `LogKeys.legacyPlayer`).
  final String key;

  /// Verbose / deepest tracing (`Level.FINEST`).
  void v(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(logging.Level.FINEST, message, error, stackTrace);

  /// Debug-level (`Level.FINE`).
  void d(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(logging.Level.FINE, message, error, stackTrace);

  /// Informational (`Level.INFO`).
  void i(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(logging.Level.INFO, message, error, stackTrace);

  /// Warning (`Level.WARNING`).
  void w(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(logging.Level.WARNING, message, error, stackTrace);

  /// Error / exception (`Level.SEVERE`).
  void e(Object? message, [Object? error, StackTrace? stackTrace]) =>
      log(logging.Level.SEVERE, message, error, stackTrace);

  /// Emits [message] at an arbitrary [level], forwarding [error] and
  /// [stackTrace] to the sink (kept by `dart:developer log()`).
  void log(logging.Level level, Object? message,
          [Object? error, StackTrace? stackTrace]) =>
      logging.Logger(key).log(level, message, error, stackTrace);
}

/// Legacy single-argument logger kept for backward compatibility.
///
/// Alias of [AreaKeyLog] at INFO on the `log.legacy.<area>` channel. Prefer a
/// file-scoped `AreaKeyLog(LogKeys.legacyXxx)` over passing [key] each call.
void logger(String message, {String key = LogKeys.legacyMisc}) {
  AreaKeyLog(key).i(message);
}

/// Logs an error/exception on a `log.legacy.<area>` channel at SEVERE level.
///
/// Alias of [AreaKeyLog.e]. Errors stay visible even while an area's
/// informational logging is off (the parent `log.legacy` gate is WARNING).
void logError(String message, {String key = LogKeys.legacyMisc}) {
  AreaKeyLog(key).e(message);
}

/// Development diag channel for the Virtual Media merge feature (`log.media_probe`)
/// is enabled by default in debug builds so the merge pipeline can be verified
/// on-device. Flip to `false` once verified to silence it WITHOUT touching call
/// sites.
// CLOSE_DEBUG_LOG: set to false to silence all vm merge diag lines.
const bool vmMergeDiagLogsEnabled = true;

/// Scrub-surface diagnostics (`log.dial`) are enabled by default in debug so a
/// drag-hit-test / 副音-cooperation repro can be captured in one run. Set to
/// `false` once the investigation closes to silence it WITHOUT touching call
/// sites.
// CLOSE_DEBUG_LOG: set to false to silence all log.dial lines.
const bool dialDiagLogsEnabled = true;
