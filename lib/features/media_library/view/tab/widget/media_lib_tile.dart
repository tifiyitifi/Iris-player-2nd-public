import 'package:flutter/material.dart';
import 'package:iris/widgets/a11y_tooltip.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/media_library/model/db/adapters/media_library.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart'
    show SortDirection;
import 'package:iris/features/media_library/model/enum/media_lib_sources.dart'
    show MediaSourceKind;
import 'package:iris/features/media_library/model/enum/media_lib_sort_by.dart';
import 'package:iris/features/media_library/model/media_lib/media_library.dart';
import 'package:iris/features/media_library/model/media_lib/media_library_source.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/selection/selection_controller.dart';
import 'package:iris/features/media_library/services/add_sources_to_library.dart';
import 'package:iris/features/media_library/services/show_add_to_library_dialog.dart';
import 'package:iris/features/media_library/services/system_library_open_check.dart';
import 'package:iris/features/media_library/store/use_media_lib_browser_store.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/features/media_library/view/tab/dialogs/media_libs_tile_trailing_dialog.dart';
import 'package:iris/features/media_library/view/tab/store/libs/use_media_libs_page_store.dart';
import 'package:iris/features/scenario_playback/actions/scenario_playback_actions.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_source_kind.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_sort_field.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart' show StorageType;
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';
import 'package:iris/utils/get_localizations.dart';

class MediaLibTile extends HookWidget {
  const MediaLibTile({
    super.key,
    required this.onLongPress,
    required this.library,
    required this.selection,
    this.onTileTap,
  });
  final VoidCallback onLongPress;
  final MediaLibrary library;
  final SelectionController<String> selection;
  final void Function(String libraryId)? onTileTap;

  @override
  Widget build(BuildContext context) {
    // Hooks pattern: clean access to state
    final t = getLocalizations(context);
    final store = useMediaLibsStore();
    final sortBy = store.select(context, (s) => s.sortBy);

    // F-002 (D2/D32): whole-library Play + more is gated on the scenario mode;
    // legacy mode keeps the pre-existing trailing untouched.
    final scenarioMode = useAppStore().select(context,
        (s) => !s.useLegacyStoragePersistence && s.useScenarioDrivenPlayback);

    // Offline-grey: whole-library play queues live files for EVERY source,
    // so one disconnected storage disables the play entries (standard
    // disabled, no reaction). Rename / delete / add-as-source are pure
    // local-DB ops and stay enabled; tapping the tile still browses the
    // greyed snapshot.
    final connStatus = useStorageStore().select(
      context,
      (s) => s.storageConnectionStatus,
    );
    final sourcesSnapshot = useFuture(
      useMemoized(
        () => DbModule.sourcesRepository.getSources(library.id),
        [library.id],
      ),
    );
    final libOffline = sourcesSnapshot.data?.any(
          (src) => connStatus[src.storageId] == false,
        ) ??
        false;

    // We keep ListenableBuilder for the specific selection logic
    // to avoid unnecessary rebuilds of the whole tile when other
    // selections change.
    return ListenableBuilder(
      listenable: selection,
      builder: (_, __) {
        final selected = selection.isSelected(library.id);
        // System libraries cannot be selected, edited, or deleted.
        final isSystem = library.isSystem;
        final isSelecting = !isSystem && selection.isSelecting;
        // Conditionally render the popup menu
        Widget? trailingMenu;
        if (!isSelecting) {
          if (scenarioMode) {
            // F-002 (v3-D5): Play + more for EVERY lib (incl. system libs).
            trailingMenu = Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  icon: const Icon(Icons.play_arrow_rounded),
                  // Windows drops the payload (AXTree graft race, see
                  // rowTooltip); other platforms keep the label.
                  tooltip: rowTooltip(t.scn_play_override),
                  visualDensity: VisualDensity.compact,
                  padding: EdgeInsets.zero,
                  onPressed:
                      libOffline ? null : () => _playWholeLibrary(context),
                ),
                PopupMenuButton<String>(
                  tooltip: rowTooltip(null),
                  onSelected: (action) async {
                    if (action == 'playAppend') {
                      await _appendWholeLibrary(context);
                    } else if (action == 'rename') {
                      final newName = await showRenameLibraryDialog(
                        context,
                        library.name,
                      );
                      if (newName != null &&
                          newName.isNotEmpty &&
                          newName != library.name) {
                        await store.renameLibrary(library.id, newName);
                      }
                    } else if (action == 'delete') {
                      final confirm = await showDeleteLibraryDialog(context);
                      if (confirm) {
                        await store.deleteLibrary(library.id);
                      }
                    } else if (action == 'add_as_source') {
                      await _handleAddAsSource(context);
                    }
                  },
                  itemBuilder: (context) => [
                    PopupMenuItem(
                        value: 'playAppend',
                        enabled: !libOffline,
                        child: Text(t.lib_play_append)),
                    if (!isSystem) ...[
                      PopupMenuItem(
                          value: 'rename', child: Text(t.lib_rename)),
                      PopupMenuItem(
                          value: 'add_as_source',
                          child: Text(t.lib_add_as_source)),
                      PopupMenuItem(
                          value: 'delete', child: Text(t.scn_delete)),
                    ],
                  ],
                ),
              ],
            );
          } else if (!isSystem) {
            trailingMenu = PopupMenuButton<String>(
              tooltip: rowTooltip(null),
              onSelected: (action) async {
                final store = useMediaLibsStore();

                if (action == 'rename') {
                  final newName = await showRenameLibraryDialog(
                    context,
                    library.name,
                  );

                  if (newName != null &&
                      newName.isNotEmpty &&
                      newName != library.name) {
                    await store.renameLibrary(
                      library.id,
                      newName,
                    );
                  }
                } else if (action == 'delete') {
                  final confirm = await showDeleteLibraryDialog(context);
                  if (confirm) {
                    await store.deleteLibrary(library.id);
                  }
                } else if (action == 'add_as_source') {
                  await _handleAddAsSource(context);
                }
              },
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Text(t.lib_rename),
                ),
                PopupMenuItem(
                  value: 'add_as_source',
                  child: Text(t.lib_add_as_source),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Text(t.scn_delete),
                ),
              ],
            );
          }
        }
