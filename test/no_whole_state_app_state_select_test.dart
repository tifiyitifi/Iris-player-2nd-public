import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// WHY: a whole-state `select(context, (s) => s)` on a Freezed [AppState] is
/// NOT an inert read. `Store.set` emits unconditionally, `StoreScope` marks
/// every dependent on each emit, and provider's comparison is
/// `!DeepCollectionEquality().equals(selector(newValue), selected)` — for a
/// Freezed state that is a deep field compare, so ANY AppState mutation
/// re-ran the consuming widget.
///
/// That is expensive out of proportion to the subscription, because the
/// per-frame writes a gesture makes (`transientRate` on every speed stop, the
/// panel geometry on every drag frame) hit every whole-state subscriber at
/// once, each re-running a subtree the write does not touch.
///
/// Commit 050dd4a4 fixed `ControlsOverlay` and the dialog rows; this guard is
/// what stops the pattern from growing back. A child's `context.select`
/// registers its OWN dependency on the store, so narrowing a parent does not
/// narrow its children — the panel below the control bar is the proof.
void main() {
  /// The receiver of `.select(...)` plus the selector, so the allowlist can be
  /// keyed per OCCURRENCE: `osd_overlay.dart` legitimately reads its own store
  /// whole and must still be caught reading AppState whole on the next line.
  final RegExp selectCall = RegExp(
    r'([\w.]+(?:\(\))?)\s*\.\s*select\(\s*context\s*,\s*'
    r'\(\s*(\w+)(?:\s+(\w+))?\s*\)\s*=>\s*(\w+)\s*[,)]',
  );

  /// Whole-state subscriptions that are NOT AppState, keyed `path | receiver`,
  /// with the reason each one is sound. These stores are small and dedicated,
  /// so "the whole state" is close to "everything this widget renders" — the
  /// opposite of AppState, a ~90-field blob that every module writes into.
  const Map<String, String> allowlist = <String, String>{
    'lib/features/osd/view/osd_overlay.dart | useOsdStore()':
        'the store holds exactly one OsdEntry, so the whole state IS the '
            'selected value',
    'lib/pages/player/player.dart | useScrubDragStore()':
        'two bools (isScrubbing/isHolding) and the caller reads both',
    'lib/features/windows/desktop_keyboard/view/ab_loop_overlay.dart | useAbLoopStore()':
        'a three-field chip (enabled/pointA/pointB) that reads all of them',
    'lib/features/virtual_media/view/vm_sheet.dart | useVmPlaybackStore()':
        'the VM sheet renders the whole playback state',
  };

  test('no widget takes a whole-state AppState subscription', () {
    final offenders = <String>[];
    final Directory lib = Directory('lib');
    expect(lib.existsSync(), isTrue,
        reason: 'run from the project root (flutter test default)');

    for (final FileSystemEntity entity in lib.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      // Generated code mirrors the model, it is never hand-written.
      if (entity.path.endsWith('.g.dart') ||
          entity.path.endsWith('.freezed.dart')) {
        continue;
      }
      final List<String> lines = entity.readAsLinesSync();
      for (int i = 0; i < lines.length; i++) {
        // Only CODE counts: several files quote this very pattern in prose.
        final String line = lines[i];
        final int comment = line.indexOf('//');
        final String code = comment < 0 ? line : line.substring(0, comment);
        final RegExpMatch? match = selectCall.firstMatch(code);
        if (match == null) continue;
        final String receiver = match.group(1)!;
        final String? first = match.group(2);
        final String? second = match.group(3);
        final String? body = match.group(4);
        // `(s) => s` / `(AppState s) => s`: the body IS the parameter.
        final bool identity = second == null ? first == body : second == body;
        if (!identity) continue;
        final String path = entity.path.replaceAll('\\', '/');
        if (allowlist.containsKey('$path | $receiver')) continue;
        offenders.add('$path:${i + 1}: ${line.trim()}');
      }
    }

    expect(offenders, isEmpty,
        reason: 'a whole-state AppState subscription re-runs the consuming '
            'subtree on every AppState write, including the per-frame ones a '
            'gesture makes. Select the fields the widget reads (or the derived '
            'value it computes from them). Legitimate whole-state reads of '
            'OTHER stores belong in the allowlist above, keyed '
            '"path | receiver", with a reason.');
  });
}
