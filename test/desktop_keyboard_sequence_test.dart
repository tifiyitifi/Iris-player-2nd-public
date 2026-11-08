import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_sequence_map.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/sequence_resolver.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

/// Five-rule state machine for the `;` prefix sequence buffer plus the
/// follower table anchors.
void main() {
  group('kPotPlayerSequenceMap anchors', () {
    test('covers the five standalone features on plain keys', () {
      expect(
        kPotPlayerSequenceMap,
        equals(<LogicalKeyboardKey, PotPlayerAction>{
          LogicalKeyboardKey.keyF: PotPlayerAction.storagesBrowser,
          LogicalKeyboardKey.keyH: PotPlayerAction.historyPanel,
          LogicalKeyboardKey.keyP: PotPlayerAction.togglePlaylistDockMode,
          LogicalKeyboardKey.keyR: PotPlayerAction.toggleRepeatMode,
          LogicalKeyboardKey.keyX: PotPlayerAction.toggleShuffleMode,
        }),
      );
    });
  });

  group('resolveSequence — idle state', () {
    final idle = (
      buffered: false,
      elapsed: null,
    );

    SequenceInput input(
      LogicalKeyboardKey key, {
      bool ctrl = false,
      bool alt = false,
      bool shift = false,
      bool isRepeat = false,
    }) =>
        (
          key: key,
          ctrl: ctrl,
          alt: alt,
          shift: shift,
          isRepeat: isRepeat,
        );

    test('R1: plain prefix opens the buffer', () {
      final v = resolveSequence(
        state: idle,
        input: input(LogicalKeyboardKey.semicolon),
      );
      expect(v, isA<OpenBuffer>());
    });

    test('prefix with any modifier never opens the buffer', () {
      for (final v in [
        resolveSequence(state: idle, input: input(LogicalKeyboardKey.semicolon, ctrl: true)),
        resolveSequence(state: idle, input: input(LogicalKeyboardKey.semicolon, alt: true)),
        resolveSequence(state: idle, input: input(LogicalKeyboardKey.semicolon, shift: true)),
      ]) {
        expect(v, isA<Unhandled>());
      }
    });

    test('auto-repeat of the prefix does not open the buffer', () {
      final v = resolveSequence(
        state: idle,
        input: input(LogicalKeyboardKey.semicolon, isRepeat: true),
      );
      expect(v, isA<Unhandled>());
    });

    test('any other idle key is not handled by the sequence layer', () {
      expect(
        resolveSequence(state: idle, input: input(LogicalKeyboardKey.keyG)),
        isA<Unhandled>(),
      );
    });
  });

  group('resolveSequence — buffered state', () {
    SequenceInput input(
      LogicalKeyboardKey key, {
      bool ctrl = false,
      bool alt = false,
      bool shift = false,
      bool isRepeat = false,
    }) =>
        (
          key: key,
          ctrl: ctrl,
          alt: alt,
          shift: shift,
          isRepeat: isRepeat,
        );

    final buffered = (buffered: true, elapsed: const Duration(milliseconds: 100));

    test('R3: auto-repeat of a standalone action honours the repeat guard', () {
      // The first press of a standalone key closes the buffer, so the reachable
      // case is a repeat that lands WHILE the buffer is open (arm `;` while the
      // key is already held). R3 used to skip the idle path's repeat guard, so a
      // held key executed once per auto-repeat — Shift+PgDn spawned a window per
      // repeat, PgDn walked the queue. Repeatable actions must still pass.
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.pageDown, shift: true, isRepeat: true),
        ),
        isA<Discard>(),
      );
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.pageDown, isRepeat: true),
        ),
        isA<Discard>(),
      );
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.pageUp, shift: true, isRepeat: true),
        ),
        isA<Discard>(),
      );
      // The FIRST press still executes, and a repeatable action still repeats.
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.pageDown, shift: true),
        ),
        isA<PassThroughStandalone>().having(
            (v) => v.action, 'action', PotPlayerAction.openNextInNewWindow),
      );
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.arrowRight, isRepeat: true),
        ),
        isA<PassThroughStandalone>()
            .having((v) => v.action, 'action', PotPlayerAction.seekForward),
      );
    });

    test('R2: legal follower completes with the mapped action', () {
      expect(
        resolveSequence(state: buffered, input: input(LogicalKeyboardKey.keyF)),
        isA<Complete>().having((v) => v.action, 'action', PotPlayerAction.storagesBrowser),
      );
      expect(
        resolveSequence(state: buffered, input: input(LogicalKeyboardKey.keyH)),
        isA<Complete>().having((v) => v.action, 'action', PotPlayerAction.historyPanel),
      );
      expect(
        resolveSequence(state: buffered, input: input(LogicalKeyboardKey.keyR)),
        isA<Complete>().having((v) => v.action, 'action', PotPlayerAction.toggleRepeatMode),
      );
      expect(
        resolveSequence(state: buffered, input: input(LogicalKeyboardKey.keyX)),
        isA<Complete>().having((v) => v.action, 'action', PotPlayerAction.toggleShuffleMode),
      );
      expect(
        resolveSequence(state: buffered, input: input(LogicalKeyboardKey.keyP)),
        isA<Complete>().having((v) => v.action, 'action', PotPlayerAction.togglePlaylistDockMode),
      );
    });

    test('R2: modified keys can never complete a sequence', () {
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.keyF, ctrl: true),
        ),
        isNot(isA<Complete>()),
      );
    });

    test(
        'R3: illegal combo over a standalone-legal key cancels the buffer '
        'and executes that key instead', () {
      // G has no ;G sequence but IS a standalone binding.
      final v = resolveSequence(state: buffered, input: input(LogicalKeyboardKey.keyG));
      expect(
        v,
        isA<PassThroughStandalone>()
            .having((v) => v.action, 'action', PotPlayerAction.jumpToTime),
      );
      // Modified standalone keys fall through the same way (Ctrl+O is a
      // potplayer binding; note Ctrl+P is NOT — strict replacement).
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.keyO, ctrl: true),
        ),
        isA<PassThroughStandalone>()
            .having((v) => v.action, 'action', PotPlayerAction.openFile),
      );
      // A modified key with NO binding under this scheme discards instead.
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.keyP, ctrl: true),
        ),
        isA<Discard>(),
      );
    });

    test('R4: a fully unbound key discards everything', () {
      // F7 maps to nothing anywhere in the potplayer scheme.
      expect(
        resolveSequence(state: buffered, input: input(LogicalKeyboardKey.f7)),
        isA<Discard>(),
      );
    });

    test('R5a: Escape discards the buffer without executing exitFullscreen',
        () {
      final v = resolveSequence(
        state: buffered,
        input: input(LogicalKeyboardKey.escape),
      );
      expect(v, isA<Discard>());
    });

    test('R5b: timeout discards and ignores the trailing key entirely', () {
      final expired = (
        buffered: true,
        elapsed: const Duration(seconds: 4), // > kSequenceBufferTimeout
      );
      final v = resolveSequence(
        state: expired,
        input: input(LogicalKeyboardKey.keyF),
      );
      expect(v, isA<Discard>());
    });

    test('buffered repeat of the prefix is a no-op (stays buffering)', () {
      expect(
        resolveSequence(
          state: buffered,
          input: input(LogicalKeyboardKey.semicolon, isRepeat: true),
        ),
        isA<Unhandled>(),
      );
    });
  });
}
