import 'package:flutter/services.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_sequence_map.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

/// Pure decision layer of the `;` prefix-sequence buffer (SRS §4).
///
/// Five rules over two tables:
/// - R1 idle + plain `;`        → [OpenBuffer]
/// - R2 buffered + legal combo  → [Complete]
/// - R3 buffered + illegal combo but standalone-legal key →
///   [PassThroughStandalone] (buffer cancelled, that key executes instead)
/// - R4 buffered + fully unbound key → [Discard]
/// - R5a buffered + Escape / R5b timeout exceeded → [Discard] (trailing key
///   after a timeout is swallowed too: slow input never surprises)
///
/// No clocks, no Flutter framework types beyond LogicalKeyboardKey — fully
/// unit-testable; timers live in the executor.
sealed class SequenceVerdict {
  const SequenceVerdict();
}

/// R1 — arm the buffer and show the waiting indicator.
class OpenBuffer extends SequenceVerdict {
  const OpenBuffer();
}

/// R2 — `;` + legal follower.
class Complete extends SequenceVerdict {
  final PotPlayerAction action;
  const Complete(this.action);
}

/// R3 — combo illegal, but the pressed key carries its own binding.
class PassThroughStandalone extends SequenceVerdict {
  final PotPlayerAction action;
  const PassThroughStandalone(this.action);
}

/// R4/R5 — drop everything.
class Discard extends SequenceVerdict {
  const Discard();
}

/// Not the sequence layer's concern (idle non-prefix input, buffered repeat
/// of the prefix).
class Unhandled extends SequenceVerdict {
  const Unhandled();
}

typedef SequenceState = ({bool buffered, Duration? elapsed});

typedef SequenceInput = ({
  LogicalKeyboardKey key,
  bool ctrl,
  bool alt,
  bool shift,
  bool isRepeat,
});

SequenceVerdict resolveSequence({
  required SequenceState state,
  required SequenceInput input,
}) {
  if (!state.buffered) {
    final opens =
        identical(input.key, kSequencePrefixKey) &&
            !input.ctrl &&
            !input.alt &&
            !input.shift &&
            !input.isRepeat;
    return opens ? const OpenBuffer() : const Unhandled(); // R1
  }

  // ── Buffered ──
  final elapsed = state.elapsed;
  if (elapsed != null && elapsed > kSequenceBufferTimeout) {
    return const Discard(); // R5b — swallow the trailing key too
  }
  if (identical(input.key, LogicalKeyboardKey.escape)) {
    return const Discard(); // R5a — before any pass-through lookup
  }
  if (identical(input.key, kSequencePrefixKey)) {
    return const Unhandled(); // re-press/repeat of the prefix: keep buffering
  }

  final plainFollowUp =
      !input.ctrl && !input.alt && !input.shift && !input.isRepeat;
  if (plainFollowUp) {
    final follower = kPotPlayerSequenceMap[input.key];
    if (follower != null) return Complete(follower); // R2
  }

  final rawCombo = KeyCombo(
    input.key,
    ctrl: input.ctrl,
    alt: input.alt,
    shift: input.shift,
  );
  final standalone = kPotPlayerKeyMap[canonicalKeyCombo(rawCombo)];
  if (standalone != null) {
    // R3 must honour the repeat guard the idle path applies. The first press of
    // a standalone key closes the buffer, so the reachable case is a repeat that
    // lands WHILE the buffer is open (arm `;` while the key is already held):
    // without this guard it executed once per auto-repeat — Shift+PgDn spawned
    // a window per repeat, plain PgDn walked the queue. Swallow the repeat; the
    // buffer ends with it, like any other discarded key.
    if (input.isRepeat &&
        !kRepeatablePotPlayerActions.contains(standalone)) {
      return const Discard();
    }
    return PassThroughStandalone(standalone); // R3
  }

  return const Discard(); // R4
}
