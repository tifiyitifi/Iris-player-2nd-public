import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/services/external_subtitle_loader.dart';

/// The engine reports a dead remote subtitle asynchronously, so the loader can
/// only tell success from failure by matching the error text. These cases pin
/// the exact wording observed on-device (media_kit/libmpv) plus the decoys that
/// must NOT be mistaken for a subtitle failure.
void main() {
  const uri = 'http://192.168.1.6:8090/rusia/%5B4K%5D%20(SunDub%2C%20VOX-S)%C2%A9.zh-ru.ass';

  group('ExternalSubtitleOpenAttempts', () {
    test('a newer attempt takes the shared error stream from the previous one',
        () {
      final attempts = ExternalSubtitleOpenAttempts();
      final first = attempts.begin();
      expect(attempts.owns(first), isTrue);

      // The user opens another subtitle: from this moment only the newer
      // attempt may interpret what the (shared) error stream reports.
      final second = attempts.begin();
      expect(
        attempts.owns(first),
        isFalse,
        reason: 'a superseded attempt must not consume the stream',
      );
      expect(attempts.owns(second), isTrue);
    });

    test('reopening the SAME uri is still a new attempt', () {
      final attempts = ExternalSubtitleOpenAttempts();
      final first = attempts.begin();
      final again = attempts.begin();
      expect(attempts.owns(first), isFalse);
      expect(attempts.owns(again), isTrue);
    });
  });

  group('loadExternalSubtitleOnEngine', () {
    Future<void> dispose(StreamController<String> c) async => c.close();

    test('an owning attempt whose open THREW reports failure', () async {
      final attempts = ExternalSubtitleOpenAttempts();
      final errors = StreamController<String>();
      addTearDown(() => dispose(errors));
      expect(
        await loadExternalSubtitleOnEngine(
          attempts: attempts,
          open: () async => throw StateError('boom'),
          errors: errors.stream,
          uri: uri,
        ),
        isFalse,
      );
    });

    test('a SUPERSEDED attempt whose open THREW reports success', () async {
      // The user opened another subtitle while this command was in flight and
      // this one then threw: it must NOT report a failure for the subtitle the
      // user has already left (the newer attempt owns the outcome).
      final attempts = ExternalSubtitleOpenAttempts();
      final errors = StreamController<String>();
      addTearDown(() => dispose(errors));
      expect(
        await loadExternalSubtitleOnEngine(
          attempts: attempts,
          open: () async {
            attempts.begin();
            throw StateError('slow link died after the switch');
          },
          errors: errors.stream,
          uri: uri,
        ),
        isTrue,
      );
    });

    test('an error-stream failure for the owning attempt reports failure',
        () async {
      final attempts = ExternalSubtitleOpenAttempts();
      final errors = StreamController<String>();
      addTearDown(() => dispose(errors));
      // No timeout wait: the failure completes the completer immediately.
      final pending = loadExternalSubtitleOnEngine(
        attempts: attempts,
        open: () async {},
        errors: errors.stream,
        uri: uri,
      );
      errors.add('Failed to open $uri.');
      expect(await pending, isFalse);
    });

    test('a superseded attempt does not consume the shared error stream',
        () async {
      final attempts = ExternalSubtitleOpenAttempts();
      final errors = StreamController<String>();
      addTearDown(() => dispose(errors));
      final pending = loadExternalSubtitleOnEngine(
        attempts: attempts,
        open: () async {
          // The newer attempt starts; the error below belongs to IT.
          attempts.begin();
        },
        errors: errors.stream,
        uri: uri,
        errorWindow: const Duration(milliseconds: 30),
      );
      errors.add('Failed to open $uri.');
      // No failure was observed BY THIS attempt → it reads as loaded.
      expect(await pending, isTrue);
    });
  });

  group('isExternalSubtitleOpenFailure', () {
    test('matches the two lines mpv emits for a dead subtitle URL', () {
      expect(
        isExternalSubtitleOpenFailure('Failed to open $uri.', uri),
        isTrue,
      );
      expect(
        isExternalSubtitleOpenFailure('Can not open external file $uri.', uri),
        isTrue,
      );
    });

    test('does not fire for unrelated player errors', () {
      expect(
        isExternalSubtitleOpenFailure('Failed to open video.mp4.', uri),
        isFalse,
      );
      expect(
        isExternalSubtitleOpenFailure('Failed to recognize file format.', uri),
        isFalse,
      );
    });

    test('still fires when the engine drops the address', () {
      expect(
        isExternalSubtitleOpenFailure('Can not open external file.', uri),
        isTrue,
      );
    });

    test('an unrelated external-file error is not blamed on the subtitle', () {
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file /music/other-track.mp3.',
          uri,
        ),
        isFalse,
        reason: 'the line names a DIFFERENT external file, not this subtitle',
      );
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file cover-art.jpg.',
          uri,
        ),
        isFalse,
      );
    });

    test('matches a percent-decoded echo of the address', () {
      final decoded = Uri.decodeFull(uri);
      expect(
        isExternalSubtitleOpenFailure('Failed to open $decoded.', uri),
        isTrue,
      );
    });

    test('a raw % in the subtitle name must not escape the matcher', () {
      // Dart raises ArgumentError (not FormatException) for a bare '%', so an
      // unhandled decode used to throw straight out of the engine's error
      // listener — which left `failed` uncompleted, the 5s timeout reading as
      // "loaded", and no error dialog.
      const raw = '100%.ass';
      expect(
        () => isExternalSubtitleOpenFailure(
          'Can not open external file 100%25.ass.',
          raw,
        ),
        returnsNormally,
      );
      // A percent-normalized echo names a different string, so it is not this
      // subtitle's failure: the address-aware branch declines and the generic
      // branch sees an address.
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file 100%25.ass.',
          raw,
        ),
        isFalse,
      );
      // The address-less wording still lands on the generic check.
      expect(
        isExternalSubtitleOpenFailure('Can not open external file.', raw),
        isTrue,
      );
    });

    test('the generic wording matches even without an address', () {
      expect(
        isExternalSubtitleOpenFailure('Can not open external file.', ''),
        isTrue,
      );
      expect(isExternalSubtitleOpenFailure('ok', ''), isFalse);
    });

    test('the generic wording followed by an errno reason is still a failure',
        () {
      // mpv appends the subsystem reason after the generic wording; requiring a
      // totally empty tail misread it as "some other address is named" and the
      // dead subtitle went unreported (漏报).
      for (final reason in const [
        'No such file or directory',
        'No such file or directory (errno 2)',
        'Permission denied',
        'Connection refused',
        'Connection timed out',
      ]) {
        expect(
          isExternalSubtitleOpenFailure(
              'Can not open external file. $reason', uri),
          isTrue,
          reason: reason,
        );
      }
    });

    test('a slash-bearing errno reason is still address-less', () {
      // mpv's I/O wording itself carries a `/`, so the address heuristic must
      // not swallow it (a dead subtitle was silently unreported).
      for (final reason in const [
        'I/O error',
        'input/output error',
        'Operation not permitted',
        'Operation not permitted (errno 1)',
      ]) {
        expect(
          isExternalSubtitleOpenFailure(
              'Can not open external file. $reason', uri),
          isTrue,
          reason: reason,
        );
      }
    });

    test('an errno reason does not excuse a line naming another address', () {
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file /music/other-track.mp3. '
          'No such file or directory',
          uri,
        ),
        isFalse,
        reason: 'a different address is named, whatever reason follows',
      );
    });

    test('a bare filename in the tail is still a decoy (never a reason)', () {
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file cover-art.jpg.',
          uri,
        ),
        isFalse,
      );
    });

    test('a bare decoy filename followed by a real errno reason is NOT ours',
        () {
      // mpv appends the SAME errno wording after ANY external file it cannot
      // open; the named address is the decoy, so the reason must not excuse it.
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file cover-art.jpg. No such file or directory',
          uri,
        ),
        isFalse,
      );
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file track02.mp3. Permission denied',
          uri,
        ),
        isFalse,
      );
    });

    test('a percent-decoded proxy path= tail is recognised', () {
      const proxy = 'ftp?host=h&port=21&path=/sub/Show%20S01.ass';
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file /sub/Show%20S01.ass.',
          proxy,
        ),
        isTrue,
      );
      expect(
        isExternalSubtitleOpenFailure(
          'Can not open external file /sub/Show S01.ass.',
          proxy,
        ),
        isTrue,
        reason: 'the engine echoed the decoded path',
      );
    });

    test('a double-encoded echo is still matched', () {
      const once = 'http://h/a%20b.ass';
      final twice = Uri.encodeComponent(once);
      expect(
        isExternalSubtitleOpenFailure('Failed to open ${Uri.decodeFull(twice)}.',
            once),
        isTrue,
      );
    });
  });
}
