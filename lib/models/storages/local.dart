import 'dart:io';

import 'package:android_x_storage/android_x_storage.dart';
import 'package:disks_desktop/disks_desktop.dart';
import 'package:drives_windows/drives_windows.dart';
import 'package:file_picker/file_picker.dart';
import 'package:iris/features/windows/desktop_keyboard/controller/ab_loop_engine.dart';
import 'package:iris/features/windows/desktop_keyboard/store/key_sequence_buffer_store.dart';
import 'package:flutter/material.dart';
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/models/storages/volume_identity.dart';
import 'package:iris/models/store/play_queue_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_play_queue_store.dart';
import 'package:iris/utils/check_content_type.dart';
import 'package:iris/utils/files_sort.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/get_subtitle_map.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/popups/storages/db/storages_utils/storage_utils.dart';
import 'package:path/path.dart' as p;
import 'package:saf_util/saf_util.dart';
import 'package:saf_util/saf_util_platform_interface.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

Future<List<LocalStorage>> getLocalStorages(
  BuildContext context,
) async {
  final t = getLocalizations(context);
  if (isDesktop) {
    List<LocalStorage> storages = [];

    if (isWindows) {
      final drivesWindows = DrivesWindows();
      final drives = drivesWindows.getDrives();
      final networkShortcuts = drivesWindows.getNetworkShortcuts();

      for (var drive in drives) {
        if (drive.type == DriveType.noRootDirectory) continue;

        final type = drive.type == DriveType.network ? StorageType.network : StorageType.internal;
        final name = drive.volumeLabel != null
            ? '${drive.volumeLabel} (${drive.name})'
            : '${drive.type == DriveType.network ? t.network_storage : t.local_storage} (${drive.name})';
        final root = drive.root.replaceAll('\\', '');

        // final storage = LocalStorage(
        //   type: type,
        //   name: name,
        //   basePath: [root],
        // );
        final storage = makeLocalStorage(
          type: type,
          name: name,
          basePath: [root],
          volumeId: await VolumeIdentity.of(root),
        );

        storages.add(storage);
      }

      for (var shortcut in networkShortcuts) {
        if (shortcut.path == null) continue;
        final storage = makeLocalStorage(
          type: StorageType.network,
          name: shortcut.name,
          basePath: [shortcut.path!],
        );

        storages.add(storage);
      }
    } else {
      final repository = DisksRepository();
      final disks = await repository.query;
      List<LocalStorage> storages = [];

      for (var disk in disks) {
        for (var mountpoint in disk.mountpoints) {
          final mountPath = mountpoint.path.replaceAll('\\', '');
          final storage = makeLocalStorage(
            type: StorageType.internal,
            name: '${t.local_storage} ($mountPath)',
            basePath: [mountPath],
            volumeId: await VolumeIdentity.of(mountPath),
          );

          storages.add(storage);
        }
      }
    }

    return storages;
  } else if (isAndroid) {
    final androidXStorage = AndroidXStorage();
    final external = await androidXStorage.getExternalStorageDirectory().catchError((error) {
      areaKeyLog.e('Error getting external storage: $error');
      return null;
    });

    final sdcard = await androidXStorage.getSDCardStorageDirectory().catchError((error) {
      areaKeyLog.e('Error getting SD card: $error');
      return null;
    });
    final usbs = await androidXStorage.getUSBStorageDirectories().catchError((error) {
      areaKeyLog.e('Error getting USB storages: $error');
      return <String?>[];
    });

    List<LocalStorage> storages = [];

    if (external != null) {
      final storage = makeLocalStorage(
        type: StorageType.internal,
        name: t.local_storage,
        basePath: [external],
        volumeId: await VolumeIdentity.of(external),
      );

      storages.add(storage);
    }

    if (sdcard != null && await Directory(sdcard).exists()) {
      final storage = makeLocalStorage(
        type: StorageType.sdcard,
        name: 'SD Card',
        basePath: [sdcard],
        volumeId: await VolumeIdentity.of(sdcard),
      );

      storages.add(storage);
    }

    for (var usb in usbs) {
      if (usb != null && await Directory(usb).exists()) {
        final storage = makeLocalStorage(
          type: StorageType.usb,
          name: t.usb_storage,
          basePath: [usb],
          volumeId: await VolumeIdentity.of(usb),
        );

        storages.add(storage);
      }
    }

    if (storages.isEmpty) {
      // Fallback: always include internal storage
      final fallbackRoot =
          await androidXStorage.getExternalStorageDirectory() ??
              '/storage/emulated/0';
      storages.add(makeLocalStorage(
        type: StorageType.internal,
        name: t.local_storage,
        basePath: [fallbackRoot],
        volumeId: await VolumeIdentity.of(fallbackRoot),
      ));
    }

    return storages;
  }
  return [];
}

