import 'package:flutter/material.dart' show BoxFit, ThemeMode;
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/bridge/state_bridge.dart';
import 'package:iris/models/enums/breadcrumb_start_side.dart'
    show BreadcrumbStartSide;
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/gesture/gesture_region_layout.dart'
    show defaultGestureLayoutProfiles;
import 'package:iris/models/store/title_overlay_config.dart';
import 'package:iris/widgets/popup.dart' show PopupDirection;

/// A state exercising every field family far away from its default.
AppState _richState() {
  final layout = defaultGestureLayoutProfiles.entries.first;
  return const AppState().copyWith(
    shuffle: true,
    repeat: Repeat.one,
    fit: BoxFit.cover,
    rate: 1.75,
    seekStepSeconds: 15,
    volume: 33,
    isMuted: true,
    themeMode: ThemeMode.dark,
    preferedSubtitleLanguage: 'chi',
    language: 'zh',
    autoCheckUpdate: true,
    autoResize: true,
    alwaysPlayFromBeginning: true,
    playerBackend: PlayerBackend.fvp,
    desktopControlBarLayout: DesktopControlBarLayout.stacked,
    sortBy: SortBy.lastModified,
    sortOrder: SortOrder.desc,
    folderFirst: false,
    storageBrowserPageSize: 250,
    phoneLandscapeSliderType: PhoneLandscapeSliderType.circleLeft,
    phoneLandscapeUseMode: PhoneLandscapeUseMode.leftSide,
    phoneOneHandedScrubberKind: PhoneOneHandedScrubberKind.snake,
    snakeFineWindowSeconds: 12,
    circleLandscapePercent: 65,
    centerZoneInwardAction: CircleSliderCenterAction.none,
    centerZoneOutwardAction: CircleSliderCenterAction.togglePlayPause,
    centerZoneTopAction: CircleSliderCenterAction.switchControlGroup,
    centerZoneBottomAction: CircleSliderCenterAction.none,
    desktopCenterZonePhoneMode: true,
    circleSliderScale: 0.8,
    preferredOrientation: ScreenOrientation.landscape,
    runtimeOrientation: ScreenOrientation.portrait,
    reuseLastOrientation: true,
    gestureMode: GestureMode.region,
    landscapeGestureProfile: LandscapeGestureProfile.rightHand,
    portraitGestureProfile: PortraitGestureProfile.classic,
    gestureLayoutProfiles: {layout.key: layout.value},
    showControlsOnPlayToPause: true,
    controlsTitleConfig: const TitleOverlayConfig(fontSize: 31),
    minimalTitleConfig: const TitleOverlayConfig(showTime: false, fontSize: 9),
    useClassicTitleBar: true,
    useLegacyControlBar: true,
    useLegacyStoragePersistence: true,
    useMetadataSettings: true, // the gate itself must survive roundtrips
    defaultPopupDirection: PopupDirection.left,
    breadcrumbStartPortrait: BreadcrumbStartSide.right,
    breadcrumbStartLandscape: BreadcrumbStartSide.left,
  );
}

void main() {
  group('StateBridge roundtrip fidelity', () {
    test('encodeRows → materialize reproduces the full state', () {
      final original = _richState();
      final rows = StateBridge.encodeRows(original);
      final restored = StateBridge.materialize(rows);

      expect(restored, isNotNull);
      expect(restored, original); // freezed == across every field
    });

    test('default state roundtrips too', () {
      final original = const AppState();
      final restored =
          StateBridge.materialize(StateBridge.encodeRows(original));
      expect(restored, original);
    });

    test('code-level toggle never becomes a row', () {
      final rows = StateBridge.encodeRows(_richState());
      expect(rows.keys, isNot(contains('app.useScenarioDrivenPlayback')));
    });
  });

  group('StateBridge error containment', () {
    test('malformed row is skipped, incompatible type poisons only itself', () {
      final rows = <String, String>{
        'app.volume': '{broken',
        'app.shuffle': 'true',
        'app.rate': '"not-a-number"',
      };
      final state = StateBridge.materialize(rows);

      expect(state, isNotNull);
      expect(state!.shuffle, isTrue); // good row survived
      expect(state.volume, 80, reason: 'poisoned row falls back to default');
      expect(state.rate, 1.0);
    });

    test('foreign-namespace rows are ignored', () {
      final state = StateBridge.materialize({
        'scenario.foo': '"x"',
        'app.shuffle': 'true',
      });
      expect(state!.shuffle, isTrue);
    });

    test('fully corrupt table yields null (caller falls back)', () {
      expect(StateBridge.materialize({'app.a': '{broken'}), isNull);
      expect(StateBridge.materialize(const {}), isNull);
    });
  });

  group('app. row dialect (jsonEncode, never ValueCodec)', () {
    test('encodeField emits JSON bools/strings/numbers', () {
      expect(StateBridge.encodeField(true), 'true');
      expect(StateBridge.encodeField(false), 'false');
      expect(StateBridge.encodeField('zh'), '"zh"');
      expect(StateBridge.encodeField(42), '42');
    });

    test('a ValueCodec bool ("1") would be dropped by materialize', () {
      // Guards the portable autoResize regression: the seed must use
      // encodeField, because a raw '1' is type-incompatible on reload.
      final fromValueCodec = StateBridge.materialize({'app.autoResize': '1'});
      expect(fromValueCodec?.autoResize ?? false, isFalse);

      final fromBridge = StateBridge.materialize(
        {'app.autoResize': StateBridge.encodeField(true)!},
      );
      expect(fromBridge!.autoResize, isTrue);
    });
  });

  group('gate peek on legacy blob', () {
    test('true only for exact gate flag', () {
      expect(StateBridge.gateEnabledInBlob('{"useMetadataSettings":true}'),
          isTrue);
      expect(StateBridge.gateEnabledInBlob('{"useMetadataSettings":false}'),
          isFalse);
      expect(StateBridge.gateEnabledInBlob('{}'), isFalse);
      expect(StateBridge.gateEnabledInBlob(null), isFalse);
      expect(StateBridge.gateEnabledInBlob('{broken'), isFalse);
    });
  });

  group('typed row readers (renderer fallback path)', () {
    test('readers decode the JSON dialect with fallbacks', () {
      final rows = StateBridge.encodeRows(_richState());
      expect(StateBridge.readBool(rows, 'shuffle'), isTrue);
      expect(StateBridge.readInt(rows, 'volume'), 33);
      expect(StateBridge.readDouble(rows, 'circleSliderScale'), 0.8);
      expect(StateBridge.readString(rows, 'playerBackend'), 'fvp');
      // Missing/malformed → fallback, never throw.
      expect(StateBridge.readInt(rows, 'nope', fallback: 5), 5);
      expect(
        StateBridge.readInt({'app.x': '{broken'}, 'x', fallback: 7),
        7,
      );
    });

    test('enum rows stay in bare-name dialect shared with defs.defaultValue',
        () {
      final rows = StateBridge.encodeRows(const AppState());
      expect(StateBridge.readString(rows, 'themeMode'), 'system');
      expect(StateBridge.readString(rows, 'playerBackend'), 'mediaKit');
    });
  });
}
