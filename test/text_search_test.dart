import 'package:flutter_test/flutter_test.dart';
import 'package:org_flutter/org_flutter.dart';
import 'package:orgro/src/roam/nodes.dart';
import 'package:orgro/src/roam/text_search.dart';

OrgFileData _file(String name, String content, {DateTime? modified}) =>
    OrgFileData(
      identifier: name,
      uri: 'file:///notes/$name',
      fileName: name,
      relativePath: name,
      modified: modified ?? DateTime(2026),
      content: content,
    );

void main() {
  final files = [
    _file('kmp.org', r'''
:PROPERTIES:
:ID:       7e3592ba
:END:
#+title: Knuth-Morris-Pratt
* Laufzeit
Der Algorithmus benötigt maximal $2n-m+1$ Zeichenvergleiche für die Suche.
* Rand
Ein Rand heißt *echter* Rand, wenn r ≠ w.''', modified: DateTime(2026, 1)),
    _file('stats.org', '''
#+title: Statistik
Die Laufzeit der Suche ist hier egal.''', modified: DateTime(2026, 6)),
  ];

  test('all terms must appear on the line, any order', () {
    final hits = searchText(files, 'suche laufzeit').hits;
    expect(hits.map((h) => h.file.fileName), ['stats.org']);
    expect(searchText(files, 'vergleiche suche').hits.single.lineNumber, 6);
  });

  test('newest file first, heading context, title', () {
    final hits = searchText(files, 'suche').hits;
    expect(hits.map((h) => h.fileTitle), ['Statistik', 'Knuth-Morris-Pratt']);
    expect(hits[1].heading, 'Laufzeit');
    expect(hits[0].heading, isNull);
  });

  test('ignores case, diacritics and property drawers', () {
    expect(searchText(files, 'BENOTIGT').hits, hasLength(1));
    expect(searchText(files, '7e3592ba').hits, isEmpty);
  });

  test('too-short queries return nothing', () {
    expect(searchText(files, 'r').hits, isEmpty);
  });

  test('limit truncates', () {
    final r = searchText(files, 'rand', limit: 1);
    expect(r.hits, hasLength(1));
    expect(r.truncated, isTrue);
  });

  test('highlights cover the match', () {
    final hit = searchText(files, 'zeichen').hits.single;
    final s = [for (final i in hit.highlights.toList()..sort()) hit.line[i]];
    expect(s.join(), 'Zeichen');
  });

  test('jump text avoids markup and works as a regexp search option', () {
    final hit = searchText(files, 'vergleiche').hits.single;
    expect(hit.jumpText, isNot(contains(r'$')));
    expect(hit.jumpText.toLowerCase(), contains('vergleiche'));
    final target = '/${RegExp.escape(hit.jumpText)}/';
    expect(isRegexpSearch(target), isTrue);
    expect(RegExp(parseRegexpSearch(target)).hasMatch(hit.line), isTrue);

    final rand = searchText(files, 'echter').hits.single;
    // The match itself is wrapped in markup, so only the word is used
    expect(rand.jumpText, 'echter');
  });
}
