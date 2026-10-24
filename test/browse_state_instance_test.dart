import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/view/content/store/use_media_lib_content_store.dart';
import 'package:iris/models/db/app_database.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/use_kv_store.dart';
import 'package:iris/utils/app_instance.dart';

import 'helpers/sqlite3_loader.dart';

/// Browse/view state ("which page, which filter, which storage") answers "where
/// am I", exactly like the play queue. It must be per-window: two windows
/// browsing different places used to overwrite each other's restored view.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  ensureSqlite3Loaded();

  setUpAll(() async {
    await DbModule.init(AppDatabase(NativeDatabase.memory()));
  });

  setUp(() {
    setKvStoreForTest(MemoryKvStore());
    AppInstance.debugReset();
  });

  tearDown(() {
    resetKvStoreForTest();
    AppInstance.debugReset();
  });

  MediaLibContentStore store() => MediaLibContentStore(
        nodeRepository: DbModule.mediaNodeRepo,
        sourcesRepository: DbModule.libSourceRepo,
        facade: DbModule.mediaFacade,
      );

  test('browse view state is per window', () async {
    AppInstance.debugSetSlot(1);
    final first = store();
    await first.initialized;
    await first.save(first.state.copyWith(requestedPage: 3));

    AppInstance.debugSetSlot(2);
    final second = store();
    await second.initialized;

    expect(second.state.requestedPage, 0,
        reason: 'a second window must not inherit the primary view');
  });

  test('both windows still restore their own state', () async {
    AppInstance.debugSetSlot(1);
    final first = store();
    await first.initialized;
    await first.save(first.state.copyWith(requestedPage: 3));

    AppInstance.debugSetSlot(2);
    final second = store();
    await second.initialized;
    await second.save(second.state.copyWith(requestedPage: 5));

    AppInstance.debugSetSlot(1);
    final firstAgain = store();
    await firstAgain.initialized;

    AppInstance.debugSetSlot(2);
    final secondAgain = store();
    await secondAgain.initialized;

    expect(firstAgain.state.requestedPage, 3);
    expect(secondAgain.state.requestedPage, 5);
  });
}
