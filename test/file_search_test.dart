import 'package:flutter_test/flutter_test.dart';
import 'package:orgro/src/roam/files.dart';

FileEntry _f(
  String path, {
  int day = 1,
  String dir = 'root',
  String root = 'notes',
}) => FileEntry(
  dirIdentifier: dir,
  rootName: root,
  relativePath: path,
  fileName: path.split('/').last,
  modified: DateTime(2026, 1, day),
);

void main() {
  final files = [
    _f('5Semester/algobioII/Vorlesungen/Skript.pdf', day: 3),
    _f('todo.org', day: 9),
    _f('images/20260722154426.png', day: 2),
    _f('4Semester/FSK/Aufgaben/Solved/fsk_blatt-05-solved.pdf', day: 5),
    _f('roam/20260513103041-boyer_moore_algorithmus.org', day: 4),
  ];

  List<String> paths(String q) =>
      searchFiles(files, q).map((m) => m.file.relativePath).toList();

  test('matches name and folder, any order', () {
    expect(paths('skript'), ['5Semester/algobioII/Vorlesungen/Skript.pdf']);
    expect(paths('algobio skript'), [
      '5Semester/algobioII/Vorlesungen/Skript.pdf',
    ]);
    expect(paths('fsk 05').single, contains('fsk_blatt-05'));
    expect(paths('boyer moore').single, contains('boyer_moore'));
  });

  test('empty query: newest first', () {
    expect(paths('').first, 'todo.org');
  });

  test('folder and type helpers', () {
    final f = files.first;
    expect(f.folder, 'notes/5Semester/algobioII/Vorlesungen');
    expect(f.extension, 'pdf');
    expect(files[1].isOrg, isTrue);
    expect(files[1].folder, 'notes');
  });

  test('nested grants: same file listed twice keeps one', () {
    final outer = _f('roam/a.org', dir: 'outer', root: 'notes');
    final inner = _f('a.org', dir: 'inner', root: 'roam');
    final deduped = dedupeNested([inner, outer]);
    expect(deduped.single.dirIdentifier, 'outer');
  });
}
