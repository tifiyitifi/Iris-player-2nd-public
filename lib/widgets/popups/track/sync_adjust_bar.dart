import 'package:flutter/material.dart';
import 'package:iris/models/player.dart';
import 'package:iris/utils/get_localizations.dart';

/// Subtitle/audio sync nudge bar inside the track panel.
///
/// Rendered only when the backend reports [MediaPlayer.supportsSyncAdjustment]
/// (mediaKit). Shares the exact 0.5s ladder with the keyboard triads
/// (`>` `<` `/` and Shift variants) via [kSyncStep].
///
/// Laid out with a [Wrap], not a fixed [Row]: on a 360dp phone the two
/// three-button clusters plus the step label exceed the panel width, and the
/// old Row overflowed by ~28px (the yellow/black stripes seen on-device). A Wrap
/// keeps each cluster intact and moves the step label to a second line rather
/// than clipping content.
class SyncAdjustBar extends StatelessWidget {
  const SyncAdjustBar({super.key, required this.player});

  final MediaPlayer player;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final step = kSyncStepSeconds();
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 0),
      child: Wrap(
        spacing: 16,
        runSpacing: 2,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: [
          _cluster(context, Icons.subtitles_rounded, t.track_subtitle, step,
              () => player.nudgeSubtitleSync(-1),
              () => player.resetSubtitleSync(),
              () => player.nudgeSubtitleSync(1)),
          _cluster(context, Icons.graphic_eq_rounded, t.track_audio, step,
              () => player.nudgeAudioSync(-1),
              () => player.resetAudioSync(),
              () => player.nudgeAudioSync(1)),
          Text(
            t.track_sync_step(step),
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ],
      ),
    );
  }

  Widget _cluster(
    BuildContext context,
    IconData icon,
    String label,
    String step,
    VoidCallback onBack,
    VoidCallback onReset,
    VoidCallback onForward,
  ) {
    final t = getLocalizations(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 4),
        Text(label, style: Theme.of(context).textTheme.bodySmall),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: t.track_sync_earlier(step),
          icon: const Icon(Icons.remove_circle_outline_rounded, size: 20),
          onPressed: onBack,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: t.track_sync_reset,
          icon: const Icon(Icons.restart_alt_rounded, size: 18),
          onPressed: onReset,
        ),
        IconButton(
          visualDensity: VisualDensity.compact,
          tooltip: t.track_sync_later(step),
          icon: const Icon(Icons.add_circle_outline_rounded, size: 20),
          onPressed: onForward,
        ),
      ],
    );
  }
}

/// [kSyncStep] as the label/tooltip numeral: `500ms` → `"0.5"`, `1s` → `"1"`.
/// Keeps the "0.5" out of the ARB — only the step size owns it.
String kSyncStepSeconds() {
  final seconds = kSyncStep.inMilliseconds / 1000;
  return seconds == seconds.roundToDouble()
      ? seconds.toStringAsFixed(0)
      : seconds.toString();
}
