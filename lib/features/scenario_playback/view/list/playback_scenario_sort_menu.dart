import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_list_sort_by.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/utils/get_localizations.dart';

class PlaybackScenarioSortMenu extends HookWidget {
  const PlaybackScenarioSortMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final store = usePlaybackScenarioStore();
    final t = getLocalizations(context);

    final sortBy = store.select(context, (s) => s.scenarioSortBy);
    final sortDirection = store.select(context, (s) => s.scenarioSortDirection);

    return PopupMenuButton<ScenarioListSortBy>(
      icon: const Icon(Icons.sort_rounded),
      onSelected: (value) async {
        if (sortBy == value) {
          await store.updateScenarioSort(
            value,
            sortDirection == SortDirection.asc ? SortDirection.desc : SortDirection.asc,
          );
        } else {
          await store.updateScenarioSort(
            value,
            sortDirection,
          );
        }
      },
      itemBuilder: (_) => [
        _item(
          label: t.scn_sort_name,
          target: ScenarioListSortBy.name,
          current: sortBy,
          order: sortDirection,
        ),
        _item(
          label: t.scn_sort_created,
          target: ScenarioListSortBy.createdAt,
          current: sortBy,
          order: sortDirection,
        ),
        _item(
          label: t.scn_sort_updated,
          target: ScenarioListSortBy.updatedAt,
          current: sortBy,
          order: sortDirection,
        ),
      ],
    );
  }

  PopupMenuItem<ScenarioListSortBy> _item({
    required String label,
    required ScenarioListSortBy target,
    required ScenarioListSortBy current,
    required SortDirection order,
  }) {
    return PopupMenuItem(
      value: target,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          if (current == target)
            Icon(
              order == SortDirection.asc ? Icons.arrow_upward : Icons.arrow_downward,
            ),
        ],
      ),
    );
  }
}
