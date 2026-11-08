// Part of editor_bindings.dart - generic metadata row widgets shared by all
// domains (toggle, inline slider and dialog-backed card rows).
part of '../editor_bindings.dart';

class _BoundSwitchTile extends HookWidget {
  const _BoundSwitchTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.valueOf,
    required this.apply,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final bool Function(AppState s) valueOf;
  final Future<void> Function(AppStore store, bool v) apply;

  @override
  Widget build(BuildContext context) {
    final AppStore store = useAppStore();
    final AppLocalizations t = getLocalizations(context);
    // Row-scoped subscription: rebuild only when this switch's value changes.
    final bool live = store.select(context, (s) => valueOf(s));
    final String? subtitle =
        subtitleKey == null ? null : SettingTexts.subtitle(subtitleKey!, t);

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => unawaited(apply(store, !live)),
      trailing: Switch(
        value: live,
        onChanged: (bool v) => unawaited(apply(store, v)),
      ),
    );
  }
}

class _ScanPromptSwitchTile extends HookWidget {
  const _ScanPromptSwitchTile();

  @override
  Widget build(BuildContext context) {
    final scanStore = useRecursiveScanStore();
    final AppLocalizations t = getLocalizations(context);
    // Row-scoped subscription: rebuild only when the switch's value changes.
    final bool live = scanStore.select(context, (s) => s.autoClosePrompt);

    return ListTile(
      leading: const Icon(Icons.timer_off_outlined),
      title: Text(SettingTexts.title('set_scan_completion_prompt', t)),
      subtitle: Text(
        SettingTexts.subtitle('set_scan_completion_prompt_desc', t),
      ),
      onTap: () => unawaited(scanStore.updateAutoClosePrompt(!live)),
      trailing: Switch(
        value: live,
        onChanged: (bool v) => unawaited(scanStore.updateAutoClosePrompt(v)),
      ),
    );
  }
}

class _BoundSliderTile extends HookWidget {
  const _BoundSliderTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleKey,
    required this.valueOf,
    required this.min,
    required this.max,
    required this.divisions,
    required this.format,
    required this.apply,
  });

  final IconData icon;
  final String titleKey;
  final String? subtitleKey;
  final double Function(AppState s) valueOf;
  final double min;
  final double max;
  final int divisions;
  final String Function(double v) format;
  final Future<void> Function(AppStore store, double v) apply;

  @override
  Widget build(BuildContext context) {
    final AppStore store = useAppStore();
    final AppLocalizations t = getLocalizations(context);
    final double live = valueOf(store.state).clamp(min, max).toDouble();
    final String? subtitle =
        subtitleKey == null ? null : SettingTexts.subtitle(subtitleKey!, t);

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          if (subtitle != null) Text(subtitle),
          Slider(
            value: live,
            min: min,
            max: max,
            divisions: divisions,
            label: format(live),
            onChanged: (double v) => unawaited(apply(store, v)),
          ),
        ],
      ),
      trailing: Text(format(live)),
    );
  }
}

class _BoundEditorTile extends HookWidget {
  const _BoundEditorTile({
    required this.icon,
    required this.titleKey,
    required this.subtitleBuilder,
    required this.onOpen,
  });

  final IconData icon;
  final String titleKey;
  final String Function(AppState state, AppLocalizations t)? subtitleBuilder;
  final void Function(BuildContext context) onOpen;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    // Select the RESOLVED subtitle string (value equality) instead of the
    // whole AppState, so an unrelated state change does not rebuild this tile.
    final String? subtitle =
        useAppStore().select(context, (s) => subtitleBuilder?.call(s, t));

    return ListTile(
      leading: Icon(icon),
      title: Text(SettingTexts.title(titleKey, t)),
      subtitle: subtitle == null ? null : Text(subtitle),
      onTap: () => onOpen(context),
    );
  }
}
