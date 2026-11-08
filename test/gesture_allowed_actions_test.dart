import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/gesture_region.dart';
import 'package:iris/models/store/gesture/gesture_region_layout.dart';
import 'package:iris/pages/player/overlays/gesture_region_editor/gesture_settings_entry.dart';

/// `getAllowedActions` backs the action picker of the region editor. The phone
/// gesture guide's pencil opens that editor directly for EVERY page it shows,
/// so the function must be total over [GestureIntent] — a missing case threw
/// `UnimplementedError` inside the route builder and left the pan /
/// long-press-pan pages uneditable.
void main() {
  test('every gesture intent has an editor action list', () {
    for (final intent in GestureIntent.values) {
      expect(
        () => getAllowedActions(intent),
        returnsNormally,
        reason: 'the guide can open the editor for $intent directly',
      );
      expect(
        getAllowedActions(intent),
        isNotEmpty,
        reason: '$intent needs at least one assignable action',
      );
    }
  });

  test('every action configured by a default layout is offered by the editor',
      () {
    for (final profile in defaultGestureLayoutProfiles.entries) {
      for (final entry in profile.value.entries) {
        final allowed = getAllowedActions(entry.key);
        for (final region in entry.value.regions) {
          expect(
            allowed,
            contains(region.action.type),
            reason: '${profile.key} / ${entry.key} defaults to '
                '${region.action.type.name}, so the picker must show it '
                '(otherwise the current value cannot even be displayed)',
          );
        }
      }
    }
  });

  test('pan and long-press-pan pages expose the actions they actually run', () {
    expect(
      getAllowedActions(GestureIntent.panHorizontal),
      containsAll(<GestureActionType>[
        GestureActionType.none,
        GestureActionType.seekTo,
      ]),
    );
    for (final intent in <GestureIntent>[
      GestureIntent.longPressPanHorizontal,
      GestureIntent.longPressPanVertical,
    ]) {
      expect(
        getAllowedActions(intent),
        containsAll(<GestureActionType>[
          GestureActionType.none,
          GestureActionType.updateTransientSpeed,
          GestureActionType.updatePlaybackRateFromSelector,
        ]),
        reason: '$intent keeps updating the speed armed by the long press',
      );
    }
    expect(
      getAllowedActions(GestureIntent.hover),
      containsAll(<GestureActionType>[
        GestureActionType.none,
        GestureActionType.toggleControls,
      ]),
    );
  });
}
