import 'package:drift/drift.dart' show DatabaseConnectionUser;
import 'package:drift/native.dart' show SqliteException;

/// SQLite primary result codes that mean "another connection holds the write
/// lock". They are transient by definition: the holder will release it.
const int _kSqliteBusy = 5;
const int _kSqliteLocked = 6;

/// Default per-connection `busy_timeout` (ms) applied in `multiInstancePragmaSetup`.
///
/// Kept here (single source of truth) so fail-fast scopes can restore it.
const int kDbBusyTimeoutMs = 5000;

/// Whether [error] is a transient write-lock conflict (SQLITE_BUSY /
/// SQLITE_LOCKED, including their extended codes).
///
/// Only these are worth retrying. A constraint violation, a missing table or a
/// disk error will fail exactly the same way on the next attempt, so retrying
/// them would only delay the report.
bool isDbBusyError(Object error) {
  if (error is! SqliteException) return false;
  final code = error.resultCode;
  return code == _kSqliteBusy || code == _kSqliteLocked;
}

/// Runs [action], retrying ONLY while SQLite reports a write-lock conflict.
///
/// WHY: every IRIS window has its own writer against one database file.
/// `busy_timeout` absorbs most contention, but the loser of a long transaction
/// (a scan batch, a startup repair) still surfaces SQLITE_BUSY. Progress writes
/// used to swallow that as "no row" and silently drop the sample; a short,
/// bounded retry lets the next attempt land once the other writer is done.
///
/// The schedule is deliberately tiny (tens of milliseconds, capped at
/// [maxDelay]): the DB runs on the UI isolate, so a long wait would be a frozen
/// window. [maxAttempts] bounds the total work, and a non-busy error is
/// rethrown immediately.
Future<T> retryOnDbBusy<T>(
  Future<T> Function() action, {
  int maxAttempts = 3,
  Duration initialDelay = const Duration(milliseconds: 30),
  Duration maxDelay = const Duration(milliseconds: 250),
  void Function(int attempt, Object error)? onRetry,
}) async {
  assert(maxAttempts >= 1, 'at least one attempt must run');
  for (var attempt = 1; ; attempt++) {
    try {
      return await action();
    } catch (error) {
      if (attempt >= maxAttempts || !isDbBusyError(error)) rethrow;
      onRetry?.call(attempt, error);
      final backoff = initialDelay.inMilliseconds * attempt;
      final delayMs =
          backoff > maxDelay.inMilliseconds ? maxDelay.inMilliseconds : backoff;
      if (delayMs > 0) {
        await Future<void>.delayed(Duration(milliseconds: delayMs));
      }
    }
  }
}

/// Runs [action] with a temporarily lowered `busy_timeout`.
///
/// WHY: the DB runs on the UI isolate (`NativeDatabase`), so waiting out the
/// default 5s `busy_timeout` on every attempt freezes the window — and with a
/// 3-attempt retry that compounds to ~15s, worse than no retry at all.
/// A fail-fast window for a cheap, repeatable write (a playback-progress
/// sample that the next timer tick rewrites anyway) bounds the worst case to
/// roughly `maxAttempts * timeoutMs` instead. The previous timeout is always
/// restored, so unrelated writers keep the contention-absorbing default.
Future<T> withShortDbBusyTimeout<T>(
  DatabaseConnectionUser db,
  int timeoutMs,
  Future<T> Function() action,
) async {
  await db.customStatement('PRAGMA busy_timeout=$timeoutMs');
  try {
    return await action();
  } finally {
    await db.customStatement('PRAGMA busy_timeout=$kDbBusyTimeoutMs');
  }
}
