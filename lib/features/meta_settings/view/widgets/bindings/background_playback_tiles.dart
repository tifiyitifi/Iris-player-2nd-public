// Part of editor_bindings.dart - row widgets bound to the background-playback
// store (values live in that store, not the `app.` snapshot).
part of '../editor_bindings.dart';

/// Inline switch row bound to the 副音 background-playback store (values do
/// NOT live in the `app.` snapshot, so the generic toggle is unavailable).
class _BgBoundSwitchTile extends HookWidget {
  const _BgBoundSwitchTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.valueOf,
    required this.apply,
    this.confirmOffTitleKey,
    this.confirmOffBodyKey,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final bool Function(BackgroundPlaybackState s) valueOf;
  final Future<void> Function(BackgroundPlaybackStore bg, bool v) apply;

  /// When set, turning the switch OFF first shows an explanatory dialog and
  /// only writes on confirm (never a SnackBar).
  final String? confirmOffTitleKey;
  final String? confirmOffBodyKey;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final bool live = bg.select(context, (s) => valueOf(s));
    final t = getLocalizations(context);
    final String? subtitle =
        subtitleKey == null ? null : SettingTexts.subtitle(subtitleKey!, t);

    Future<void> setValue(bool v) async {
      if (!v && confirmOffBodyKey != null) {
        final confirmed = await showDialog<bool>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            title: Text(
              SettingTexts.title(confirmOffTitleKey ?? titleKey, t),
            ),
            content: Text(
              SettingTexts.subtitle(confirmOffBodyKey!, t),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(false),
                child: Text(t.cancel),
              ),
              FilledButton(
                onPressed: () => Navigator.of(dialogContext).pop(true),
                child: Text(t.ok),
              ),
            ],
          ),
        );
        if (confirmed != true) return;
      }
      await apply(bg, v);
    }

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => unawaited(setValue(!live)),
      trailing: Switch(
        value: live,
        onChanged: (bool v) => unawaited(setValue(v)),
      ),
    );
  }
}

/// Integer row bound to the 副音 store — opens a min..max slider dialog and
/// writes back through the store mutator. (No text input, so no keyboard/scroll
/// concerns; the slider keeps it phone- and desktop-friendly.)
class _BgBoundIntTile extends HookWidget {
  const _BgBoundIntTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.min,
    required this.max,
    this.suffix = ' s',
    required this.valueOf,
    required this.apply,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final int min;
  final int max;

  /// Unit label appended to the value (default the legacy `' s'`); pass `''`
  /// for unit-less counts such as the snap release limit.
  final String suffix;
  final int Function(BackgroundPlaybackState s) valueOf;
  final Future<void> Function(BackgroundPlaybackStore bg, int v) apply;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final int current = bg.select(context, (s) => valueOf(s));
    final t = getLocalizations(context);
    final String? subtitle =
        subtitleKey == null ? null : SettingTexts.subtitle(subtitleKey!, t);

    Future<void> pick() async {
      var draft = current.clamp(min, max);
      final picked = await showDialog<int>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setLocal) {
            final w = MediaQuery.sizeOf(dialogContext).width;
            final h = MediaQuery.sizeOf(dialogContext).height;
            final available =
                h * 0.9 - MediaQuery.viewInsetsOf(dialogContext).bottom;
            return AlertDialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
              title: Text(SettingTexts.title(titleKey, t)),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (w - 24).clamp(0.0, 560.0),
                  maxHeight: available,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('$draft$suffix'),
                      Slider(
                        key: const ValueKey('bg_align_restart_gap_slider'),
                        value: draft.toDouble(),
                        min: min.toDouble(),
                        max: max.toDouble(),
                        divisions: max - min,
                        label: '$draft$suffix',
                        onChanged: (v) =>
                            setLocal(() => draft = v.round().clamp(min, max)),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(t.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(draft),
                  child: Text(t.ok),
                ),
              ],
            );
          },
        ),
      );
      if (picked != null) await apply(bg, picked);
    }

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => unawaited(pick()),
      trailing: Text('$current$suffix'),
    );
  }
}

/// Double row bound to the 副音 store — opens a min..max slider dialog and
/// writes back through the store mutator (used by the fg zoom multiplier).
class _BgBoundDoubleTile extends HookWidget {
  const _BgBoundDoubleTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.min,
    required this.max,
    required this.valueOf,
    required this.apply,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final double min;
  final double max;
  final double Function(BackgroundPlaybackState s) valueOf;
  final Future<void> Function(BackgroundPlaybackStore bg, double v) apply;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final double current = bg.select(context, (s) => valueOf(s));
    final t = getLocalizations(context);
    final String? subtitle =
        subtitleKey == null ? null : SettingTexts.subtitle(subtitleKey!, t);
    String fmt(double v) => v.toStringAsFixed(1);

    Future<void> pick() async {
      var draft = current.clamp(min, max);
      final int divisions = ((max - min) * 10).round().clamp(1, 1000);
      final picked = await showDialog<double>(
        context: context,
        builder: (dialogContext) => StatefulBuilder(
          builder: (dialogContext, setLocal) {
            final w = MediaQuery.sizeOf(dialogContext).width;
            final h = MediaQuery.sizeOf(dialogContext).height;
            final available =
                h * 0.9 - MediaQuery.viewInsetsOf(dialogContext).bottom;
            return AlertDialog(
              insetPadding:
                  const EdgeInsets.symmetric(horizontal: 12, vertical: 24),
              title: Text(SettingTexts.title(titleKey, t)),
              content: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: (w - 24).clamp(0.0, 560.0),
                  maxHeight: available,
                ),
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text('${fmt(draft)}×'),
                      Slider(
                        key: const ValueKey('bg_fg_window_zoom_slider'),
                        value: draft,
                        min: min,
                        max: max,
                        divisions: divisions,
                        label: '${fmt(draft)}×',
                        onChanged: (v) => setLocal(
                          () => draft =
                              ((v * 10).round() / 10).clamp(min, max),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: Text(t.cancel),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(dialogContext).pop(draft),
                  child: Text(t.ok),
                ),
              ],
            );
          },
        ),
      );
      if (picked != null) await apply(bg, picked);
    }

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => unawaited(pick()),
      trailing: Text('${fmt(current)}×'),
    );
  }
}

/// Enum row bound to the 副音 background-playback store — opens the shared
/// radio dialog and writes back through the store mutator.
class _BgBoundEnumTile<T extends Enum> extends HookWidget {
  const _BgBoundEnumTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.defKey,
    required this.values,
    required this.valueOf,
    required this.apply,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final String defKey;
  final List<T> values;
  final T Function(BackgroundPlaybackState s) valueOf;
  final Future<void> Function(BackgroundPlaybackStore bg, T v) apply;

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final T current = bg.select(context, (s) => valueOf(s));
    final t = getLocalizations(context);
    final String? subtitle =
        subtitleKey == null ? null : SettingTexts.subtitle(subtitleKey!, t);

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () {
        showEnumRadioDialog<T>(
          context: context,
          title: SettingTexts.title(titleKey, t),
          values: values,
          currentValue: current,
          labelOf: (v) => SettingTexts.enumLabel(defKey, v.name, t),
          onSelected: (v) => unawaited(apply(bg, v)),
        );
      },
      trailing: Text(SettingTexts.enumLabel(defKey, current.name, t)),
    );
  }
}
