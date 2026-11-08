import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/storages/local.dart';
import 'package:iris/models/storages/storage.dart';
import 'package:path/path.dart' as p;

/// A scan must not pay a `stat()` for entries it is about to throw away.
///
/// Measured on a 2019 Android 10 phone: 34,005 directories / 20,916 playable
/// files / ~180,000 images. The listing stat-ed every entry, so a full-volume
/// scan spent 51–62% of its time (160–193 s of 313 s, AOT profile) on facts for
/// rows that never reached the database.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory root;
  late LocalStorage storage;
  late List<String> path;

  setUp(() {
    root = Directory.systemTemp.createTempSync('iris_listing_facts');
    File(p.join(root.path, 'movie.mkv')).writeAsBytesSync(List.filled(64, 0));
    File(p.join(root.path, 'cover.jpg')).writeAsBytesSync(List.filled(32, 0));
    File(p.join(root.path, 'movie.zh.srt')).writeAsStringSync('1');
    Directory(p.join(root.path, 'sub')).createSync();
    storage = Storage.local(
      type: StorageType.internal,
      name: 'T',
      basePath: [root.path],
    ) as LocalStorage;
    path = [root.path];
  });

  tearDown(() {
    if (root.existsSync()) root.deleteSync(recursive: true);
  });

  Future<FileItem> itemNamed(String name, {required bool withEntryFacts}) async {
    final result =
        await getLocalFilesResult(storage, path, withEntryFacts: withEntryFacts);
    return result.items.firstWhere((f) => f.name == name);
  }

  test('the browser keeps size and date for every kind of entry', () async {
    expect((await itemNamed('movie.mkv', withEntryFacts: true)).size, 64);
    expect(
      (await itemNamed('cover.jpg', withEntryFacts: true)).lastModified,
      isNotNull,
      reason: 'the file browser draws a date column for images too',
    );
    expect(
      (await itemNamed('sub', withEntryFacts: true)).lastModified,
      isNotNull,
      reason: 'the file browser draws a date column for folders too',
    );
  });

  test('a scan skips facts for entries it cannot catalogue', () async {
    final image = await itemNamed('cover.jpg', withEntryFacts: false);
    expect(image.size, 0);
    expect(image.lastModified, isNull,
        reason: 'no stat() may be spent on an image the scan discards');

    final dir = await itemNamed('sub', withEntryFacts: false);
    expect(dir.isDir, isTrue);
    expect(dir.lastModified, isNull,
        reason: 'only the name matters for a directory during a scan');
  });

  test('a scan still gets the facts and associations its rows need', () async {
    final video = await itemNamed('movie.mkv', withEntryFacts: false);
    expect(video.size, 64);
    expect(video.lastModified, isNotNull,
        reason: 'size + mtime are the incremental-sync identity of a file');
    expect(video.subtitles, isNotEmpty,
        reason: 'pairing comes from the listing, not from a stat()');
  });
}
