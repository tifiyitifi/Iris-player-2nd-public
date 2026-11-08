import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/services/background_volume_policy.dart';

void main() {
  group('BackgroundVolumePolicy (fg engine)', () {
    test('legacy identity: 副音 inactive ⇒ fg == master, ratio ignored', () {
      for (final master in [0, 1, 50, 80, 100]) {
        expect(
          BackgroundVolumePolicy.foregroundEngineVolume(
            master: master,
            muted: false,
            bgActive: false,
          ),
          master,
        );
      }
      // An explicit fgPercent must not leak into the legacy path either.
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
          master: 80,
          muted: false,
          bgActive: false,
          fgPercent: 5,
        ),
        80,
      );
    });

    test('bg on scales the foreground by the fg ratio (default 30%)', () {
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 80, muted: false, bgActive: true),
        24,
      );
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 100, muted: false, bgActive: true),
        30,
      );
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 7, muted: false, bgActive: true),
        2,
      );
    });

    test('master mute mutes the foreground in both modes', () {
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 80, muted: true, bgActive: false),
        0,
      );
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 80, muted: true, bgActive: true),
        0,
      );
    });

    test('fgMuted silences the foreground track only', () {
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 80, muted: false, bgActive: true, fgMuted: true),
        0,
      );
      // 副音 inactive: fgMuted is a mixing-domain concept and is ignored — the
      // foreground plays like a plain single-track player at master volume.
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 80, muted: false, bgActive: false, fgMuted: true),
        80,
      );
    });

    test('clamps out-of-range inputs', () {
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: 300, muted: false, bgActive: false),
        100,
      );
      expect(
        BackgroundVolumePolicy.foregroundEngineVolume(
            master: -5, muted: false, bgActive: false),
        0,
      );
    });
  });

  group('BackgroundVolumePolicy.active (the duck gate)', () {
    test('only enabled AND gate open AND not exhausted is active', () {
      expect(
        BackgroundVolumePolicy.active(enabled: true, gateOpen: true),
        isTrue,
      );
      // Armed at launch but the gate is shut: NO 副音, NO ducking.
      expect(
        BackgroundVolumePolicy.active(enabled: true, gateOpen: false),
        isFalse,
      );
      expect(
        BackgroundVolumePolicy.active(enabled: false, gateOpen: true),
        isFalse,
      );
      expect(
        BackgroundVolumePolicy.active(
            enabled: true, gateOpen: true, exhausted: true),
        isFalse,
      );
    });

    test('an out-of-scope media or an ended queue is NOT ducking', () {
      // 仅当前 left its anchor / 智能 met an unpaired media / user opt-out: the
      // pair is not a pair, so the foreground must play at master (it used to
      // stay ducked to 30% while 副音 was already silent).
      expect(
        BackgroundVolumePolicy.active(
            enabled: true, gateOpen: true, outOfScope: true),
        isFalse,
      );
      // The queue ran off its end under Repeat.none: nothing to sound.
      expect(
        BackgroundVolumePolicy.active(
            enabled: true, gateOpen: true, queueEnded: true),
        isFalse,
      );
      expect(
        BackgroundVolumePolicy.active(
            enabled: true, gateOpen: true, outOfScope: false, queueEnded: false),
        isTrue,
      );
    });
  });

  group('BackgroundVolumePolicy (bg engine)', () {
    test('off ⇒ background engine is silent', () {
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 80, muted: false, bgActive: false),
        0,
      );
    });

    test('on scales by the bg ratio (default 100%)', () {
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 80, muted: false, bgActive: true),
        80,
      );
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 50, muted: false, bgActive: true, bgPercent: 40),
        20,
      );
    });

    test('quick mute via bgPercent=0 silences the background engine', () {
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 80, muted: false, bgActive: true, bgPercent: 0),
        0,
      );
    });

    test('bgMuted silences the background track only', () {
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 80, muted: false, bgActive: true, bgMuted: true),
        0,
      );
      // bgMuted never affects the foreground (checked in the fg group).
    });

    test('bg off is silent regardless of bgMuted', () {
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 80, muted: false, bgActive: false, bgMuted: true),
        0,
      );
      expect(
        BackgroundVolumePolicy.backgroundEngineVolume(
            master: 80, muted: false, bgActive: false, bgMuted: false),
        0,
      );
    });
  });

  group('fvp scale', () {
    test('converts the 0–100 domain to 0–1', () {
      expect(BackgroundVolumePolicy.toFvpScale(0), 0.0);
      expect(BackgroundVolumePolicy.toFvpScale(50), 0.5);
      expect(BackgroundVolumePolicy.toFvpScale(100), 1.0);
    });
  });
}
