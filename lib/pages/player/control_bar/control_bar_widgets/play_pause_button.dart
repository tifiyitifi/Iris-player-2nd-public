import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/windows/desktop_keyboard/view/shortcut_hints.dart';
import 'package:iris/models/player.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/store/use_scrub_drag_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:provider/provider.dart';

class PlayPauseButton extends HookWidget {
  const PlayPauseButton({
    super.key,
    required this.showControl,
    this.color,
    this.overlayColor,
  });

  final void Function() showControl;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);

    final isPlaying = context.select<MediaPlayer, bool>((p) => p.isPlaying);
    final isInitializing =
        context.select<MediaPlayer, bool>((p) => p.isInitializing);
    final isSeeking = useScrubDragStore().select(context, (s) => s.isScrubbing);
    final scheme = useEffectiveKeyboardScheme(context);

    final displayIsPlaying = useState(isPlaying);

    useEffect(() {
      if (!isSeeking) {
        displayIsPlaying.value = isPlaying;
      }
      return null;
    }, [isPlaying, isSeeking]);

    return Stack(
      alignment: Alignment.center,
      children: [
        // AXTree stability: keep the loading indicator subtree always mounted
        // (Offstage hides it from semantics + layout) so isInitializing flips
        // do not create/destroy a semantics node and trigger the Windows UIA
        // bridge reparent race (flutter/flutter #98099/#182444).
        // TickerMode disabled when offstage so pumpAndSettle can settle in tests
        // (CircularProgressIndicator's animation ticker would otherwise never settle).
        Offstage(
          offstage: !isInitializing,
          child: TickerMode(
            enabled: isInitializing,
            child: SizedBox(
              width: kIconSizePlayPause,
              height: kIconSizePlayPause,
              child: CircularProgressIndicator(
                strokeWidth: 4,
                color: Theme.of(context).colorScheme.surface,
              ),
            ),
          ),
        ),
        a11yTooltipIconButton(
          context: context,
          tooltip:
              '${displayIsPlaying.value ? t.pause : t.play} ( ${shortcutHintLabelFor(ShortcutHintKind.playPause, scheme)} )',
          icon: Icon(
            displayIsPlaying.value
                ? Icons.pause_rounded
                : Icons.play_arrow_rounded,
            size: kIconSizePlayPause,
            color: color,
          ),
          onPressed: () {
            showControl();
            // ONE owner publishes the transport flag (ADR 0018): it writes
            // `bgAutoPlay` while 副音 owns the controls and the foreground
            // preference otherwise, so a surface can never leave the other
            // runtime's flag stale.
            setActiveTransportFlag(context, playing: !isPlaying);
            if (isPlaying) {
              context.read<MediaPlayer>().pause();
            } else {
              context.read<MediaPlayer>().play();
            }
          },
          style: ButtonStyle(overlayColor: overlayColor),
        ),
      ],
    );
  }
}
