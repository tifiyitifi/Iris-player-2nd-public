import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/settings_transfer/engine/platform_key_policy.dart';
import 'package:iris/features/settings_transfer/model/export_envelope.dart';

// Cross-platform transfer policy: same-platform migrates everything,
// cross-platform (desktop <-> mobile) keeps common + target-platform keys
// and skips source-platform-only keys (notably WebDAV/FTP storages always
// migrate — they are the primary limited-interop scenario).
void main() {
  group('transferPlatformName', () {
    test('maps every TargetPlatform to the settings-transfer id', () {
      expect(transferPlatformName(TargetPlatform.android), 'android');
      expect(transferPlatformName(TargetPlatform.iOS), 'ios');
      expect(transferPlatformName(TargetPlatform.windows), 'windows');
      expect(transferPlatformName(TargetPlatform.linux), 'linux');
      expect(transferPlatformName(TargetPlatform.macOS), 'macos');
    });
  });

  group('PlatformKeyPolicy snapshot fields', () {
    test('desktop file -> android keeps common, skips desktop-only', () {
      const snapshot = <String, dynamic>{
        'language': 'zh',
        'volume': 80,
        'autoResize': true,
        'keyboardShortcutScheme': 'potplayer',
        'desktopControlBarLayout': 'stacked',
        'preferredOrientation': 'landscape',
        'gestureMode': 'classic',
      };
      final kept = snapshot.keys
          .where((k) => PlatformKeyPolicy.isTransferableSnapshotField(k, 'android'))
          .toSet();
      expect(kept, containsAll(['language', 'volume', 'preferredOrientation', 'gestureMode']));
      expect(kept, isNot(contains('autoResize')));
      expect(kept, isNot(contains('keyboardShortcutScheme')));
      expect(kept, isNot(contains('desktopControlBarLayout')));
    });

    test('android file -> windows keeps common, skips mobile-only', () {
      const snapshot = <String, dynamic>{
        'language': 'en',
        'autoResize': true,
        'preferredOrientation': 'landscape',
        'gestureMode': 'classic',
        'controlsTitleConfig': {'x': 1},
        'defaultPopupDirection': 'right',
        'breadcrumbStartPortrait': 'left',
      };
      final kept = snapshot.keys
          .where((k) => PlatformKeyPolicy.isTransferableSnapshotField(k, 'windows'))
          .toSet();
      expect(kept, containsAll(['language', 'autoResize']));
      expect(kept, isNot(contains('preferredOrientation')));
      expect(kept, isNot(contains('gestureMode')));
      expect(kept, isNot(contains('controlsTitleConfig')));
      expect(kept, isNot(contains('defaultPopupDirection')));
      expect(kept, isNot(contains('breadcrumbStartPortrait')));
    });

    test('same platform keeps everything', () {
      expect(PlatformKeyPolicy.isTransferableSnapshotField('autoResize', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableSnapshotField('gestureMode', 'android'), isTrue);
      expect(PlatformKeyPolicy.isTransferableSnapshotField('language', 'windows'), isTrue);
    });

    test('unknown platform keeps everything (legacy files without stamp)', () {
      expect(PlatformKeyPolicy.isTransferableSnapshotField('autoResize', 'unknown'), isTrue);
      expect(PlatformKeyPolicy.isTransferableSnapshotField('gestureMode', 'unknown'), isTrue);
    });

    test('the slider type crosses to desktop; the use mode stays phone-only', () {
      // The one-handed SIDE PANEL runs on desktop too (opt-in via
      // `desktopCenterZonePhoneMode`), and the slider-type dialog is exposed
      // there — `app_settings_contribution` declares the row visible on
      // android/windows/linux/macos, and the parity test lists it among the
      // DESKTOP play keys. Classifying the snapshot field as mobile-only used
      // to drop the user's slider type on every android<->desktop transfer.
      expect(PlatformKeyPolicy.isTransferableSnapshotField('phoneLandscapeSliderType', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableSnapshotField('phoneLandscapeSliderType', 'linux'), isTrue);
      expect(PlatformKeyPolicy.isTransferableSnapshotField('phoneLandscapeSliderType', 'android'), isTrue);

      // Its sibling is genuinely phone-only (the contribution declares
      // `app.phoneLandscapeUseMode` android-only), and stays that way.
      expect(PlatformKeyPolicy.isTransferableSnapshotField('phoneLandscapeUseMode', 'windows'), isFalse);
      expect(PlatformKeyPolicy.isTransferableSnapshotField('phoneLandscapeUseMode', 'android'), isTrue);
    });

    test('a desktop-configured slider type now reaches a phone import', () {
      // The round-trip that actually regressed: a desktop user picks
      // circleLeft, exports, imports on Android. The row must survive.
      const snapshot = <String, dynamic>{
        'language': 'zh',
        'phoneLandscapeSliderType': 'circleLeft',
        'autoResize': true,
      };
      final kept = snapshot.keys
          .where((k) => PlatformKeyPolicy.isTransferableSnapshotField(k, 'android'))
          .toSet();
      expect(kept, contains('phoneLandscapeSliderType'));
      expect(kept, contains('language'));
      expect(kept, isNot(contains('autoResize')),
          reason: 'unrelated desktop-only knobs must still be skipped');
    });
  });

  group('PlatformKeyPolicy AUX rows', () {
    test('desktop AUX rows skipped on android, generic rows kept', () {
      expect(PlatformKeyPolicy.isTransferableAuxKey('window.fitMode', 'android'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('keybind.overrides', 'android'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('osd.enabled', 'android'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('video.desktopDisplayMode', 'android'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('screenshot.desktopDir', 'android'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('screenshot.mobileDir', 'android'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('dialring.palette', 'android'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('browse.mediaScope', 'android'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('playback.resumeOnStartup', 'android'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('slider.phonePosH', 'android'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('video.mobileDisplayMode', 'android'), isTrue);
    });

    test('both corner-hide rows cross a transfer in either direction', () {
      // They are per-platform rows, not platform-scoped ones: moving a device
      // should carry each device's own choice to the new one. Skipping them
      // would silently reset the panel's hide direction on arrival.
      for (final key in <String>[
        'slider.cornerHideMode',
        'slider.phoneCornerHideMode',
      ]) {
        expect(PlatformKeyPolicy.isTransferableAuxKey(key, 'android'), isTrue,
            reason: '$key must reach a phone');
        expect(PlatformKeyPolicy.isTransferableAuxKey(key, 'ios'), isTrue,
            reason: '$key must reach a phone');
        expect(PlatformKeyPolicy.isTransferableAuxKey(key, 'windows'), isTrue,
            reason: '$key must reach a desktop');
      }
    });

    test('mobile AUX rows skipped on windows, generic rows kept', () {
      expect(PlatformKeyPolicy.isTransferableAuxKey('video.mobileDisplayMode', 'windows'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('screenshot.mobileDir', 'windows'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('screenshot.desktopDir', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('window.fitMode', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('osd.enabled', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('dialring.palette', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('speed.mode', 'windows'), isTrue);
      expect(PlatformKeyPolicy.isTransferableAuxKey('virtualmedia.strategy', 'windows'), isTrue);
    });

    test('the cross-platform queue rows survive a transfer in BOTH directions', () {
      // These sit under the `window.` prefix but describe a preference the
      // play queue has on a phone too. Reading the prefix literally dropped them
      // from every phone restore, silently resetting the layout on the device the
      // user was moving to.
      for (final key in PlatformKeyPolicy.crossPlatformWindowAux) {
        expect(PlatformKeyPolicy.isTransferableAuxKey(key, 'android'), isTrue,
            reason: '$key must reach a phone');
        expect(PlatformKeyPolicy.isTransferableAuxKey(key, 'ios'), isTrue,
            reason: '$key must reach a phone');
        expect(PlatformKeyPolicy.isTransferableAuxKey(key, 'windows'), isTrue,
            reason: '$key must reach a desktop');
      }
      // The genuinely desktop-only window rows are unaffected by that exception.
      expect(PlatformKeyPolicy.isTransferableAuxKey('window.fitMode', 'android'), isFalse);
      expect(PlatformKeyPolicy.isTransferableAuxKey('window.playlistPanelWidth', 'android'), isFalse);
    });

    test('skip note is stable for the import report', () {
      expect(PlatformKeyPolicy.skipNoteFor('window.fitMode', 'android', isAuxRow: true), kPlatformSkippedNote);
      expect(PlatformKeyPolicy.skipNoteFor('autoResize', 'android'), kPlatformSkippedNote);
      expect(PlatformKeyPolicy.skipNoteFor('language', 'android'), isNull);
      expect(
        PlatformKeyPolicy.skipNoteFor('window.scenarioQueueLayoutPortrait', 'android',
            isAuxRow: true),
        isNull,
      );
    });
  });

  group('ExportEnvelope sourcePlatform', () {
    test('create stamps current platform and roundtrip preserves it', () async {
      final env = await ExportEnvelope.create({
        'appSettings': {'subVersion': 1},
      });
      expect(env.sourcePlatform, isNotEmpty);
      expect(env.sourcePlatform, isNot('unknown'));
      final back = ExportEnvelope.decode(env.encode());
      expect(back.sourcePlatform, env.sourcePlatform);
      expect(back.sections, contains('appSettings'));
    });

    test('payload without stamp decodes as unknown (legacy files)', () {
      const raw = '{"format":2,"appVersion":"x","exportedAt":"t","sections":{}}';
      expect(ExportEnvelope.decode(raw).sourcePlatform, 'unknown');
    });
  });
}
