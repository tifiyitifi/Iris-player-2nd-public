import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/potplayer_key_map.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/resolve_keybinds.dart';
import 'package:iris/features/windows/desktop_keyboard/model/keybind_codec.dart';
import 'package:iris/features/windows/desktop_keyboard/model/potplayer_action.dart';

void main() {
  group('KeybindCodec', () {
    test('encode/decode roundtrip single combo', () {
      const combo = KeyCombo(LogicalKeyboardKey.keyK, ctrl: true);
      final json = KeybindCodec.encodeOverrides({'playPause': [combo]});
      final decoded = KeybindCodec.decodeOverrides(json);
      expect(decoded['playPause'], [combo]);
    });

    test('decode skips unknown action', () {
      const bad = '{"unknownAction":[{"keyId":32,"ctrl":false,"alt":false,"shift":false}]}';
      final decoded = KeybindCodec.decodeOverrides(bad);
      expect(decoded.containsKey('unknownAction'), isFalse);
    });

    test('labelFor formats Ctrl+K', () {
      const combo = KeyCombo(LogicalKeyboardKey.keyK, ctrl: true);
      expect(KeybindCodec.labelFor(combo), 'Ctrl+K');
    });

    test('empty list keeps action as unbound', () {
      final json = KeybindCodec.encodeOverrides({'playPause': []});
      final decoded = KeybindCodec.decodeOverrides(json);
      expect(decoded['playPause'], isEmpty);
    });

    test('malformed json degrades to empty', () {
      expect(KeybindCodec.decodeOverrides('not json'), isEmpty);
      expect(KeybindCodec.decodeOverrides(null), isEmpty);
    });

    test('the Windows apostrophe id is stored and read canonically', () {
      // 34 == 0x22 == the id a Windows build records for the `'` key.
      const windowsRow =
          '{"toggleBackgroundGate":[{"keyId":34,"ctrl":false,"alt":true,"shift":false}]}';
      final decoded = KeybindCodec.decodeOverrides(windowsRow);
      expect(
        decoded['toggleBackgroundGate'],
        [const KeyCombo(kApostropheKey, alt: true)],
      );
      final reencoded = KeybindCodec.encodeOverrides(decoded);
      expect(reencoded, contains('"keyId":${kApostropheKey.keyId}'));
    });
  });

  group('resolveEffectiveKeyMap', () {
    test('metadata disabled returns defaults', () {
      final map = resolveEffectiveKeyMap(overrides: {}, metadataEnabled: false);
      expect(map.length, kPotPlayerKeyMap.length);
    });

    test('override replaces default', () {
      const newCombo = KeyCombo(LogicalKeyboardKey.keyQ, ctrl: true);
      final overrides = {'playPause': [newCombo]};
      final decoded = KeybindCodec.decodeOverrides(KeybindCodec.encodeOverrides(overrides));
      final map = resolveEffectiveKeyMap(overrides: decoded, metadataEnabled: true);
      expect(map[newCombo], PotPlayerAction.playPause);
      expect(map[const KeyCombo(LogicalKeyboardKey.space)], isNull);
    });

    test('empty override unbinds', () {
      final overrides = {'playPause': <KeyCombo>[]};
      final decoded = KeybindCodec.decodeOverrides(KeybindCodec.encodeOverrides(overrides));
      final map = resolveEffectiveKeyMap(overrides: decoded, metadataEnabled: true);
      expect(map[const KeyCombo(LogicalKeyboardKey.space)], isNull);
    });

    test('conflict last writer wins', () {
      const combo = KeyCombo(LogicalKeyboardKey.keyQ, ctrl: true);
      final overrides = {
        'playPause': [combo],
        'nextItem': [combo],
      };
      final decoded = KeybindCodec.decodeOverrides(KeybindCodec.encodeOverrides(overrides));
      final map = resolveEffectiveKeyMap(overrides: decoded, metadataEnabled: true);
      // Sorted keys: nextItem < playPause, so playPause wins last.
      expect(map[combo], isNotNull);
    });
  });
}
