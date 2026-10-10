import 'package:flutter/material.dart' hide Chip;
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/tag_play/model/domain/tag_play_tag.dart';
import 'package:iris/features/windows/explorer/menu/explorer_reveal_action.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/progress.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_history_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/file_size_convert.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:iris/widgets/chip.dart';
import 'package:scrollable_positioned_list/scrollable_positioned_list.dart';

/// Canonical membership key of a [FileItem], matching [TagPlayMember.mediaKey].
String tagMediaKeyOf(String storageId, List<String> pathSegments) =>
    '$storageId:${canonicalDbPath(pathSegments.join('/'))}';

class PlayQueue extends HookWidget {
  const PlayQueue({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final playQueue =
        usePlayQueueStore().select(context, (state) => state.playQueue);
    final currentIndex =
        usePlayQueueStore().select(context, (state) => state.currentIndex);
    final popupDirection =
        useAppStore().select(context, (state) => state.defaultPopupDirection);

    final int currentPlayIndex = useMemoized(
        () => playQueue.indexWhere((element) => element.index == currentIndex),
        [playQueue, currentIndex]);

    // Per-row tag labels: one bulk query for the whole visible queue.
    final tagFeature = useAppStore()
        .select(context, (s) => !s.useLegacyStoragePersistence && s.useMetadataSettings);
    final tagsFuture = useMemoized(() async {
      if (!tagFeature) return const <String, List<TagPlayTag>>{};
      final keys = <String>{
        for (final item in playQueue)
          if (item.file.storageId.isNotEmpty && item.file.path.isNotEmpty)
            tagMediaKeyOf(item.file.storageId, item.file.path),
      };
      if (keys.isEmpty) return const <String, List<TagPlayTag>>{};
      return DbModule.tagPlayRepo.tagsOfMediaKeys(keys);
    }, [playQueue, tagFeature]);
    final tagsByKey = useFuture(tagsFuture).data ??
        const <String, List<TagPlayTag>>{};
    final tagsLoaded = tagsByKey.isNotEmpty;

    final itemScrollController = useMemoized(() => ItemScrollController(), []);
    final scrollOffsetController =
        useMemoized(() => ScrollOffsetController(), []);
    final itemPositionsListener =
        useMemoized(() => ItemPositionsListener.create(), []);
    final scrollOffsetListener =
        useMemoized(() => ScrollOffsetListener.create(), []);

    useEffect(() {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (itemScrollController.isAttached && playQueue.isNotEmpty) {
          itemScrollController.jumpTo(
              index: currentPlayIndex - 3 < 0 ? 0 : currentPlayIndex - 1);
        }
      });
      return;
    }, []);

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
              itemCount: playQueue.length,
              itemBuilder: (context, index) => ListTile(
                autofocus: currentPlayIndex == index,
                tileColor: currentPlayIndex == index
                    ? Theme.of(context).hoverColor
                    : null,
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
                title: Row(
                  children: [
                    Expanded(
                      child: Text(
                        playQueue[index].file.name,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: currentPlayIndex == index
                            ? TextStyle(
                                fontWeight: FontWeight.bold,
                                color: Theme.of(context).colorScheme.primary,
                              )
                            : null,
                      ),
                    ),
                    if (tagFeature) ...[
                      const SizedBox(width: 8),
                      _tagIndicator(
                        context,
                        tags: tagsByKey[tagMediaKeyOf(
                              playQueue[index].file.storageId,
                              playQueue[index].file.path,
                            )] ??
                            const [],
                        loaded: tagsLoaded,
                        isCurrent: currentPlayIndex == index,
                      ),
                    ],
                  ],
                ),
                subtitle: Row(
                  children: [
                    if (playQueue[index].file.size > 0)
                      Text("${fileSizeConvert(playQueue[index].file.size)} MB",
                          style: TextStyle(
                              fontSize: 13,
                              color: currentPlayIndex == index
                                  ? Theme.of(context).colorScheme.primary
                                  : null)),
                    const Spacer(),
                    () {
                      final Progress? progress = useHistoryStore().findById(
                          // playQueue[index].file.getID());  // legacy: surface-dependent uri key
                          canonicalProgressKey(
                              playQueue[index].file.storageId,
                              playQueue[index].file.path,
                              uri: playQueue[index].file.uri)); // unified
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
                    ...playQueue[index]
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
                      case FileOptions.remove:
                        usePlayQueueStore().remove(playQueue[index]);
                        break;
                      case FileOptions.openInFolder:
                        await openInFolder(
                          context,
                          playQueue[index].file,
                          direction: popupDirection,
                        );
                        break;
                      case FileOptions.openInExplorer:
                        await revealFileInExplorer(
                          context,
                          playQueue[index].file,
                        );
                        break;
                      default:
                        break;
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                      value: FileOptions.remove,
                      child: Text(t.remove),
                    ),
                    if (playQueue[index].file.path.isNotEmpty)
                      PopupMenuItem(
                        value: FileOptions.openInFolder,
                        child: Text(t.open_in_folder),
                      ),
                    if (canRevealFileInExplorer(playQueue[index].file))
                      PopupMenuItem(
                        value: FileOptions.openInExplorer,
                        child: Text(t.open_in_explorer),
                      ),
                  ],
                ),
                onTap: () async {
                  await useAppStore().updateAutoPlay(true);
                  usePlayQueueStore()
                      .updateCurrentIndex(playQueue[index].index);
                  if (context.mounted) {
                    Navigator.of(context).pop();
                  }
                },
              ),
              itemScrollController: itemScrollController,
              scrollOffsetController: scrollOffsetController,
              itemPositionsListener: itemPositionsListener,
              scrollOffsetListener: scrollOffsetListener,
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
                t.play_queue,
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

  /// Compact per-row tag label: tag chips when membered, a muted no-tag
  /// marker once loaded with no memberships (disambiguated from a real tag
  /// via the subdued colour).
  Widget _tagIndicator(
    BuildContext context, {
    required List<TagPlayTag> tags,
    required bool loaded,
    required bool isCurrent,
  }) {
    if (!loaded) return const SizedBox.shrink();
    if (tags.isEmpty) {
      return Text(
        getLocalizations(context).tag_no_tag,
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.outline,
        ),
      );
    }
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final tag in tags) ...[
          Chip(text: tag.name, primary: isCurrent),
          const SizedBox(width: 4),
        ],
      ],
    );
  }
}
