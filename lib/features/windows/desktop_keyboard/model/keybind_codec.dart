import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';
import 'package:iris/utils/logger.dart';

final _log = AreaKeyLog(LogKeys.legacyStore);

/// Codec for desktop keybind overrides stored as a single `keybind.overrides`
/// JSON AUX row.
///
/// Wire format (JSON string):
///   { "playPause": [{"keyId": 32, "ctrl":false,"alt":false,"shift":false}], ... }
///
/// Each entry maps a PotPlayerAction.name to a list of KeyCombo objects.
/// Empty list = explicitly unbound (removed from effective map).
/// Missing key = use defaults.
abstract final class KeybindCodec {
  static const int _maxStoredCombosPerAction = 4;

  static Map<String, dynamic> _encodeCombo(KeyCombo raw) {
    // Store the canonical id so a Windows-recorded `quote` (0x22) never lands
    // in the AUX row as a combo the default table can't name.
    final KeyCombo c = canonicalKeyCombo(raw);
    return <String, dynamic>{
      'keyId': c.key.keyId,
      'ctrl': c.ctrl,
      'alt': c.alt,
      'shift': c.shift,
    };
  }

  static KeyCombo? _decodeCombo(Object? raw) {
    if (raw is! Map) return null;
    final dynamic keyIdRaw = raw['keyId'];
    final int? keyId =
        keyIdRaw is int ? keyIdRaw : int.tryParse(keyIdRaw?.toString() ?? '');
    if (keyId == null) return null;
    LogicalKeyboardKey? key = LogicalKeyboardKey.findKeyByKeyId(keyId);
    key ??= LogicalKeyboardKey(keyId);
    final bool ctrl = raw['ctrl'] == true || raw['ctrl'] == 1;
    final bool alt = raw['alt'] == true || raw['alt'] == 1;
    final bool shift = raw['shift'] == true || raw['shift'] == 1;
    // Rows written by a Windows build may carry `quote` (0x22) for the
    // apostrophe key; fold it onto the canonical binding id on the way in.
    return canonicalKeyCombo(KeyCombo(key, ctrl: ctrl, alt: alt, shift: shift));
  }

  /// Encodes overrides map to JSON string for the AUX row.
  static String encodeOverrides(Map<String, List<KeyCombo>> overrides) {
    final Map<String, dynamic> jsonMap = <String, dynamic>{};
    overrides.forEach((actionName, combos) {
      final List<Map<String, dynamic>> list = combos
          .take(_maxStoredCombosPerAction)
          .map(_encodeCombo)
          .toList(growable: false);
      jsonMap[actionName] = list;
    });
    try {
      return jsonEncode(jsonMap);
    } catch (e) {
      _log.w('KeybindCodec.encode failed: $e');
      return '{}';
    }
  }

  /// Decodes JSON string to overrides map; malformed entries are skipped.
  static Map<String, List<KeyCombo>> decodeOverrides(String? raw) {
    if (raw == null || raw.trim().isEmpty || raw.trim() == '{}') {
      return const <String, List<KeyCombo>>{};
    }
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! Map) return const <String, List<KeyCombo>>{};
      final Map<String, List<KeyCombo>> out = <String, List<KeyCombo>>{};
      decoded.forEach((dynamic k, dynamic v) {
        if (k is! String) return;
        // Validate action name exists.
        final bool known = PotPlayerAction.values.any((e) => e.name == k);
        if (!known) {
          _log.w('KeybindCodec: unknown action "$k" skipped');
          return;
        }
        if (v is! List) {
          out[k] = const <KeyCombo>[];
          return;
        }
        final List<KeyCombo> combos = <KeyCombo>[];
        for (final entry in v) {
          final KeyCombo? c = _decodeCombo(entry);
          if (c == null) continue;
          // Skip pure-modifier combos (no non-modifier key) — they never fire.
          if (_isPureModifier(c.key)) continue;
          combos.add(c);
          if (combos.length >= _maxStoredCombosPerAction) break;
        }
        // Deduplicate within same action.
        final deduped = <KeyCombo>[];
        for (final c in combos) {
          if (!deduped.contains(c)) deduped.add(c);
        }
        out[k] = deduped;
      });
      return out;
    } catch (e) {
      _log.w('KeybindCodec.decode failed: $e');
      return const <String, List<KeyCombo>>{};
    }
  }

  static bool _isPureModifier(LogicalKeyboardKey key) {
    return key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight ||
        key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight ||
        key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight ||
        key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight;
  }

  /// Human-readable label for a combo, e.g. "Ctrl+Shift+K".
  static String labelFor(KeyCombo c) {
    final String label = _keyLabel(c.key);
    final List<String> parts = <String>[];
    if (c.ctrl) parts.add('Ctrl');
    if (c.alt) parts.add('Alt');
    if (c.shift) parts.add('Shift');
    parts.add(label);
    return parts.join('+');
  }

  static String _keyLabel(LogicalKeyboardKey key) {
    if (key.keyLabel.isNotEmpty && key.keyLabel.trim().isNotEmpty) {
      // Single-char keys upper-cased for readability.
      if (key.keyLabel.length == 1) return key.keyLabel.toUpperCase();
      return key.keyLabel;
    }
    // Fallback to debugName / keyId hex.
    final String? debug = key.debugName;
    if (debug != null && debug.isNotEmpty) return debug;
    return 'Key#${key.keyId.toRadixString(16)}';
  }

  /// Shared validation: is combo recordable (not pure modifier, not empty)?
  static bool isRecordable(KeyCombo c) => !_isPureModifier(c.key);
}
