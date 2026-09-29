import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/player_control_target_scope.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/windows/desktop_keyboard/view/shortcut_hints.dart';
import 'package:iris/pages/player/control_bar/control_bar_widgets/control_bar_constants.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/a11y_tooltip.dart';

/// Whether the scenario-driven playback mode is active.
bool _useScenarioMode(BuildContext context) {
  final app = useAppStore();
  return app.select(context, (s) => !s.useLegacyStoragePersistence && s.useScenarioDrivenPlayback);
}

/// Resolves the effective queue size for visibility, using the scenario
/// provider's total in scenario mode (the synthetic store holds only 1 item).
///
/// The scenario total is re-resolved whenever the active scenario's playback
/// revision changes — otherwise the memoized future would keep the initial
/// (empty) value and the prev/next buttons would never appear.
int _effectiveTotal(BuildContext context) {
  final store = usePlayQueueStore();
  final length = store.select(context, (s) => s.playQueue.length);
  // Evaluated unconditionally (hook order must stay stable across a
  // legacy<->query backend switch), but only USED in query mode.
  final queryTotal = useValueListenable(store.totalCountNotifier);
  final useScenario = _useScenarioMode(context);
  final bg = useBackgroundPlaybackStore();
  // While the controls target 副音 the transport belongs to the bg LIST (a
  // plain single-file queue, never virtual-merged): visibility and stepping
  // follow it instead of the foreground scenario.
  final bgIsControl = bg.select(context, (s) => s.bgOwnsControls);
  final bgLength = bg.select(context, (s) => s.queue.length);

  // Always evaluate the foreground scenario total — hook order must stay
  // stable across a control-target flip; it is only USED for the fg target.
  final scenarioStore = usePlaybackScenarioStore();
  final activeId = scenarioStore.select(context, (s) => s.activeScenarioId);
  final version = scenarioStore.select(context, (s) => s.playbackVersion);
  final total = useFuture(
    useMemoized(
      () => (!useScenario || activeId == null)
          ? Future<int>.value(0)
          : PlaybackProviderRegistry.active().totalCount(),
      [version, activeId, useScenario],
    ),
  );

  if (bgIsControl) return bgLength;
  if (useScenario) return total.data ?? 0;
  // Query mode's real total is NOT `playQueue.length` (the synthetic state is
  // pinned to one item), and a bare `store.totalCount` read is not a
  // subscription — subscribe to the store's published mirror instead.
  return store.isQueryMode ? queryTotal : length;
}

class PrevButton extends HookWidget {
  const PrevButton({super.key, required this.showControl, this.color, this.overlayColor});

  final void Function() showControl;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = useEffectiveKeyboardScheme(context);

    if (_effectiveTotal(context) <= 1) return const SizedBox.shrink();

    return a11yTooltipIconButton(
      context: context,
      tooltip:
          '${t.previous} ( ${shortcutHintLabelFor(ShortcutHintKind.previous, scheme)} )',
      icon: Icon(Icons.skip_previous_rounded, size: kIconSizePrimary, color: color),
      onPressed: () {
        showControl();
        if (isBackgroundControlTarget(context)) {
          useBackgroundPlaybackStore().step(forward: false);
        } else {
          PlaybackProviderRegistry.step(forward: false);
        }
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );
  }
}

class NextButton extends HookWidget {
  const NextButton({super.key, required this.showControl, this.color, this.overlayColor});

  final void Function() showControl;
  final Color? color;
  final WidgetStateProperty<Color?>? overlayColor;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = useEffectiveKeyboardScheme(context);

    if (_effectiveTotal(context) <= 1) return const SizedBox.shrink();

    return a11yTooltipIconButton(
      context: context,
      tooltip:
          '${t.next} ( ${shortcutHintLabelFor(ShortcutHintKind.next, scheme)} )',
      icon: Icon(Icons.skip_next_rounded, size: kIconSizePrimary, color: color),
      onPressed: () {
        showControl();
        if (isBackgroundControlTarget(context)) {
          useBackgroundPlaybackStore().step(forward: true);
        } else {
          PlaybackProviderRegistry.step(forward: true);
        }
      },
      style: ButtonStyle(overlayColor: overlayColor),
    );
  }
}