// Reactive subtitle logic
        final subtitle = _getSubtitle(sortBy, library, t);

        return ListTile(
          selected: selected,
          leading: isSelecting
              ? Checkbox(
                  value: selected,
                  onChanged: (_) => selection.toggle(library.id),
                )
              : const Icon(Icons.video_library),
          title: Text(
            library.name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          subtitle: subtitle != null ? Text(subtitle) : null,
          trailing: trailingMenu,
          onTap: () async {
            if (isSelecting) {
              selection.toggle(library.id);
            } else {
              onTileTap?.call(library.id);
              // Awaited so single-source system libs finish auto-entering
              // before the content page opens (no sources-page flash).
              await useMediaLibContentStore().setLibrary(library.id);
              useMediaLibBrowserStore().openLibContent();
            }
          },
          onLongPress: onLongPress,
        );
      },
    );
  }

  // Extracted logic keeps the build method "Deep" and readable
  String? _getSubtitle(
      MediaLibsListSortBy sortBy, MediaLibrary lib, AppLocalizations t) {
    // System libs: show the storage address (basePath) for per-storage libs,
    // "Detached" for the detached lib — regardless of the current sort field (D7).
    if (lib.isSystem) {
      if (lib.id == SystemLibraryOpenCheckService.detachedLibId) {
        return t.lib_detached;
      }
      final storageId = _storageIdFromSystemLib(lib.id);
      final storage =
          storageId == null ? null : useStorageStore().findById(storageId);
      final address = storage?.basePath.join('/');
      return (address == null || address.isEmpty) ? null : address;
    }

    switch (sortBy) {
      case MediaLibsListSortBy.createdAt:
        return t.lib_created_prefix(_formatDate(lib.createdAt));
      case MediaLibsListSortBy.updatedAt:
        return t.lib_updated_prefix(_formatDate(lib.updatedAt));
      default:
        return null;
    }
  }

  static String? _storageIdFromSystemLib(String libId) {
    const prefix = 'sys_';
    if (!libId.startsWith(prefix)) return null;
    final sid = libId.substring(prefix.length);
    return sid.isEmpty ? null : sid;
  }

  // Helper to format date
  String _formatDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}'
        '-${date.day.toString().padLeft(2, '0')}'
        '-${date.hour.toString().padLeft(2, '0')}'
        ':${date.minute.toString().padLeft(2, '0')}'
        ':${date.second.toString().padLeft(2, '0')}';
  }

  Future<void> _handleAddAsSource(BuildContext context) async {
    final navigator = Navigator.of(context, rootNavigator: true);
    final existingSources =
        await DbModule.sourcesRepository.getSources(library.id);
    // The tile may have been disposed while the DB read was in flight.
    if (!context.mounted) return;
    final t = getLocalizations(context);

    if (existingSources.isEmpty) {
      await showMessageDialog(
        navigator,
        message: t.lib_no_sources_to_copy,
        type: MessageDialogType.error,
      );
      return;
    }

    final targetId = await showAddToLibraryDialog(
      context,
      excludeIds: [library.id],
    );
    if (targetId == null) return;

    final added = await addSourcesToLibrary(
      targetLibraryId: targetId,
      sources: existingSources,
    );

    await showMessageDialog(
      navigator,
      message: t.lib_added_sources(added),
      type: MessageDialogType.success,
    );
  }

  // ── F-002: whole-library play / append ──

  /// Groups the library sources into scenario play inputs (v3-D2):
  /// dir-kind source → recursive [ScenarioSourceSpec] (path joined with `/`,
  /// empty/root → '', v6-D39); file-kind source → [FileItem] explicit —
  /// restored from `media_nodes` when present (D22), otherwise a greyed
  /// placeholder FileItem (D27). `kind == null` falls back to path inference
  /// (D18).
  Future<(List<FileItem>, List<ScenarioSourceSpec>)> _gatherLibraryScope() async {
    final sources = await DbModule.sourcesRepository.getSources(library.id);
    final files = <FileItem>[];
    final dirs = <ScenarioSourceSpec>[];
    for (final source in sources) {
      final segments = _segmentsOf(source.path);
      final kind = source.kind ??
          (segments.isEmpty
              ? MediaSourceKind.storage
              : MediaSourceKind.directory);
      if (kind == MediaSourceKind.file) {
        files.add(await _fileItemFromSource(source, segments));
      } else {
        dirs.add((
          storageId: source.storageId,
          path: segments.join('/'),
          recursive: true,
          kind: ScenarioSourceKind.folder,
        ));
      }
    }
    return (files, dirs);
  }

  static List<String> _segmentsOf(List<String>? path) =>
      (path ?? const []).where((s) => s.isNotEmpty).toList();

  Future<FileItem> _fileItemFromSource(
      MediaLibrarySource source, List<String> segments) async {
    final node = await DbModule.mediaNodeRepo.getNodeByPath(
      storageId: source.storageId,
      path: segments,
    );
    final file = node?.maybeMap(file: (f) => f, orElse: () => null);
    if (file != null) {
      final storage = useStorageStore().resolveStorageForNodeId(file.storageId);
      return FileItem(
        storageId: file.storageId,
        storageType: storage?.type ?? StorageType.none,
        name: file.name,
        uri: mediaNodePlayableUri(storage, file.path, uri: file.uri),
        path: file.path,
        size: file.sizeInBytes ?? 0,
        durationMs: file.durationMs,
        type: file.mediaType == MediaType.video
            ? ContentType.video
            : file.mediaType == MediaType.audio
                ? ContentType.audio
                : ContentType.other,
        // Subtitle associations persisted at scan time (schema v50).
        subtitles: file.subtitles ?? const [],
      );
    }
    // D27: missing file-kind source → placeholder explicit (greyed, un-tappable).
    final name = segments.isNotEmpty
        ? segments.last
        : (source.name?.isNotEmpty ?? false ? source.name! : 'unknown');
    return FileItem(
      storageId: source.storageId,
      storageType: StorageType.none,
      name: name,
      uri: playableUri(segments),
      path: segments,
      size: 0,
      type: ContentType.other,
    );
  }

  Future<void> _playWholeLibrary(BuildContext context) async {
    final (files, dirs) = await _gatherLibraryScope();
    if (!context.mounted) return;
    final result =
        await ScenarioPlaybackActions.runPlayActionWithNoMediaConfirm(
      context,
      action: ({bool force = false}) =>
          ScenarioPlaybackActions.playSelectionInDefaultScenario(
        files: files,
        directories: dirs,
        sortField: ScenarioSortField.name,
        sortDirection: SortDirection.asc,
        force: force,
        gateContext: context,
      ),
    );
    // v5-D33/v6-D34: success closes the popup unless pinned; a forced
    // No-Media install keeps it open.
    if (result == NoMediaActionResult.success &&
        context.mounted &&
        !usePlaybackScenarioStore().storagesDbStayOnPlay &&
        Navigator.of(context).canPop()) {
      Navigator.pop(context);
    }
  }

  Future<void> _appendWholeLibrary(BuildContext context) async {
    final (files, dirs) = await _gatherLibraryScope();
    if (!context.mounted) return;
    await ScenarioPlaybackActions.appendToDefaultScenarioWithFeedback(
      context,
      files,
      directories: dirs,
    );
  }
}
