import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_kind.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/scenario_playback/view/list/playback_scenario_tile.dart';
import 'package:iris/features/scenario_playback/view/list/system_playing_tile.dart';
import 'package:iris/features/scenario_playback/view/list/use_playback_scenarios_selection.dart';

/// Scenario tab body: the pinned SystemPlaying tile first, then the saved
/// scenarios list. The SystemPlaying row never participates in multi-select.
class PlaybackScenariosListPage extends HookWidget {
  const PlaybackScenariosListPage({super.key});

  @override
  Widget build(BuildContext context) {
    final store = usePlaybackScenarioStore();
    final scenarios = store.select(context, (s) => s.scenarios);
    final isLoading = store.select(context, (s) => s.isLoading);

    if (isLoading && scenarios.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }

    final system = store.select(context, store.systemPlayingScenarioOf);
    // The unified workspace is an internal context, never a user-visible
    // "saved scenario" — only userSaved rows are listed.
    final saved =
        scenarios.where((s) => s.type == ScenarioKind.userSaved).toList();

    final selectionStore = usePlaybackScenariosSelectionStore();
    final selection = selectionStore.controller;
    final ids = saved.map((e) => e.id).toList();

    if (system == null && saved.isEmpty) {
      return const Center(child: Text('No scenarios yet.'));
    }

    return ListView(
      padding: const EdgeInsets.only(bottom: 100),
      children: [
        if (system != null) SystemPlayingTile(scenario: system),
        if (saved.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Saved Scenarios',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
            ),
          ),
          for (var i = 0; i < saved.length; i++)
            PlaybackScenarioTile(
              onLongPress: () => selection.longPressAt(saved[i].id, ids),
              scenario: saved[i],
              selection: selection,
              index: i + 2,
            ),
        ],
      ],
    );
  }
}
