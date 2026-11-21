// Papers from a BibTeX/BibLaTeX bibliography (e.g. a Zotero Better BibTeX
// export): parse entries, fuzzy-find them like citar, and build a link to
// open them (DOI first, then URL).

import 'dart:math';

import 'package:orgro/src/roam/fuzzy.dart';

class Paper {
  Paper({
    required this.key,
    required this.type,
    required this.title,
    this.authors = const [],
    this.year,
    this.venue,
    this.doi,
    this.url,
  });

  final String key;
  final String type;
  final String title;

  /// Family names
  final List<String> authors;
  final String? year;

  /// Journal, conference or website
  final String? venue;
  final String? doi;
  final String? url;

  /// "Smith", "Smith & Jones", "Smith et al."
  String get authorsShort => switch (authors.length) {
    0 => '',
    1 => authors.first,
    2 => '${authors[0]} & ${authors[1]}',
    _ => '${authors.first} et al.',
  };

  /// Where to open the paper: the DOI resolver, otherwise its URL
  Uri? get link {
    final d = doi;
    if (d != null && d.isNotEmpty) {
      return Uri.parse('https://doi.org/${Uri.encodeFull(cleanDoi(d))}');
    }
    final u = url;
    if (u != null && u.isNotEmpty) return Uri.tryParse(u);
    return null;
  }

  @override
  String toString() => 'Paper($key, $title)';
}

/// Strip resolver prefixes some exports include in the doi field
String cleanDoi(String doi) => doi
    .trim()
    .replaceFirst(
      RegExp(r'^https?://(dx\.)?doi\.org/', caseSensitive: false),
      '',
    )
    .replaceFirst(RegExp(r'^doi:\s*', caseSensitive: false), '');

// --- Parsing ---------------------------------------------------------------

const _accents = {
  '"': {
    'a': 'ä',
    'o': 'ö',
    'u': 'ü',
    'A': 'Ä',
    'O': 'Ö',
    'U': 'Ü',
    'e': 'ë',
    'i': 'ï',
  },
  "'": {'a': 'á', 'e': 'é', 'i': 'í', 'o': 'ó', 'u': 'ú', 'E': 'É', 'y': 'ý'},
  '`': {'a': 'à', 'e': 'è', 'i': 'ì', 'o': 'ò', 'u': 'ù'},
  '^': {'a': 'â', 'e': 'ê', 'i': 'î', 'o': 'ô', 'u': 'û'},
  '~': {'n': 'ñ', 'a': 'ã', 'o': 'õ', 'N': 'Ñ'},
  'c': {'c': 'ç', 'C': 'Ç'},
};

const _symbols = {
  r'\ss': 'ß',
  r'\o': 'ø',
  r'\O': 'Ø',
  r'\aa': 'å',
  r'\AA': 'Å',
  r'\ae': 'æ',
  r'\&': '&',
  r'\%': '%',
  r'\_': '_',
  r'\$': r'$',
};

/// Turn BibTeX field markup into plain text: LaTeX accents, protective
/// braces, dashes, simple commands like \textit{...}
String cleanBibText(String raw) {
  var s = raw;
  // \"{o}, \"o, {\"o}
  s = s.replaceAllMapped(
    RegExp(r'''\{?\\(["'`^~c])\s*\{?([a-zA-Z])\}?\}?'''),
    (m) => _accents[m[1]]?[m[2]] ?? m[2]!,
  );
  for (final e in _symbols.entries) {
    s = s.replaceAll('{${e.key}}', e.value).replaceAll(e.key, e.value);
  }
  // \textit{x}, \emph{x} -> x
  s = s.replaceAllMapped(RegExp(r'\\[a-zA-Z]+\s*\{([^{}]*)\}'), (m) => m[1]!);
  s = s.replaceAll('---', '—').replaceAll('--', '–');
  s = s.replaceAll(RegExp(r'[{}]'), '');
  s = s.replaceAll('~', ' ');
  return s.replaceAll(RegExp(r'\s+'), ' ').trim();
}

