import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture fitness test for the legacy circle placement.
///
/// `phoneLandscapeSliderType` encodes ONE decision — "is the frozen legacy
/// circle panel on screen?" — and it is answered by exactly one function,
/// `useLegacyCircleSliderPanel` (lib/models/store/phone_landscape_slider_type_helper.dart).
/// It used to be spelled out by hand at three call sites
/// (`isMobile && isLandscape && type.isCircle`), and they drifted from the
/// anchor resolver: the resolver ignores the field under the meta gate, the
/// three mount sites did not. Gate ON + mode=normal + a stored `circleRight`
/// then mounted a panel the overlay placed bottom-centre, hid with the linear
/// downward slide and never told the settings dialog to dodge it.
///
/// The enum members themselves stay public — the store's pairing fold and the
/// SettingDef whitelist both need them — so this guard pins the CONSUMERS:
/// nothing under the widget/page/feature trees may decide the placement
/// itself. A new caller must go through the authority, which is where the gate
/// branch lives.
void main() {
  /// The one file allowed to spell the placement decision out.
  const String authority = 'phone_landscape_slider_type_helper.dart';

  /// Trees whose widgets mount or place the panel. The store
  /// (`sliderTypeForUseMode`, the load/gate-enable fold), the SettingDef
  /// whitelist, the enum itself and the localization labels all legitimately
  /// name the members, so they are outside this list by construction.
  const List<String> consumerTrees = <String>[
    'lib/pages',
    'lib/widgets',
    'lib/features',
  ];

  /// Spelled-out forms of the decision, as opposed to naming the enum members
  /// for something else. `.isCircle` is the getter; the qualified members are
  /// the hand-rolled `== circleRight || == circleLeft` spelling that three
  /// call sites used instead of the getter.
  const List<String> forbidden = <String>[
    'PhoneLandscapeSliderType.circleRight',
    'PhoneLandscapeSliderType.circleLeft',
    '.isCircle',
  ];

  test('no widget spells out the legacy circle placement itself', () {
    final offenders = <String>[];
    for (final String tree in consumerTrees) {
      final Directory dir = Directory(tree);
      expect(dir.existsSync(), isTrue,
          reason: 'run from the project root (flutter test default)');
      for (final FileSystemEntity entity in dir.listSync(recursive: true)) {
        if (entity is! File || !entity.path.endsWith('.dart')) continue;
        if (entity.path.endsWith(authority)) continue;
        // Generated code mirrors the enum; it is never hand-written.
        if (entity.path.endsWith('.g.dart') ||
            entity.path.endsWith('.freezed.dart')) {
          continue;
        }
        // Line comments quote the decision in prose ("the legacy circleRight /
        // circleLeft placement options are folded away") — only CODE counts.
        final String code = entity
            .readAsLinesSync()
            .map((String line) {
              final int comment = line.indexOf('//');
              return comment < 0 ? line : line.substring(0, comment);
            })
            .join('\n');
        for (final String token in forbidden) {
          if (code.contains(token)) {
            offenders.add('${entity.path}: $token');
          }
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'the legacy circle placement is decided in ONE place — '
            'useLegacyCircleSliderPanel — so the bar, the legacy bar and the '
            'More menu cannot answer differently from the anchor resolver');
  });
}
