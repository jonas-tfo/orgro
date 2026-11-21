import 'package:flutter_test/flutter_test.dart';
import 'package:orgro/src/roam/fuzzy.dart';
import 'package:orgro/src/roam/nodes.dart';

OrgFileData _file(String name, List<String> lines, {DateTime? modified}) =>
    OrgFileData(
      identifier: name,
      uri: 'file:///notes/$name',
      fileName: name,
      relativePath: 'roam/$name',
      modified: modified ?? DateTime(2026),
      content: lines.join('\n'),
    );

void main() {
  group('parseRoamNodes', () {
    test('file node with title and filetags', () {
      final nodes = parseRoamNodes(
        _file('20260512-kmp.org', [
          ':ID:       7e3592ba',
          '#+title: Knuth-Morris-Pratt Algorithmus (KMP)',
          '#+FILETAGS: :algo:uni:',
          '** Grundidee:',
        ]),
      );
      expect(nodes, hasLength(1));
      final node = nodes.single;
      expect(node.id, '7e3592ba');
      expect(node.title, 'Knuth-Morris-Pratt Algorithmus (KMP)');
      expect(node.tags, ['algo', 'uni']);
      expect(node.isFileNode, isTrue);
    });

    test('file title falls back to file name', () {
      final nodes = parseRoamNodes(_file('untitled.org', [':ID: abc']));
      expect(nodes.single.title, 'untitled');
    });

    test('headline nodes with outline, tags, aliases, cleanup', () {
      final nodes = parseRoamNodes(
        _file('folding.org', [
          ':ID: file-id',
          '#+title: Protein Faltung',
          '#+filetags: bio',
          '* Struktur :struct:',
          '** TODO [#A] Thermodynamik [[id:x][der]] Faltung [1/2] :thermo:',
          ':ID: head-id',
          ':ROAM_ALIASES: "Folding energy" dG',
          '* Excluded',
          ':ID: excluded-id',
          ':ROAM_EXCLUDE: t',
          '** Child of excluded',
          ':ID: child-id',
        ]),
      );
      expect(nodes.map((n) => n.id), ['file-id', 'head-id']);
      final head = nodes[1];
      expect(head.title, 'Thermodynamik der Faltung');
      expect(head.level, 2);
      expect(head.outline, ['Struktur']);
      expect(head.breadcrumb, 'Protein Faltung › Struktur');
      expect(head.tags, ['bio', 'struct', 'thermo']);
      expect(head.aliases, ['Folding energy', 'dG']);
    });

    test('ID only applies to the most recent entity', () {
      final nodes = parseRoamNodes(
        _file('a.org', ['* One', '* Two', ':ID: two']),
      );
      expect(nodes.single.title, 'Two');
    });
  });

  test('buildRoamIndex keeps the newest file for duplicate IDs', () {
    final index = buildRoamIndex([
      _file('note 2.org', [
        ':ID: same',
        '#+title: Old',
      ], modified: DateTime(2026, 5)),
      _file('note.org', [
        ':ID: same',
        '#+title: New',
      ], modified: DateTime(2026, 9)),
    ]);
    expect(index.single.title, 'New');
  });

  group('searchRoamNodes', () {
    final nodes = buildRoamIndex([
      _file('a.org', [
        ':ID: kmp',
        '#+title: Knuth-Morris-Pratt Algorithmus',
        '#+filetags: :algo:',
      ], modified: DateTime(2026, 1)),
      _file('b.org', [
        ':ID: aqui',
        '#+title: Äquivalenzklasse (Equivalence Class)',
      ], modified: DateTime(2026, 3)),
      _file('c.org', [
        ':ID: bm',
        '#+title: Boyer-Moore Algorithmus',
        '#+filetags: :algo:',
      ], modified: DateTime(2026, 2)),
      _file('d.org', [
        ':ID: textsuche',
        '#+title: Textsuche',
      ], modified: DateTime(2026, 4)),
    ]);

    List<String> ids(String q) =>
        searchRoamNodes(nodes, q).map((m) => m.node.id).toList();

    test('empty query lists most recently modified first', () {
      expect(ids(''), ['textsuche', 'aqui', 'bm', 'kmp']);
    });

    test('space-separated terms match in any order', () {
      expect(ids('algo moore'), ['bm']);
      expect(ids('moore algo'), ['bm']);
    });

    test('diacritics are folded', () {
      expect(ids('aquiv'), ['aqui']);
    });

    test('flex matching tolerates abbreviations', () {
      expect(ids('kmpalg').first, 'kmp');
    });

    test('# terms only match tags', () {
      expect(ids('#algo').toSet(), {'kmp', 'bm'});
      expect(ids('#textsuche'), isEmpty);
    });

    test('prefix matches rank above inner matches', () {
      expect(ids('text').first, 'textsuche');
    });

    test('title highlights cover the literal match', () {
      final match = searchRoamNodes(nodes, 'moore').single;
      final title = match.node.title;
      final highlighted = [
        for (final i in match.titleHighlights.toList()..sort()) title[i],
      ].join();
      expect(highlighted, 'Moore');
    });
  });
}
