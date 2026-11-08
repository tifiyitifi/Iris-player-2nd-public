/// Per-phase wall-clock breakdown of one recursive scan run.
///
/// WHY: the scan's ETA only answers "how fast overall", while the answer to
/// "why is it slow" is a DIFFERENT phase per device. Measured on a 2019 phone
/// (Android 10, 34k directories / 558 videos): the whole volume lists in ~6 s,
/// yet the scan took minutes — the cost sat in per-directory statements and in
/// the encrypted scan-state blob, not in IO. On a Windows desktop the same code
/// is IO-bound. A single summary line per run turns that from a guess into a
/// number the next fix can be chosen from.
///
/// Deliberately allocation-light: one [Stopwatch] per measured block, no
/// per-entry objects, no isolates, no persistence.
class ScanProfiler {
  final Map<String, _PhaseTotal> _totals = <String, _PhaseTotal>{};

  /// Adds one measured block to [phase].
  ///
  /// [items] is the work the block covered (directories listed, rows written,
  /// files probed) and only affects the reported per-item average.
  void record(String phase, Duration elapsed, {int items = 0}) {
    final micros = elapsed.inMicroseconds;
    if (micros < 0) return;
    final total = _totals.putIfAbsent(phase, () => _PhaseTotal());
    total.micros += micros;
    total.calls += 1;
    total.items += items < 0 ? 0 : items;
  }

  /// Times [body] under [phase]. Never swallows or reorders the body's result.
  ///
  /// [itemsOf] derives the work count from the body's own result when the
  /// amount is only known afterwards (a backfill pass reports how many rows it
  /// actually visited).
  Future<T> time<T>(
    String phase,
    Future<T> Function() body, {
    int items = 0,
    int Function(T result)? itemsOf,
  }) async {
    final stopwatch = Stopwatch()..start();
    try {
      final result = await body();
      record(
        phase,
        stopwatch.elapsed,
        items: itemsOf == null ? items : itemsOf(result),
      );
      return result;
    } catch (_) {
      // A failing block still costs the time it burned; record it, then let the
      // error through unchanged.
      record(phase, stopwatch.elapsed, items: items);
      rethrow;
    }
  }

  /// Total time attributed to [phase] (for tests and adaptive policy).
  Duration total(String phase) =>
      Duration(microseconds: _totals[phase]?.micros ?? 0);

  int calls(String phase) => _totals[phase]?.calls ?? 0;

  bool get isEmpty => _totals.isEmpty;

  /// `list=6.1s/34002(0.2ms/it) sync=...` — one line, biggest phase first.
  ///
  /// Ordered by total time so the head of the line is the phase worth fixing;
  /// ties keep insertion order.
  String summary() {
    if (_totals.isEmpty) return 'no-phase-timings';
    final entries = _totals.entries.toList()
      ..sort((a, b) => b.value.micros.compareTo(a.value.micros));
    return entries.map((e) {
      final t = e.value;
      final buffer = StringBuffer()
        ..write(e.key)
        ..write('=')
        ..write(_format(Duration(microseconds: t.micros)));
      if (t.items > 0) {
        buffer
          ..write('/')
          ..write(t.items)
          ..write('(')
          ..write(_format(Duration(microseconds: t.micros ~/ t.items)))
          ..write('/it)');
      } else if (t.calls > 1) {
        buffer
          ..write('x')
          ..write(t.calls);
      }
      return buffer.toString();
    }).join(' ');
  }

  static String _format(Duration d) {
    if (d.inMilliseconds >= 1000) {
      return '${(d.inMilliseconds / 1000).toStringAsFixed(2)}s';
    }
    if (d.inMilliseconds >= 1) return '${d.inMilliseconds}ms';
    return '${d.inMicroseconds}us';
  }

  @override
  String toString() => summary();
}

class _PhaseTotal {
  int micros = 0;
  int calls = 0;
  int items = 0;
}
