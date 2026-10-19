import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/media_library/services/media_uri.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/store/use_storage_store.dart';

/// Converts a scanned [MediaFile] into the playback-side [FileItem] the 副音
/// runtime consumes (storage type, playable uri incl. SAF document uris,
/// size, media type, mtime). Vanished/absent rows are the callers' concern —
/// the resolver drops them before conversion.
///
/// Mirrors the node→file conversion in `tag_voice_candidate_source.dart` and
/// `tag_play_controller._toEntry`; keep all three in sync.
FileItem backgroundFileItemFromMediaFile(
  MediaFile f, {
  Map<String, Storage?>? storages,
}) {
  final storage = storages == null
      ? useStorageStore().findById(f.storageId)
      : storages.putIfAbsent(
          f.storageId,
          () => useStorageStore().findById(f.storageId),
        );
  return FileItem(
    storageId: f.storageId,
    storageType: storage?.type ?? StorageType.none,
    name: f.name,
    // Remote rows derive their address from the storage record (current host),
    // local rows rebuild from the path — same contract as every other producer.
    uri: mediaNodePlayableUri(storage, f.path, uri: f.uri),
    path: f.path,
    size: f.sizeInBytes ?? 0,
    type: backgroundContentTypeOf(f.mediaType),
    lastModified: f.modifiedAt,
  );
}

/// Media type → content type for 副音 candidates (video/audio only play; the
/// resolver filters before calling this).
ContentType backgroundContentTypeOf(MediaType mt) => switch (mt) {
      MediaType.video => ContentType.video,
      MediaType.audio => ContentType.audio,
      MediaType.unknown => ContentType.other,
    };
