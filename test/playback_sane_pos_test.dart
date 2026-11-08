import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/playback/playback_progress.dart';

// Display/persistence sanitizer for the 1s progress sampler.
//
// Legacy contract (no lock in flight): clamp to [0, dur], reject backward
// regressions beyond 2s unless a user seek just happened or first sample.
// While a position-intent lock is in flight the raw sample may lag the
// intent (pre-land ticks) or lead it (a stale high watermark from an
// earlier tick, e.g. the dial's release commit); with the target known the
// sanitizer accepts raw on the way from lastSane to the target and keeps
// the legacy guard otherwise.
void main() {
  const int dur = 659178;

  group('sanePlaybackPos legacy behaviour (no in-flight target)', () {
    test('clamps into range', () {
      expect(
        sanePlaybackPos(null, -5, dur,
            userSeeked: false, inFlightTargetMs: null),
        0,
      );
      expect(
        sanePlaybackPos(null, dur + 1000, dur,
            userSeeked: false, inFlightTargetMs: null),
        dur,
      );
    });

    test('first sample accepted', () {
      expect(
        sanePlaybackPos(null, 469450, dur,
            userSeeked: false, inFlightTargetMs: null),
        469450,
      );
    });

    test('user seek accepts backward jumps', () {
      expect(
        sanePlaybackPos(518283, 99779, dur,
            userSeeked: true, inFlightTargetMs: null),
        99779,
      );
    });

    test('rejects large backward regressions without a seek', () {
      expect(
        sanePlaybackPos(518283, 99779, dur,
            userSeeked: false, inFlightTargetMs: null),
        518283,
      );
    });

    test('accepts forward drift and small backward jitter', () {
      expect(
        sanePlaybackPos(100000, 101000, dur,
            userSeeked: false, inFlightTargetMs: null),
        101000,
      );
      expect(
        sanePlaybackPos(100000, 99000, dur,
            userSeeked: false, inFlightTargetMs: null),
        99000,
      );
    });
  });

  group('sanePlaybackPos with in-flight lock target', () {
    test('dial release regression: stale high watermark gives way to the target path', () {
      // Repro from the dial log: lastSane was polluted by an in-flight
      // throttled target (227837) while the release commit (221167) was
      // landing; the fresh raw (221833) lies on the way and must be
      // accepted instead of pinning the stale value (the visible jump-back).
      expect(
        sanePlaybackPos(227837, 221833, dur,
            userSeeked: false, inFlightTargetMs: 221167),
        221833,
      );
    });

    test('forward commit in flight accepts pre-land samples on the way', () {
      expect(
        sanePlaybackPos(99779, 110000, dur,
            userSeeked: false, inFlightTargetMs: 139515),
        110000,
      );
    });

    test('head sample during flight is still rejected', () {
      // The whole point of the lock: a pre-land head tick must never
      // become the sanitized position.
      expect(
        sanePlaybackPos(469450, 100, dur,
            userSeeked: false, inFlightTargetMs: 139515),
        469450,
      );
    });

    test('forward overshoot past the target keeps the legacy forward rule',
        () {
      // Not on the way to the target, but forward motion was always
      // accepted by the legacy guard — preserved verbatim.
      expect(
        sanePlaybackPos(100000, 500000, dur,
            userSeeked: false, inFlightTargetMs: 139515),
        500000,
      );
    });

    test('userSeeked still wins over everything', () {
      expect(
        sanePlaybackPos(469450, 100, dur,
            userSeeked: true, inFlightTargetMs: 139515),
        100,
      );
    });

    test('first sample during a mid-file lock reports the intent, not the head',
        () {
      // Field log (second launch, Android): the first 1s tick fired BEFORE the
      // resume seek was observed, so the pre-land head sample (~580ms) seeded
      // `lastSane` and every later tick followed it — the progress UI reset to
      // 0 while the DB row still held 277156.
      expect(
        sanePlaybackPos(null, 580, dur,
            userSeeked: false, inFlightTargetMs: 277156),
        277156,
      );
    });

    test('first sample during a head lock keeps the head', () {
      // A from-the-beginning intent (target 0) has no head sample to reject.
      expect(
        sanePlaybackPos(null, 120, dur,
            userSeeked: false, inFlightTargetMs: 0),
        120,
      );
    });

    test('first sample is verbatim when no lock is in flight', () {
      expect(
        sanePlaybackPos(null, 580, dur,
            userSeeked: false, inFlightTargetMs: null),
        580,
      );
    });
  });
}
