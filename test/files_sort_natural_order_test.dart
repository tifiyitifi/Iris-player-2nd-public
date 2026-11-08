import 'package:flutter_test/flutter_test.dart';
import 'package:iris/models/file.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/utils/files_sort.dart';

/// The file browser (storages popup) sorts in memory, not through the DB, so it
/// has its own list of names to keep natural: 1, 2, 10.
void main() {
  FileItem file(String name, {bool isDir = false}) => FileItem(
        storageId: 'st',
        name: name,
        uri: '/$name',
        path: [name],
        size: 0,
        type: ContentType.other,
        isDir: isDir,
      );

  List<String> sorted(List<String> names, [SortOrder order = SortOrder.asc]) =>
      [for (final f in filesSort(files: names.map(file).toList(), sortOrder: order)) f.name];

  test('name order is natural, not lexicographic', () {
    expect(
      sorted(['10.mkv', '2.mkv', '1.mkv', '20.mkv']),
      ['1.mkv', '2.mkv', '10.mkv', '20.mkv'],
    );
  });

  test('descending is the exact reverse', () {
    expect(
      sorted(['10.mkv', '2.mkv', '1.mkv'], SortOrder.desc),
      ['10.mkv', '2.mkv', '1.mkv'],
    );
  });

  test('folders stay first regardless of the natural order', () {
    final items = [
      file('b.mkv'),
      file('a_dir', isDir: true),
      file('2.mkv'),
    ];
    final out = filesSort(files: items);
    expect(out.first.name, 'a_dir');
    expect(out.skip(1).map((f) => f.name).toList(), ['2.mkv', 'b.mkv']);
  });

  test('episode style names keep their episode order', () {
    expect(
      sorted(['ep10.mp4', 'ep2.mp4', 'ep1.mp4']),
      ['ep1.mp4', 'ep2.mp4', 'ep10.mp4'],
    );
  });
}
