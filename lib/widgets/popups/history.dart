import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/meta_settings/engine/browse_scope_snapshot.dart'
    show currentBrowseMediaScope;
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/progress.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_history_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/file_size_convert.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:iris/widgets/chip.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/storages/db/storages_db.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

class History extends HookWidget {
  const History({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final Map<String, Progress> history =
        useHistoryStore().select(context, (state) => state.history);

    final useLegacy = useAppStore()
        .select(context, (s) => s.useLegacyStoragePersistence);
    final popupDirection = useAppStore()
        .select(context, (s) => s.defaultPopupDirection);

    final List<MapEntry<String, Progress>> historyList = useMemoized(() {
      // Display-layer scope filter: out-of-scope entries stay persisted but
      // never surface here.
      final scope = currentBrowseMediaScope();
      final entries = history.entries
          .where((e) => e.value.file.matchesBrowseScope(scope))
          .toList();
      entries.sort((a, b) => b.value.dateTime.compareTo(a.value.dateTime));
      return entries.sublist(0, min(entries.length, 100));
    }, [history]);

    Future<void> play(int index) async {
      await useAppStore().updateAutoPlay(true);

      final playQueue = historyList
          .asMap()
          .map((index, entry) => MapEntry(
              index, PlayQueueItem(file: entry.value.file, index: index)))
          .values
          .toList();

      PlaybackProviderRegistry.beginExternalFeed();
      usePlayQueueStore().update(playQueue: playQueue, index: index);
    }

    return Column(
      children: [
        Expanded(
          child: Card(
            color: Colors.transparent,
            elevation: 0,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
            ),
            child: ScrollablePositionedList.builder(
              itemCount: historyList.length,
              itemBuilder: (context, index) => ListTile(
                contentPadding: const EdgeInsets.fromLTRB(12, 0, 8, 0),
                visualDensity:
                    const VisualDensity(horizontal: -4, vertical: -4),
                leading: Text(
                  (index + 1).toString(),
                  style: const TextStyle(
                    fontSize: 14,
                  ),
                  textAlign: TextAlign.center,
                ),
                minLeadingWidth: 14,
                title: Text(
                  historyList[index].value.file.name,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
                subtitle: Row(
                  children: [
                    if (historyList[index].value.file.size > 0)
                      Text(
                          "${fileSizeConvert(historyList[index].value.file.size)} MB"),
                    const Spacer(),
                    () {
                      final Progress? progress = useHistoryStore().findById(
                          // historyList[index].value.file.getID());  // legacy
                          canonicalProgressKey(
                              historyList[index].value.file.storageId,
                              historyList[index].value.file.path,
                              uri: historyList[index].value.file.uri)); // unified
                      if (progress != null &&
                          progress.file.type == ContentType.video) {
                        if ((progress.duration.inMilliseconds -
                                progress.position.inMilliseconds) <=
                            5000) {
                          return Chip(text: '100%');
                        }
                        final String progressString =
                            (progress.position.inMilliseconds /
                                    progress.duration.inMilliseconds *
                                    100)
                                .toStringAsFixed(0);
                        return Chip(text: '$progressString %');
                      } else {
                        return const SizedBox();
                      }
                    }(),
                    ...historyList[index]
                        .value
                        .file
                        .subtitles
                        .map((subtitle) =>
                            subtitle.uri.split('.').last.toUpperCase())
                        .toSet()
                        .toList()
                        .map(
                          (subtitleType) => Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const SizedBox(width: 4),
                              Chip(
                                text: subtitleType,
                                primary: true,
                              ),
                            ],
                          ),
                        ),
                  ],
                ),
                trailing: PopupMenuButton<FileOptions>(
                  // Windows drops the payload (AXTree graft race, see
                  // rowTooltip); other platforms keep "Show menu".
                  tooltip: rowTooltip(null),
                  clipBehavior: Clip.hardEdge,
                  constraints: const BoxConstraints(minWidth: 200),
                  onSelected: (value) async {
                    switch (value) {
                      case FileOptions.addToPlayQueue:
                        usePlayQueueStore()
                            .add([historyList[index].value.file]);
                        break;
                      case FileOptions.remove:
                        useHistoryStore().remove(historyList[index].value);
                        break;
                      case FileOptions.openInFolder:
                        if (useLegacy) {
                          await openInFolder(
                            context,
                            historyList[index].value.file,
                            direction: popupDirection,
                          );
                        } else {
                          await _openInFolderDb(context,
                              historyList[index].value.file, popupDirection);
                        }
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: FileOptions.addToPlayQueue,
                      child: Text(t.add_to_play_queue),
                    ),
                    PopupMenuItem(
                      value: FileOptions.remove,
                      child: Text(t.remove),
                    ),
                    if (historyList[index].value.file.path.isNotEmpty)
                      PopupMenuItem(
                        value: FileOptions.openInFolder,
                        child: Text(t.open_in_folder),
                      ),
                  ],
                ),
                onTap: () {
                  play(index);
                  Navigator.of(context).pop();
                },
              ),
            ),
          ),
        ),
        Divider(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.25),
          height: 0,
        ),
        Container(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(
            children: [
              Text(
                t.history,
                style: const TextStyle(fontWeight: FontWeight.w500),
              ),
              const Spacer(),
              IconButton(
                tooltip: '${t.close} ( Escape )',
                icon: const Icon(Icons.close_rounded),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Future<void> _openInFolderDb(
      BuildContext context, FileItem file, PopupDirection popupDirection) async {
    if (file.path.isEmpty) return;
    useStorageStore()
        .updateCurrentPath(file.path.sublist(0, file.path.length - 1));

    Storage? storage = useStorageStore().findById(file.storageId);

    if (storage != null) {
      useStorageStore().updateCurrentStorage(storage);
    } else {
      final localStorages = await getLocalStorages(context);
      storage = localStorages.firstWhereOrNull(
          (element) => element.basePath[0] == file.path[0]);
      if (storage != null) {
        useStorageStore().updateCurrentStorage(storage);
      } else {
        useStorageStore().updateCurrentStorage(
          LocalStorage(
            type: file.storageType,
            name: file.path[0],
            basePath: [file.path[0]],
          ),
        );
      }
    }

    if (context.mounted) {
      replacePopup(
        context: context,
        child: const StoragesDb(),
        direction: popupDirection,
      );
    }
  }
}