/// Family names from a BibTeX author list ("Last, First and First Last")
List<String> parseAuthors(String raw) {
  final names = raw
      .split(RegExp(r'\s+and\s+'))
      .map((n) => n.trim())
      .where((n) => n.isNotEmpty);
  return [
    for (final name in names)
      if (name.toLowerCase() == 'others')
        ...const <String>[]
      else
        _familyName(name),
  ];
}

String _familyName(String name) {
  // Corporate authors are wrapped in extra braces: keep whole
  if (name.startsWith('{') && name.endsWith('}')) return cleanBibText(name);
  // BibLaTeX extended format: family=Alamo, given=Diego, prefix=del, ...
  if (RegExp(r'(^|,\s*)family=').hasMatch(name)) {
    final parts = {
      for (final part in name.split(','))
        if (part.contains('='))
          part.substring(0, part.indexOf('=')).trim(): part
              .substring(part.indexOf('=') + 1)
              .trim(),
    };
    final family = cleanBibText(parts['family'] ?? '');
    final prefix = cleanBibText(parts['prefix'] ?? '');
    final usePrefix = parts['useprefix']?.toLowerCase() == 'true';
    return usePrefix && prefix.isNotEmpty ? '$prefix $family' : family;
  }
  final comma = name.indexOf(',');
  if (comma != -1) return cleanBibText(name.substring(0, comma));
  final parts = cleanBibText(name).split(' ');
  return parts.last;
}

/// Parse a .bib file. Malformed entries are skipped rather than failing.
List<Paper> parseBibliography(String source) {
  final papers = <Paper>[];
  var i = 0;
  while (true) {
    final at = source.indexOf('@', i);
    if (at == -1) break;
    final open = source.indexOf(RegExp(r'[{(]'), at);
    if (open == -1) break;
    final type = source.substring(at + 1, open).trim().toLowerCase();
    final end = _matchingClose(source, open);
    if (end == -1) break;
    i = end + 1;
    if (!RegExp(r'^[a-z]+$').hasMatch(type) ||
        const {'comment', 'string', 'preamble'}.contains(type)) {
      continue;
    }
    final body = source.substring(open + 1, end);
    final paper = _parseEntry(type, body);
    if (paper != null) papers.add(paper);
  }
  return papers;
}

int _matchingClose(String s, int open) {
  final close = s[open] == '{' ? '}' : ')';
  var depth = 0;
  var inQuotes = false;
  for (var j = open; j < s.length; j++) {
    final c = s[j];
    if (c == '"' && depth == 1 && s[j - 1] != '\\') inQuotes = !inQuotes;
    if (inQuotes) continue;
    if (c == s[open] || (c == '{' && s[open] == '(')) {
      depth++;
    } else if (c == close || (c == '}' && close == ')')) {
      depth--;
      if (depth == 0) return j;
    }
  }
  return -1;
}

Paper? _parseEntry(String type, String body) {
  final comma = body.indexOf(',');
  if (comma == -1) return null;
  final key = body.substring(0, comma).trim();
  final fields = <String, String>{};
  var j = comma + 1;
  final fieldName = RegExp(r'\s*([A-Za-z_-]+)\s*=\s*');
  while (j < body.length) {
    final m = fieldName.matchAsPrefix(body, j);
    if (m == null) {
      j++;
      continue;
    }
    final name = m[1]!.toLowerCase();
    j = m.end;
    final (value, next) = _readValue(body, j);
    fields[name] = value;
    j = next;
    // Skip to after the next comma
    while (j < body.length && body[j] != ',') {
      j++;
    }
    j++;
  }
  final title = cleanBibText(fields['title'] ?? '');
  if (key.isEmpty || title.isEmpty) return null;
  final date = fields['date'] ?? fields['year'];
  final yearMatch = date == null ? null : RegExp(r'\d{4}').firstMatch(date);
  String? clean(String? v) {
    if (v == null) return null;
    final c = cleanBibText(v);
    return c.isEmpty ? null : c;
  }

  return Paper(
    key: key,
    type: type,
    title: title,
    authors: parseAuthors(fields['author'] ?? fields['editor'] ?? ''),
    year: yearMatch?[0],
    venue: clean(
      fields['journaltitle'] ??
          fields['journal'] ??
          fields['booktitle'] ??
          fields['eventtitle'] ??
          fields['publisher'] ??
          fields['organization'] ??
          fields['howpublished'],
    ),
    doi: clean(fields['doi']),
    url: fields['url']?.trim().replaceAll(RegExp(r'^\{|\}$'), ''),
  );
}