Future<PlayQueueState?> getLocalPlayQueue(String filePath) async {
  final type = checkContentType(filePath);

  if (type != ContentType.video && type != ContentType.audio) {
    return null;
  }

  final convedPath = pathConv(filePath);
  if (convedPath.isEmpty) return null;

  final dirPath = convedPath.length > 1
      ? convedPath.sublist(0, convedPath.length - 1)
      : <String>[];
  final files = await LocalStorage(
    type: StorageType.internal,
    name: convedPath.last,
    basePath: dirPath,
  ).getFiles(dirPath);
  final List<FileItem> sortedFiles = filesSort(files: files);
  final List<FileItem> filteredFiles = sortedFiles
      .where((file) => [ContentType.video, ContentType.audio].contains(file.type))
      .toList();

  final List<PlayQueueItem> playQueue = filteredFiles
      .asMap()
      .entries
      .map((entry) => PlayQueueItem(file: entry.value, index: entry.key))
      .toList();

  final clickedFile = filteredFiles.where((file) => file.uri == filePath).first;

  final index = filteredFiles.indexOf(clickedFile);
  return PlayQueueState(
    playQueue: playQueue,
    currentIndex: index < 0 || index >= playQueue.length ? 0 : index,
  );
}

Future<void> pickLocalFile() async {
  AbLoopEngine.instance.reset();
  useKeySequenceBufferStore().close();
  FilePickerResult? result = await FilePicker.platform.pickFiles(
    type: FileType.custom,
    allowedExtensions: [...Formats.video, ...Formats.audio],
  );

  final filePath = result?.files.first.path;

  if (filePath != null) {
    final playQueue = await getLocalPlayQueue(filePath);

    if (playQueue == null || playQueue.playQueue.isEmpty) return;

    await useAppStore().updateAutoPlay(true);
    PlaybackProviderRegistry.beginExternalFeed();
    await usePlayQueueStore().update(
      playQueue: playQueue.playQueue,
      index: playQueue.currentIndex,
    );
  }
}

