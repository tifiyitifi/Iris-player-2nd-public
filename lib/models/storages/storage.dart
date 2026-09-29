import 'package:collection/collection.dart';
import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/ftp.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/webdav.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/popup.dart';
import 'package:iris/widgets/popups/storages/storages.dart';
import 'package:saf_util/saf_util.dart';

part 'storage.freezed.dart';
part 'storage.g.dart';

const String localStorageId = 'local';

enum StorageType {
  none,
  internal,
  network,
  usb,
  sdcard,
  webdav,
  ftp,
}

enum StorageOptions {
  edit,
  remove,
}

abstract class _Storage {
  String get id;
  StorageType get type;
  String get name;
  List<String> get basePath;

  /// Canonical data scope shared with other entries that resolve to the same
  /// account + path tree. NULL means "independent" (the entry's own [id]).
  String? get dataScopeId;

  Map<String, dynamic> toJson();

  Future<List<FileItem>> getFiles(List<String> path);

  /// Like [getFiles], but reports WHY a listing failed instead of returning an
  /// empty list. Non-WebDAV storages keep throwing as before; only WebDAV
  /// classifies failures (its exceptions were previously swallowed).
  Future<FileListResult> getFilesDetailed(List<String> path);

  String? getAuth();
}

@freezed
sealed class Storage with _$Storage implements _Storage {
  const Storage._();

  factory Storage.local({
    @Default(localStorageId) String id,
    required StorageType type,
    required String name,
    required List<String> basePath,
    String? dataScopeId,

    /// Stable volume identity (Windows volume GUID / Android volume UUID).
    /// NULL when unknown; see `VolumeIdentity`.
    String? volumeId,
  }) = LocalStorage;

  factory Storage.webdav({
    required String id,
    @Default(StorageType.webdav) StorageType type,
    required String name,
    @JsonKey(name: 'url') required String host, // raw input (can be wildcard)
    /// Recently resolved concrete hosts, most-recent first. DHCP reassigns
    /// IPs while credentials stay valid, so several candidates are kept and
    /// retried before falling back to a scan.
    @Default(<String>[]) List<String> resolvedHosts,

    required List<String> basePath,
    required String port,
    required String username,
    required String password,
    required bool https,
    /// Canonical data scope (NULL = independent).
    String? dataScopeId,
  }) = WebDAVStorage;

  factory Storage.ftp({
    required String id,
    @Default(StorageType.ftp) StorageType type,
    required String name,
    required String host,
    required List<String> basePath,
    required String port,
    required String username,
    required String password,
    /// Canonical data scope (NULL = independent).
    String? dataScopeId,
  }) = FTPStorage;

  factory Storage.fromJson(Map<String, dynamic> json) => _$StorageFromJson(json);

  // Never leak passwords through toString/debug output. The freezed-generated
  // toString would include `password: $password` which is a plaintext leak
  // whenever someone logs a storage object.
  @override
  String toString() {
    return map(
      local: (s) =>
          'Storage.local(id: ${s.id}, type: ${s.type}, name: ${s.name}, basePath: ${s.basePath})',
      webdav: (s) =>
          'Storage.webdav(id: ${s.id}, type: ${s.type}, name: ${s.name}, host: ${s.host}, resolvedHosts: ${s.resolvedHosts}, basePath: ${s.basePath}, port: ${s.port}, username: ${s.username}, password: ***, https: ${s.https})',
      ftp: (s) =>
          'Storage.ftp(id: ${s.id}, type: ${s.type}, name: ${s.name}, host: ${s.host}, basePath: ${s.basePath}, port: ${s.port}, username: ${s.username}, password: ***)',
    );
  }

