import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_lib_sort_by.dart';
import 'package:iris/features/media_library/view/tab/store/libs/use_media_libs_page_store.dart';
import 'package:iris/utils/get_localizations.dart';

class MediaLibSortMenu extends HookWidget {
  const MediaLibSortMenu({super.key});

  @override
  Widget build(BuildContext context) {
    final store = useMediaLibsStore();
    final t = getLocalizations(context);

    final sortBy = store.select(
      context,
      (s) => s.sortBy,
    );

    final sortDirection = store.select(
      context,
      (s) => s.sortDirection,
    );

    return PopupMenuButton<MediaLibsListSortBy>(
      icon: const Icon(Icons.sort_rounded),
      onSelected: (value) async {
        if (sortBy == value) {
          await store.updateSort(
            value,
            sortDirection == SortDirection.asc ? SortDirection.desc : SortDirection.asc,
          );
        } else {
          await store.updateSort(
            value,
            sortDirection,
          );
        }
      },
      itemBuilder: (_) => [
        _item(
          label: t.lib_sort_name,
          target: MediaLibsListSortBy.name,
          current: sortBy,
          order: sortDirection,
          context: context,
        ),
        _item(
          label: t.lib_sort_created,
          target: MediaLibsListSortBy.createdAt,
          current: sortBy,
          order: sortDirection,
          context: context,
        ),
        _item(
          label: t.lib_sort_updated,
          target: MediaLibsListSortBy.updatedAt,
          current: sortBy,
          order: sortDirection,
          context: context,
        ),
      ],
    );
  }

  PopupMenuItem<MediaLibsListSortBy> _item({
    required String label,
    required MediaLibsListSortBy target,
    required MediaLibsListSortBy current,
    required SortDirection order,
    required BuildContext context,
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