/// Read a field value: {braced}, "quoted", or a bare word/number. Returns
/// the raw value (braces kept for cleanBibText) and the index after it.
(String, int) _readValue(String s, int j) {
  if (j >= s.length) return ('', j);
  if (s[j] == '{') {
    var depth = 0;
    for (var k = j; k < s.length; k++) {
      if (s[k] == '{') depth++;
      if (s[k] == '}') {
        depth--;
        if (depth == 0) return (s.substring(j + 1, k), k + 1);
      }
    }
    return (s.substring(j + 1), s.length);
  }
  if (s[j] == '"') {
    var depth = 0;
    for (var k = j + 1; k < s.length; k++) {
      if (s[k] == '{') depth++;
      if (s[k] == '}') depth--;
      if (s[k] == '"' && depth == 0 && s[k - 1] != '\\') {
        return (s.substring(j + 1, k), k + 1);
      }
    }
    return (s.substring(j + 1), s.length);
  }
  final m = RegExp(r'[^,\s]+').matchAsPrefix(s, j);
  return m == null ? ('', j) : (m[0]!, m.end);
}

// --- Search ----------------------------------------------------------------

class PaperMatch {
  PaperMatch(this.paper, this.score, this.titleHighlights);

  final Paper paper;
  final double score;
  final Set<int> titleHighlights;
}

/// Like citar: space-separated components in any order, matched against
/// title, authors, year, venue and citekey. An empty query lists newest first.
List<PaperMatch> searchPapers(List<Paper> papers, String query) {
  final terms = splitSearchQuery(query);
  if (terms.isEmpty) {
    final sorted = [...papers]
      ..sort((a, b) {
        final byYear = (b.year ?? '').compareTo(a.year ?? '');
        return byYear != 0 ? byYear : a.title.compareTo(b.title);
      });
    return [for (final p in sorted) PaperMatch(p, 0, const {})];
  }
  final results = <PaperMatch>[];
  for (final paper in papers) {
    final title = foldForSearch(paper.title);
    final fields = <(String, double, bool)>[
      (title, 1.0, true),
      for (final a in paper.authors) (foldForSearch(a), 0.85, false),
      if (paper.year != null) (paper.year!, 0.6, false),
      if (paper.venue != null) (foldForSearch(paper.venue!), 0.5, false),
      (foldForSearch(paper.key), 0.7, false),
    ];
    var total = 0.0;
    final highlights = <int>{};
    var all = true;
    for (final term in terms) {
      var best = 0.0;
      List<int>? bestPositions;
      var bestIsTitle = false;
      for (final (text, weight, isTitle) in fields) {
        final m = matchTerm(term, text, allowFlex: isTitle);
        if (m == null) continue;
        final score = m.score * weight;
        if (score > best) {
          best = score;
          bestPositions = m.positions;
          bestIsTitle = isTitle;
        }
      }
      if (bestPositions == null) {
        all = false;
        break;
      }
      total += best;
      if (bestIsTitle) highlights.addAll(bestPositions);
    }
    if (!all) continue;
    total -= min(paper.title.length, 120) * 0.05;
    results.add(PaperMatch(paper, total, highlights));
  }
  results.sort((a, b) => b.score.compareTo(a.score));
  return results;
}
