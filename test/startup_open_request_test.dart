import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/app_instance/model/new_window_request.dart';
import 'package:iris/features/app_instance/services/startup_open_request.dart';
import 'package:iris/models/file.dart';

/// A spawned window replays its `--open-request` payload. A payload with no
/// action (e.g. a default-constructed request that only serializes `sort`) must
/// NOT be consumed: consuming it skips the generic startup resume and leaves a
/// blank window.
void main() {
  const file = NewWindowFile(
    storageId: 's',
    name: 'a.mp4',
    uri: '/a.mp4',
    path: ['a.mp4'],
    type: ContentType.video,
  );

  test('a default request carries no action', () {
    expect(startupRequestHasAction(const NewWindowRequest()), isFalse);
  });

  test('entries without a storageId are not an action', () {
    // `{"files":[{}]}` deserializes to one all-default NewWindowFile. Replaying
    // it can only fail, so treating it as "consumed" would show the play-failed
    // dialog AND skip the resume the window should have run.
    const hollowFile = NewWindowFile(storageId: '', name: '', uri: '', path: []);
    expect(
      startupRequestHasAction(const NewWindowRequest(files: [hollowFile])),
      isFalse,
    );
    expect(
      startupRequestHasAction(const NewWindowRequest(folders: [
        NewWindowFolder(storageId: '', path: ''),
      ])),
      isFalse,
    );
    expect(
      startupRequestHasAction(const NewWindowRequest(startFile: hollowFile)),
      isFalse,
    );
    expect(
      startupRequestHasAction(
        const NewWindowRequest(openStorageId: '', openPath: ['']),
      ),
      isFalse,
    );

    // A hollow entry next to a valid one keeps the request actionable: the
    // replay drops just the invalid row (mixed payload).
    expect(
      startupRequestHasAction(
        const NewWindowRequest(files: [hollowFile, file]),
      ),
      isTrue,
    );
  });

  test('every explicit surface counts as an action', () {
    expect(
      startupRequestHasAction(const NewWindowRequest(scenarioId: 'sc')),
      isTrue,
    );
    expect(
      startupRequestHasAction(const NewWindowRequest(libraryId: 'lib')),
      isTrue,
    );
    expect(
      startupRequestHasAction(
        const NewWindowRequest(openStorageId: 's', openPath: ['Movies']),
      ),
      isTrue,
    );
    expect(
      startupRequestHasAction(const NewWindowRequest(folders: [
        NewWindowFolder(storageId: 's', path: 'Movies'),
      ])),
      isTrue,
    );
    expect(
      startupRequestHasAction(const NewWindowRequest(files: [file])),
      isTrue,
    );
    expect(
      startupRequestHasAction(const NewWindowRequest(startFile: file)),
      isTrue,
    );
  });
}
