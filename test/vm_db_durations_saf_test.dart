import 'package:drift/native.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/scan/vm_db_durations.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';

import 'helpers/sqlite3_loader.dart';

/// A SAF single pick stores an EMPTY `path` and carries its identity in `uri`.
/// Both the duration reader and the progress reader must key it through the
/// one canonical helper (`storageId:content://…`), or a healed duration is
/// never confirmed and a VM session can never resume that file.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  const secureStorageChannel =
      MethodChannel('plugins.it_nomads.com/flutter_secure_storage');
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(secureStorageChannel, (call) async => null);

  const uri = 'content://doc/a';
  final mediaKey = canonicalMediaKey('s', const [], uri: uri);

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
    await DbModule.mediaNodesDao.insertNode(
      MediaNode.file(
        id: 'f:s:doc-a',
        storageId: 's',
        path: const [],
        name: 'a.mp4',
        mediaType: MediaType.video,
        durationMs: 4321,
        uri: uri,
      ),
    );
  });

  VirtualSegment safSegment() => VirtualSegment(
        mediaKey: mediaKey,
        storageId: 's',
        path: const [],
        name: 'a.mp4',
        parentPath: '',
        uri: uri,
      );

  test('duration reader heals a SAF single pick by its uri', () async {
    final out = await defaultVmDbDurationReader([safSegment()]);
    expect(out[mediaKey], 4321);
  });

  test('progress reader keys a SAF single pick by its uri', () async {
    final out = await DbModule.mediaNodeRepo.progressForMediaKeys({mediaKey});
    expect(out.containsKey(mediaKey), isTrue);
  });
}
