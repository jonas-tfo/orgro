import 'package:flutter_test/flutter_test.dart';
import 'package:orgro/src/notes_settings.dart';
import 'package:orgro/src/papers/papers.dart';

const _bib = r'''
@comment{jabref-meta: whatever}
@article{jumperHighlyAccurateProtein2021,
  title = {Highly Accurate Protein Structure Prediction with {{AlphaFold}}},
  author = {Jumper, John and Evans, Richard and Pritzel, Alexander},
  date = {2021-08},
  journaltitle = {Nature},
  doi = {10.1038/s41586-021-03819-2},
  url = {https://www.nature.com/articles/s41586-021-03819-2}
}

@article{delalamoSampling2022,
  title = {Sampling Alternative Conformational States with {{AlphaFold2}}},
  author = {family=Alamo, given=Diego, prefix=del, useprefix=true and Sala, Davide},
  date = {2022},
  journaltitle = {eLife},
  doi = {https://doi.org/10.7554/eLife.75751}
}

@online{TMalign,
  title = "{TM-Align}: A Protein Structure Alignment -- Algorithm",
  url = {https://zhanggroup.org/TM-align/},
  organization = {Zhang Lab}
}

@inproceedings{kroger2021,
  title = {Ligand Recognition in {PotF} by Kr\"{o}ger},
  author = {Kr{\"o}ger, Pascal and {World Health Organization}},
  year = 2021,
  booktitle = {Proceedings}
}

@article{noTitle, author = {Nobody}}
''';

void main() {
  final papers = parseBibliography(_bib);

  test('parses entries, skips comments and untitled ones', () {
    expect(papers.map((p) => p.key), [
      'jumperHighlyAccurateProtein2021',
      'delalamoSampling2022',
      'TMalign',
      'kroger2021',
    ]);
  });

  test('fields are cleaned', () {
    final jumper = papers[0];
    expect(
      jumper.title,
      'Highly Accurate Protein Structure Prediction with AlphaFold',
    );
    expect(jumper.authors, ['Jumper', 'Evans', 'Pritzel']);
    expect(jumper.authorsShort, 'Jumper et al.');
    expect(jumper.year, '2021');
    expect(jumper.venue, 'Nature');

    expect(papers[1].authors, ['del Alamo', 'Sala']);
    expect(papers[1].authorsShort, 'del Alamo & Sala');

    expect(
      papers[2].title,
      'TM-Align: A Protein Structure Alignment – Algorithm',
    );
    expect(papers[2].venue, 'Zhang Lab');

    expect(papers[3].title, 'Ligand Recognition in PotF by Kröger');
    expect(papers[3].authors, ['Kröger', 'World Health Organization']);
    expect(papers[3].year, '2021');
  });

  test('links: DOI resolver first (prefixes stripped), then URL', () {
    expect(
      papers[0].link.toString(),
      'https://doi.org/10.1038/s41586-021-03819-2',
    );
    expect(papers[1].link.toString(), 'https://doi.org/10.7554/eLife.75751');
    expect(papers[2].link.toString(), 'https://zhanggroup.org/TM-align/');
    expect(papers[3].link, isNull);
  });

  test('search: title, author, year, any order, folded', () {
    List<String> keys(String q) =>
        searchPapers(papers, q).map((m) => m.paper.key).toList();
    expect(keys('alphafold').toSet(), {
      'jumperHighlyAccurateProtein2021',
      'delalamoSampling2022',
    });
    expect(keys('2021 jumper'), ['jumperHighlyAccurateProtein2021']);
    expect(keys('kroger'), ['kroger2021']);
    expect(keys('nothing matches this'), isEmpty);
    // Empty query: newest first
    expect(keys('').first, 'delalamoSampling2022');
  });

  test('bibliography path is normalized to be relative', () {
    expect(
      normalizeBibliographyPath(' ./references/x.bib '),
      'references/x.bib',
    );
    expect(normalizeBibliographyPath('/refs.bib'), 'refs.bib');
  });
}
