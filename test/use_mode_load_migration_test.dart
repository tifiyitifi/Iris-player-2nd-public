import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/store/app_state.dart';

/// The deprecated one-handed modes must stay PARSEABLE forever while being
/// unreachable as a choice.
///
/// [PhoneLandscapeUseMode.rightHanded] / [leftHanded] are kept in the enum so a
/// blob written by an older build still deserializes; the loader folds them
/// into their `*Side` replacements in `_normalizeLoaded` before anything reads
/// the state, and the pickers list only `kLivePhoneLandscapeUseModes`. This
/// test pins the parse side of that contract — the fold itself is covered by
/// the store's load path.
void main() {
  test('deprecated hand modes still round-trip through the blob codec', () {
    // Parsing must not throw and must keep the value, otherwise an old install
    // would silently reset to `normal` and lose its one-handed layout.
    final AppState parsed = AppState.fromJson(<String, dynamic>{
      'phoneLandscapeUseMode': 'rightHanded',
    });
    expect(parsed.phoneLandscapeUseMode, PhoneLandscapeUseMode.rightHanded);

    final AppState left = AppState.fromJson(<String, dynamic>{
      'phoneLandscapeUseMode': 'leftHanded',
    });
    expect(left.phoneLandscapeUseMode, PhoneLandscapeUseMode.leftHanded);
  });

  test('the live side modes round-trip unchanged', () {
    for (final PhoneLandscapeUseMode mode in <PhoneLandscapeUseMode>[
      PhoneLandscapeUseMode.normal,
      PhoneLandscapeUseMode.rightSide,
      PhoneLandscapeUseMode.leftSide,
    ]) {
      expect(
        AppState.fromJson(<String, dynamic>{
          'phoneLandscapeUseMode': mode.name,
        }).phoneLandscapeUseMode,
        mode,
      );
    }
  });
}
