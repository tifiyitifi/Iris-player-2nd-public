import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/video_transform/model/enum/video_rotation.dart';
import 'package:iris/features/video_transform/store/video_transform_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';

/// The player's "picture adjustment" panel (More -> 画面调整).
///
/// Session-scoped mirror/rotation plus color sliders. All of it is deliberately
/// runtime-only: the controls reset when the media changes and on restart.
class VideoTransformPanel extends HookWidget {
  const VideoTransformPanel({super.key});

  @override
  Widget build(BuildContext context) {
    final AppLocalizations t = getLocalizations(context);
    final store = useVideoTransformStore();
    final state = store.select(context, (s) => s);

    return ListView(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 12),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: Text(
            t.video_transform_panel_title,
            style: Theme.of(context).textTheme.titleMedium,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
          child: Text(
            t.video_transform_session_hint,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
          ),
        ),
        _sectionLabel(context, t.video_transform_orientation),
        _switchRow(
          label: t.video_transform_flip_horizontal,
          value: state.flipHorizontal,
          onChanged: store.setFlipHorizontal,
          resetIcon: _resetIcon(
            tooltip:
                t.video_transform_reset_item(t.video_transform_flip_horizontal),
            enabled: state.flipHorizontal,
            onPressed: store.resetFlipHorizontal,
          ),
        ),
        _switchRow(
          label: t.video_transform_flip_vertical,
          value: state.flipVertical,
          onChanged: store.setFlipVertical,
          resetIcon: _resetIcon(
            tooltip:
                t.video_transform_reset_item(t.video_transform_flip_vertical),
            enabled: state.flipVertical,
            onPressed: store.resetFlipVertical,
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 8, 4),
          child: Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final VideoRotation rotation in VideoRotation.values)
                      ChoiceChip(
                        label: Text(_rotationLabel(t, rotation)),
                        selected: state.rotation == rotation,
                        onSelected: (_) => store.setRotation(rotation),
                      ),
                  ],
                ),
              ),
              _resetIcon(
                // The row resets ROTATION only; the two mirrors belong to their
                // own rows, so the group label would promise too much.
                tooltip:
                    t.video_transform_reset_item(t.video_transform_rotation),
                enabled: state.rotation != VideoRotation.none,
                onPressed: store.resetRotation,
              ),
            ],
          ),
        ),
        _sectionLabel(context, t.video_transform_color),
        _ColorSlider(
          label: t.video_transform_brightness,
          value: state.brightness,
          onChanged: store.setBrightness,
          resetIcon: _resetIcon(
            tooltip: t.video_transform_reset_item(t.video_transform_brightness),
            // Match what the row SHOWS (`(value*100).round()`): a tiny drag
            // that still reads "0" must not enable a reset that appears to do
            // nothing.
            enabled: _shownNonZero(state.brightness),
            onPressed: store.resetBrightness,
          ),
        ),
        _ColorSlider(
          label: t.video_transform_contrast,
          value: state.contrast,
          onChanged: store.setContrast,
          resetIcon: _resetIcon(
            tooltip: t.video_transform_reset_item(t.video_transform_contrast),
            enabled: _shownNonZero(state.contrast),
            onPressed: store.resetContrast,
          ),
        ),
        _ColorSlider(
          label: t.video_transform_saturation,
          value: state.saturation,
          onChanged: store.setSaturation,
          resetIcon: _resetIcon(
            tooltip: t.video_transform_reset_item(t.video_transform_saturation),
            enabled: _shownNonZero(state.saturation),
            onPressed: store.resetSaturation,
          ),
        ),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            onPressed: state.isNeutral ? null : store.resetAll,
            icon: const Icon(Icons.restart_alt_rounded, size: 18),
            label: Text(t.video_transform_reset_all),
          ),
        ),
      ],
    );
  }

  /// `SwitchListTile` has no trailing slot (only `secondary`, which sits on the
  /// leading side), so the switch row is composed explicitly to keep the reset
  /// affordance trailing, after the switch.
  Widget _switchRow({
    required String label,
    required bool value,
    required ValueChanged<bool> onChanged,
    required Widget resetIcon,
  }) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 8),
      title: Text(label),
      // `SwitchListTile` makes the whole row toggle; composing the row by hand
      // must keep that affordance or the label becomes inert.
      onTap: () => onChanged(!value),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Switch.adaptive(value: value, onChanged: onChanged),
          resetIcon,
        ],
      ),
    );
  }

  /// One row's reset affordance. Disabled while its field is at its default,
  /// so it can never be a no-op button.
  Widget _resetIcon({
    required String tooltip,
    required bool enabled,
    required VoidCallback onPressed,
  }) {
    return IconButton(
      padding: EdgeInsets.zero,
      // Material's minimum touch target is 48dp; a 36dp icon is hard to hit on
      // a phone.
      constraints: const BoxConstraints.tightFor(width: 48, height: 48),
      icon: const Icon(Icons.restart_alt_rounded, size: 18),
      tooltip: tooltip,
      onPressed: enabled ? onPressed : null,
    );
  }

  /// Whether a color value renders as a non-zero percentage.
  ///
  /// The row shows `(value * 100).round()`, so this is the only threshold that
  /// keeps the reset button consistent with the number beside it.
  bool _shownNonZero(double value) => (value * 100).round() != 0;

  Widget _sectionLabel(BuildContext context, String text) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 12, 8, 4),
      child: Text(
        text,
        style: Theme.of(context).textTheme.labelLarge?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
      ),
    );
  }

  String _rotationLabel(AppLocalizations t, VideoRotation rotation) {
    switch (rotation) {
      case VideoRotation.none:
        return t.video_transform_rotate_0;
      case VideoRotation.cw90:
        return t.video_transform_rotate_90;
      case VideoRotation.cw180:
        return t.video_transform_rotate_180;
      case VideoRotation.cw270:
        return t.video_transform_rotate_270;
    }
  }
}

/// One -1..1 color slider (0 = neutral, matching both backend scales).
class _ColorSlider extends StatelessWidget {
  const _ColorSlider({
    required this.label,
    required this.value,
    required this.onChanged,
    required this.resetIcon,
  });

  final String label;
  final double value;
  final ValueChanged<double> onChanged;
  final Widget resetIcon;

  @override
  Widget build(BuildContext context) {
    final int percent = (value * 100).round();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(label),
              const Spacer(),
              Text('$percent'),
              resetIcon,
            ],
          ),
          Slider(
            value: value.clamp(-1.0, 1.0),
            min: -1,
            max: 1,
            label: '$percent',
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }
}