  @override
  Future<List<FileItem>> getFiles(List<String> path) async {
    switch (type) {
      case StorageType.internal:
      case StorageType.network:
      case StorageType.usb:
      case StorageType.sdcard:
        // SAF storage: path[0] is the full content:// tree URI and the
        // remaining segments are literal relative names. Resolve the actual
        // container document URI via SafUtil.child (tree root itself when
        // there are no relative segments) and list THAT, so every returned
        // FileItem carries a real playable/probe content:// document URI and
        // a prefix-correct `path` list.
        if (isAndroid && path.isNotEmpty && path[0].startsWith('content://')) {
          final containerUri = await _safContainerUri(
            path[0],
            path.sublist(1).where((s) => s.isNotEmpty).toList(),
          );
          return await getContentFiles(containerUri, path);
        } else {
          return await getLocalFiles(this as LocalStorage, path);
        }
      case StorageType.webdav:
        final s = this as WebDAVStorage;

        // Prefer the most recently resolved hosts (DHCP shuffles IPs while
        // the credentials stay valid). Try each cached host in order before
        // falling back to the wildcard/hostname itself.
        for (final host in s.resolvedHosts) {
          final candidate = s.copyWith(host: host);
          if (await testWebDAV(candidate)) {
            return await getWebDAVFiles(candidate, path);
          }
        }

        // If none of the cached hosts answered → fall back to wildcard / hostname
        return await getWebDAVFiles(s, path);
      case StorageType.ftp:
        return await getFTPFiles(this as FTPStorage, path);
      case StorageType.none:
        return [];
    }
  }

  @override
  Future<FileListResult> getFilesDetailed(List<String> path) async {
    // Remote storages classify failures so an offline host is never mistaken
    // for an empty directory (and its DB snapshot is never purged). Local
    // storages keep the historical contract.
    if (type == StorageType.ftp) {
      return getFTPFilesResult(this as FTPStorage, path);
    }
    if (type != StorageType.webdav) {
      // Local / SAF: classify the failure so a permission denial (or a revoked
      // SAF grant) is surfaced as an error with a grant entry, never as an
      // empty folder. [getFiles] keeps its legacy list-only contract.
      if (isAndroid && path.isNotEmpty && path[0].startsWith('content://')) {
        final containerUri = await _safContainerUri(
          path[0],
          path.sublist(1).where((s) => s.isNotEmpty).toList(),
        );
        return getContentFilesResult(containerUri, path);
      }
      return getLocalFilesResult(this as LocalStorage, path);
    }

    final s = this as WebDAVStorage;

    // Prefer the most recently resolved hosts (DHCP shuffles IPs while the
    // credentials stay valid). When none answers, the fallback attempt against
    // the configured host supplies the error to report.
    for (final host in s.resolvedHosts) {
      final candidate = s.copyWith(host: host);
      if (await testWebDAV(candidate)) {
        return await getWebDAVFilesResult(candidate, path);
      }
    }

    return await getWebDAVFilesResult(s, path);
  }

  /// Resolves the document URI of an SAF subdirectory under [treeUri].
  ///
  /// With no relative segments returns [treeUri] itself (root listing). Each
  /// relative segment is located one level at a time via
  /// `SafUtil().child` — the SAF provider equivalent of descending a
  /// directory tree — so a deep browse/scan gets the exact container
  /// document URI to list. A failed descent returns the nearest existing
  /// ancestor (or [treeUri]) rather than throwing; the caller's listing then
  /// simply reflects what is reachable.
  Future<String> _safContainerUri(
    String treeUri,
    List<String> relativeSegments,
  ) async {
    if (relativeSegments.isEmpty) return treeUri;
    var current = treeUri;
    final found = <String>[];
    for (final seg in relativeSegments) {
      try {
        final child = await SafUtil().child(current, [seg]);
        if (child == null) break;
        current = child.uri;
        found.add(seg);
      } catch (_) {
        break;
      }
    }
    return current;
  }

  @override
  String? getAuth() {
    switch (type) {
      case StorageType.webdav:
        return getWebDAVAuth(this as WebDAVStorage);
      case StorageType.ftp:
        return getFTPAuth(this as FTPStorage);
      default:
        return null;
    }
  }
}

/// Convenience view over a WebDAV entry's resolution cache.
extension WebDAVStorageResolvedHosts on WebDAVStorage {
  /// The most recently resolved concrete host, or null when none is cached.
  String? get resolvedHost => resolvedHosts.isEmpty ? null : resolvedHosts.first;
}

Future<void> openInFolder(
  BuildContext context,
  FileItem file, {
  required PopupDirection direction,
}) async {
  if (file.path.isEmpty) return;
  useStorageStore().updateCurrentPath(file.path.sublist(0, file.path.length - 1));

  Storage? storage = useStorageStore().findById(file.storageId);

  if (storage != null) {
    useStorageStore().updateCurrentStorage(storage);
  } else {
    final localStorages = await getLocalStorages(context);
    Storage? storage =
        localStorages.firstWhereOrNull((element) => element.basePath[0] == file.path[0]);
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
      child: Storages(),
      direction: direction,
    );
  }
}
