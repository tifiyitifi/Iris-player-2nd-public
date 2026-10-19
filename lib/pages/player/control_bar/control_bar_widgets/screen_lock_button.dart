import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/screen_lock/store/use_screen_lock_store.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart';

/// On-bar screen-lock toggle (phone + tablet video only).
///
/// It takes the slot the 副音 menu button used to occupy on the playback row
/// (the 副音 menu moved into the 副音 control group). The guard is a touch
/// one, so the button never renders on desktop — [ControlBarControls
/// .showScreenLock] carries that condition, exactly as the More-menu entry did.
class ScreenLockButton extends HookWidget {
  const ScreenLockButton({
    super.key,
    required this.showControl,
    this.color,
    this.overlayColor,
  });

  /// The bar's auto-hide refresh: the guard is armed from a visible bar, and
  /// the tap must not let the bar vanish under the finger.
  final VoidCallback showControl;

  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final bool locked =
        useScreenLockStore().select(context, (s) => s.locked);

    return a11yTooltipIconButton(
      context: context,
      tooltip: locked ? t.screen_lock_unlock : t.screen_lock_lock,
      icon: Icon(
        locked ? Icons.lock_open_rounded : Icons.lock_outline_rounded,
        size: kIconSizeSecondary,
        color: color,
      ),
      onPressed: () {
        showControl();
        useScreenLockStore().toggle();
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );
  }
}
