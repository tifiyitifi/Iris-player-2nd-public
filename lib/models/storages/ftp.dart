import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:iris/models/enums/storage_list_error.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/file_list_result.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:iris/utils/check_content_type.dart';
import 'package:iris/utils/get_subtitle_map.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/storage_path_guard.dart';
import 'package:pure_ftp/pure_ftp.dart';
final areaKeyLog = AreaKeyLog(LogKeys.legacyDb);

/// Classifies an FTP listing failure so the UI can explain WHY it failed
/// instead of rendering an unreachable host as an empty directory.
///
/// Mirrors [classifyStorageListFailure] (WebDAV) so both remote storages share
/// the same [StorageListErrorKind] contract: unreachable never implies the
/// DB rows were deleted.
StorageListErrorKind classifyFtpListFailure(Object error) {
  final text = error.toString().toLowerCase();

  if (text.contains('530') ||
      text.contains('531') ||
      text.contains('532') ||
      text.contains('login incorrect') ||
      text.contains('authentication failed') ||
      text.contains('unauthorized') ||
      text.contains('forbidden')) {
    return StorageListErrorKind.unauthorized;
  }

  if (error is TimeoutException || text.contains('timeout')) {
    return StorageListErrorKind.timeout;
  }

  if (error is SocketException ||
      text.contains('socket') ||
      text.contains('failed host lookup') ||
      text.contains('connection refused') ||
      text.contains('network is unreachable') ||
      text.contains('host unreachable') ||
      text.contains('no route to host')) {
    return StorageListErrorKind.unreachable;
  }

  return StorageListErrorKind.unknown;
}

Future<List<FileItem>> getFTPFiles(
    FTPStorage storage, List<String> path) async =>
    (await getFTPFilesResult(storage, path)).items;

/// Lists [path], reporting failures through [FileListResult] instead of
/// collapsing them into an empty list (which made an offline host look like
/// an empty folder and risked the caller purging the DB snapshot).
Future<FileListResult> getFTPFilesResult(
  FTPStorage storage,
  List<String> path,
) async {
  if (hasUnsafeRemotePathSegment(path)) {
    areaKeyLog.w('getFTPFiles rejected traversal path: $path');
    return const FileListResult(<FileItem>[],
        errorKind: StorageListErrorKind.unknown);
  }
  return _listFtpFiles(storage, path);
}

Future<FileListResult> _listFtpFiles(
    FTPStorage storage, List<String> path) async {
  final username = storage.username.isEmpty ? 'anonymous' : storage.username;

  final client = FtpClient(
    socketInitOptions: FtpSocketInitOptions(
      host: storage.host,
      port: int.tryParse(storage.port),
    ),
    authOptions: FtpAuthOptions(
      username: username,
      password: storage.password,
      account: '',
    ),
    logCallback: null,
  );

  // Reject traversal in requested path.
  if (hasUnsafeRemotePathSegment(path)) {
    areaKeyLog.w('getFTPFiles rejected traversal path: $path');
    return const FileListResult(<FileItem>[],
        errorKind: StorageListErrorKind.unknown);
  }
  bool connected = false;
  try {
    await client.connect();
    connected = true;
    await client.fs.changeDirectory(path.join('/').replaceAll('//', '/'));

    final files = await client.fs.listDirectory();

    final basePath = path.join('/').replaceAll('//', '/');

    String getUri(String fileName) {
      final separator = basePath.endsWith('/') ? '' : '/';
      // Same single encoder as playback (`media_uri.dart` `ftpPlayableUri`): a
      // name carrying `&` / `#` used to be left raw by `Uri.encodeFull` and
      // truncated the proxy query.
      return 'ftp?host=${storage.host}&port=${storage.port}'
          '&path=${encodeFtpProxyPath('$basePath$separator$fileName')}';
    }

    final subtitleMap = getSubtitleMap<FtpEntry>(
      files: files,
      getName: (file) => file.name,
      getUri: (file) => getUri(file.name),
    );

    List<FileItem> fileItems = [];

    for (final file in files) {
      if (file.name.contains('/') || file.name == '..' || file.name == '.') {
        areaKeyLog.w('getFTPFiles skip traversal file: ${file.name}');
        continue;
      }
      fileItems.add(
        FileItem(
          storageId: storage.id,
          storageType: StorageType.ftp,
          name: file.name,
          uri: getUri(file.name),
          path: [...path, file.name],
          isDir: file.isDirectory,
          size: file.isDirectory ? 0 : file.info?.size ?? 0,
          lastModified: file.info?.modifyTime != null
              ? DateTime.tryParse(file.info!.modifyTime!)
              : null,
          type: file.isDirectory
              ? ContentType.other
              : checkContentType(file.name),
          subtitles: isVideoFile(file.name)
              ? subtitleMap[subtitleMapKey(file.name)] ?? []
              : [],
        ),
      );
    }

    return FileListResult(fileItems);
  } catch (error) {
    areaKeyLog.e('Error getting FTP files: $error');
    return FileListResult(
      const <FileItem>[],
      errorKind: classifyFtpListFailure(error),
      errorDetail: error.toString(),
    );
  } finally {
    if (connected) {
      try {
        await client.disconnect();
      } catch (_) {}
    }
  }
}

Future<bool> testFTP(FTPStorage storage) async {
  final client = FtpClient(
    socketInitOptions: FtpSocketInitOptions(
      host: storage.host,
      port: int.tryParse(storage.port),
    ),
    authOptions: FtpAuthOptions(
      username: storage.username.isEmpty ? 'anonymous' : storage.username,
      password: storage.password,
      account: '',
    ),
    logCallback: null,
  );

  bool connected = false;
  try {
    await client.connect();
    connected = true;
    await client.fs.listDirectory();
    await client.disconnect();
    return true;
  } catch (error) {
    areaKeyLog.e('Error testing FTP: $error');
    return false;
  } finally {
    if (connected) {
      try {
        await client.disconnect();
      } catch (_) {}
    }
  }
}

String getFTPAuth(FTPStorage storage) =>
    'Basic ${base64Encode(utf8.encode('${storage.username.isEmpty ? 'anonymous' : storage.username}:${storage.password}'))}';
