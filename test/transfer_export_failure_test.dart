import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/settings_transfer/services/transfer_service.dart';

/// A section whose encoder swallows its own failure must be REPORTED, not
/// written as an empty payload a reader would take for a successful backup.
void main() {
  test('failedExportSections flags a payload carrying an error key', () {
    expect(
      failedExportSections({
        'scenarios': {'subVersion': 1, 'payload': <dynamic>[], 'error': 'boom'},
        'tagPlay': {
          'subVersion': 1,
          'payload': <dynamic>[1],
        },
      }),
      ['scenarios'],
    );
    // No error key: an ordinary (possibly empty) section is not a failure.
    expect(
      failedExportSections({
        'tagPlay': {'subVersion': 1, 'payload': <dynamic>[]},
      }),
      isEmpty,
    );
  });

  test('buildExport reports the section whose coder failed', () async {
    // No DbModule in this isolate, so `ScenarioCoder.encode()` catches the
    // uninitialized-repo error and returns its `error` payload — exactly the
    // swallowed failure a real DB error produces.
    final result = await TransferService.buildExport(
      selectedSections: {'scenarios'},
    );
    expect(result.failedSections, ['scenarios']);
    expect(result.isPartial, isTrue);
    // The file is still produced (partial), so the caller can offer the choice.
    expect(result.json, contains('scenarios'));
  });
}
