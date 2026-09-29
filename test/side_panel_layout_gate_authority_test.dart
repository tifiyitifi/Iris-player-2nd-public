import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture fitness test for "is a SIDE panel on screen right now?".
///
/// Two authorities answer that, and they answer it at different altitudes:
///
///  - `isSidewayPanelMounted` — would a ONE-HANDED mode mount a panel? Used by
///    the mount sites (`ControlBar.build`) and by the resolver.
///  - `isSidePanelLayoutMounted` — is a side panel on screen in the layout the
///    player actually RENDERS? The same question minus the legacy control bar,
///    which is a full-width linear layout whatever the mode says.
///
/// The bug this guards: the overlay's hide direction / corner radius / 副音
/// `isSide`, the slider-type dialog's dodge region and the More menu's rate
/// fallback all read the RESULT of the mount, so they must read it through the
/// second one. Each was reading the first, which over-reports exactly when
/// `useLegacyControlBar` is on — a switch with no gate on it, so one tap away
/// in the legacy-compat dialog.
///
/// A file is exempt by path rather than by tree, because the two altitudes are
/// both legitimate in the same tree: `ControlBar.build` reads the bare gate and
/// is CORRECT, since the legacy bar replaces it in the widget tree. The rule is
/// therefore about the KIND of site — placement/dodge consumers, not mount
/// sites — and a blanket tree scan would flag the one call that is right.
void main() {
  /// The file allowed to define both authorities.
  const String authority = 'phone_landscape_slider_type_helper.dart';

  /// Placement/dodge consumers: anything that reacts to a panel being ON SCREEN
  /// (hiding it, framing it, dodging it, or deciding which rows a menu offers).
  const List<String> placementConsumers = <String>[
    'lib/pages/player/overlays/controls_overlay.dart',
    'lib/widgets/dialogs/show_slider_type_dialog.dart',
    'lib/pages/player/control_bar/control_bar_widgets/more_menu_button.dart',
  ];

  /// The bare spelling of the mount gate. Matching the call with its parenthesis
  /// keeps it distinguishable from `isSidePanelLayoutMounted`, which delegates to
  /// it and is the spelling these sites are required to use.
  const String forbidden = 'isSidewayPanelMounted(';

  test('placement consumers read isSidePanelLayoutMounted, not the bare gate',
      () {
    for (final String path in placementConsumers) {
      final File file = File(path);
      expect(file.existsSync(), isTrue,
          reason: 'run from the project root (flutter test default); '
              '$path must exist or this guard is vacuous');

      final String code = file
          .readAsLinesSync()
          .map((String line) {
            // Line comments quote the decision in prose — only CODE counts, so a
            // site may still explain in a comment why the bare gate is wrong.
            final int comment = line.indexOf('//');
            return comment < 0 ? line : line.substring(0, comment);
          })
          .join('\n');

      expect(code, contains('isSidePanelLayoutMounted'),
          reason: '$path places/dodges a panel, so it must go through '
              'isSidePanelLayoutMounted');
      expect(code, isNot(contains(forbidden)),
          reason: '$path must not call isSidewayPanelMounted directly — the '
              'bare gate over-reports whenever useLegacyControlBar is on, which '
              'silently slid a full-width linear bar out sideways and squeezed '
              'the settings card into a strip avoiding nothing');
    }
  });

  test('the authority file is the one that spells the gate out', () {
    final File file = File('lib/models/store/$authority');
    expect(file.existsSync(), isTrue);
    final String code = file.readAsStringSync();
    expect(code, contains('isSidePanelLayoutMounted'),
        reason: 'the authority must define the layout-level gate');
    expect(code, contains('isSidewayPanelMounted'),
        reason: 'and delegate to the mount gate it narrows');
  });
}
