import 'package:flutter/foundation.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/models/store/app_state.dart' show BrowseMediaScope;
import 'package:iris/models/storages/storage.dart';

part 'file.freezed.dart';
part 'file.g.dart';

enum ContentType {
  video,
  audio,
  image,
  other,
}

enum FileOptions {
  addToPlayQueue,
  remove,
  openInFolder,
  openInExplorer,
}

@freezed
abstract class FileItem with _$FileItem {
  const FileItem._();
  const factory FileItem({
    @Default('') String storageId,
    @Default(StorageType.none) StorageType storageType,
    required String name,
    required String uri,
    @Default([]) List<String> path,
    @Default(false) bool isDir,
    @Default(0) int size,
    /// Media duration in milliseconds when known (DB `media_nodes.duration_ms`
    /// or history). Null = not probed/indexed; callers must treat it as
    /// unknown (e.g. duration sort orders null as 0).
    int? durationMs,
    DateTime? lastModified,
    @Default(ContentType.video) ContentType type,
    @Default([]) List<Subtitle> subtitles,
  }) = _FileItem;

  factory FileItem.fromJson(Map<String, dynamic> json) => _$FileItemFromJson(json);

  String getID() => '$storageId:$uri';
}

@freezed
abstract class Subtitle with _$Subtitle {
  const factory Subtitle({
    required String name,
    required String uri,
  }) = _Subtitle;

  factory Subtitle.fromJson(Map<String, dynamic> json) => _$SubtitleFromJson(json);
}

@freezed
abstract class PlayQueueItem with _$PlayQueueItem {
  const factory PlayQueueItem({
    required FileItem file,
    required int index,
  }) = _PlayQueueItem;

  factory PlayQueueItem.fromJson(Map<String, dynamic> json) => _$PlayQueueItemFromJson(json);
}

extension FileItemMediaX on FileItem {
  bool get isPlayable => type == ContentType.video || type == ContentType.audio;

  bool get isVisible => isDir || isPlayable;

  /// Browse-scope projection for filesystem-first surfaces (the DB chain
  /// filters via SQL `mediaTypes` instead). Directories are scope-neutral —
  /// visibility of childless-after-filtering dirs is the caller's concern.
  bool matchesBrowseScope(BrowseMediaScope scope) {
    if (isDir) return true;
    return switch (scope) {
      BrowseMediaScope.all => true,
      BrowseMediaScope.videoOnly => type == ContentType.video,
      BrowseMediaScope.audioOnly => type == ContentType.audio,
    };
  }
}
