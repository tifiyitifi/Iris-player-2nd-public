import 'dart:convert';

import 'package:iris/features/media_library/scan/model/recursive_scan_state.dart';

/// Rows ↔ [RecursiveScanState] mapping for the metadata settings subsystem.
///
/// Only the PREFERENCE fields participate; the rest of the state is scan
/// RUNTIME data (phase/progress/paths) and must never leak into setting
/// rows. The row key namespace `scan.` keeps auxiliary domains out of the
/// `app.` field-mapping dialect used by StateBridge.
abstract final class ScanStateBridge {
  /// Completion-countdown length (seconds).
  static const String key = 'scan.autoCloseDelay';

  /// Whether the completion countdown is shown at all ("silent completion" is
  /// the inverse: the panel closes as soon as the scan finishes).
  static const String promptKey = 'scan.autoClosePrompt';

  /// The preference rows of the scan domain.
  static Map<String, String> encodeRows(RecursiveScanState state) => {
        key: jsonEncode(state.autoCloseDelay),
        promptKey: jsonEncode(state.autoClosePrompt),
      };

  /// Decoded delay from rows; null when absent/malformed (caller keeps its
  /// current value — error containment, never throw on read).
  static double? readDelay(Map<String, String> rows) {
    final raw = rows[key];
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is num ? v.toDouble() : null;
    } catch (_) {
      return null;
    }
  }

  /// Decoded completion-prompt flag; null when absent/malformed.
  static bool? readPrompt(Map<String, String> rows) {
    final raw = rows[promptKey];
    if (raw == null) return null;
    try {
      final v = jsonDecode(raw);
      return v is bool ? v : null;
    } catch (_) {
      return null;
    }
  }

  /// Overlays persisted preference onto [base]; missing/corrupt rows are
  /// ignored so the base value survives.
  static RecursiveScanState apply(
    Map<String, String> rows,
    RecursiveScanState base,
  ) {
    final delay = readDelay(rows);
    final prompt = readPrompt(rows);
    return base.copyWith(
      autoCloseDelay: delay ?? base.autoCloseDelay,
      autoClosePrompt: prompt ?? base.autoClosePrompt,
    );
  }
}