Future<List<FileItem>> getLocalFiles(LocalStorage storage, List<String> path) async {
  if (path.any((s) => s == '..' || s == '.')) {
    areaKeyLog.w('getLocalFiles rejected traversal path: $path');
    return [];
  }
  final directoryPath = p.joinAll(path);
  final directory = Directory(directoryPath);

  bool exists = false;
  try {
    exists = await directory.exists();
  } catch (e) {
    areaKeyLog.w('getLocalFiles exists check failed for $directoryPath: $e');
    return [];
  }
  if (!exists) {
    areaKeyLog.e('Error: Directory does not exist at $directoryPath');
    return [];
  }

  final Map<String, List<FileSystemEntity>> groupedEntities = {};
  int listCount = 0;
  try {
    // Stream to avoid OOM on huge dirs (50w). Yields every 200 entries keep UI alive.
    await for (final entity in directory.list()) {
      final baseName = p.basenameWithoutExtension(entity.path);
      groupedEntities.putIfAbsent(baseName, () => []).add(entity);
      if (++listCount % 200 == 0) await Future<void>.delayed(Duration.zero);
    }
  } catch (e) {
    areaKeyLog.w('getLocalFiles list failed for $directoryPath: $e');
    return [];
  }

  final List<FileItem> fileItems = [];
  final subtitleExtensions = {'ass', 'srt', 'vtt', 'sub'};
  int statCount = 0;

  for (final group in groupedEntities.values) {
    final videos = group
        .where((e) => e is! Directory && checkContentType(e.path) == ContentType.video)
        .toList();
    final subtitles = group.where((e) {
      final ext = p.extension(e.path).replaceFirst('.', '');
      return e is! Directory && subtitleExtensions.contains(ext);
    }).toList();
    final others = group.where((e) => !videos.contains(e) && !subtitles.contains(e)).toList();

    for (final video in videos) {
      final videoStat = await video.stat();
      if (++statCount % 100 == 0) await Future<void>.delayed(Duration.zero);
      final associatedSubtitles = subtitles.map((sub) {
        final baseName = p.basenameWithoutExtension(video.path);
        String subTitleName = p.basename(sub.path);
        final regex = RegExp(r'^' + RegExp.escape(baseName) + r'\.(.+?)\.');
        final match = regex.firstMatch(subTitleName);
        if (match != null) {
          subTitleName = match.group(1) ?? subTitleName;
        }
        return Subtitle(name: subTitleName, uri: sub.path);
      }).toList();

      fileItems.add(FileItem(
        storageId: storage.id,
        storageType: storage.type,
        name: p.basename(video.path),
        uri: video.path,
        path: [...path, p.basename(video.path)],
        isDir: false,
        size: videoStat.size,
        lastModified: videoStat.modified,
        type: ContentType.video,
        subtitles: associatedSubtitles,
      ));
    }

    for (final entity in others) {
      final stat = await entity.stat();
      if (++statCount % 100 == 0) await Future<void>.delayed(Duration.zero);
      final isDir = entity is Directory;
      fileItems.add(FileItem(
        storageId: storage.id,
        storageType: storage.type,
        name: p.basename(entity.path),
        uri: entity.path,
        path: [...path, p.basename(entity.path)],
        isDir: isDir,
        size: isDir ? 0 : stat.size,
        lastModified: stat.modified,
        type: isDir ? ContentType.other : checkContentType(entity.path),
        subtitles: [],
      ));
    }
  }

  return fileItems;
}

Future<void> pickContentFile() async {
  SafDocumentFile? file;
  try {
    file = await SafUtil().pickFile(mimeTypes: ['video/*', 'audio/*']);
  } catch (e) {
    areaKeyLog.w('pickContentFile failed: $e');
    return;
  }
  if (file != null) {
    await useAppStore().updateAutoPlay(true);
    PlaybackProviderRegistry.beginExternalFeed();
    await usePlayQueueStore().update(
      playQueue: [
        PlayQueueItem(
          file: FileItem(
            name: file.name,
            uri: file.uri,
            size: file.length,
          ),
          index: 0,
        ),
      ],
      index: 0,
    );
  }
}

/// Lists one SAF container directory (resolved to its document URI by the
/// storage layer) into FileItems.
///
/// [containerUri] is the document URI of the directory to list (the tree URI
/// at the storage root, or a `SafUtil().child`-resolved subdirectory).
/// [prefixSegments] is the caller's full storage-relative segment list
/// (`[treeUri, rel1, ...]`) whose children we are listing; each child's
/// `path` extends it with the child name so downstream DB rows and lookups
/// stay prefix-correct and reversible.
Future<List<FileItem>> getContentFiles(
  String containerUri,
  List<String> prefixSegments,
) async {
  List<SafDocumentFile> files;
  try {
    files = await SafUtil().list(containerUri);
  } catch (e) {
    areaKeyLog.w('getContentFiles failed for $containerUri: $e');
    return [];
  }

  final subtitleMap = getSubtitleMap<SafDocumentFile>(
    files: files,
    getName: (file) => file.name,
    getUri: (file) => file.uri,
  );

  List<FileItem> fileItems = [];

  for (final file in files) {
    final basename = p.basenameWithoutExtension(file.name).split('.').first;
    fileItems.add(FileItem(
      name: file.name,
      uri: file.uri,
      path: [...prefixSegments, file.name],
      isDir: file.isDir,
      size: file.isDir ? 0 : file.length,
      lastModified: DateTime.fromMillisecondsSinceEpoch(file.lastModified),
      type: file.isDir ? ContentType.other : checkContentType(file.name),
      subtitles: isVideoFile(file.name) ? subtitleMap[basename] ?? [] : [],
    ));
  }

  return fileItems;
}
