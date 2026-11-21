// Full-text search across all notes, like `consult-ripgrep` with orderless:
// the query is split on spaces and a line matches when it contains every
// component (in any order). Matching ignores case and diacritics.

import 'package:orgro/src/roam/fuzzy.dart';
import 'package:orgro/src/roam/nodes.dart';

class TextHit {
  TextHit({
    required this.file,
    required this.fileTitle,
    required this.lineNumber,
    required this.line,
    required this.highlights,
    required this.heading,
    required this.jumpText,
  });

  final OrgFileData file;
  final String fileTitle;

  /// 1-based
  final int lineNumber;

  /// The matching line, trimmed
  final String line;

  /// Indices into [line] that matched
  final Set<int> highlights;

  /// Nearest headline above the hit, if any
  final String? heading;

  /// Text to search for after opening the file so the view lands on this hit:
  /// a markup-free stretch of the line around the first match
  final String jumpText;
}

class TextSearchResult {
  TextSearchResult(this.hits, {required this.truncated});

  final List<TextHit> hits;

  /// True if there were more hits than the limit
  final bool truncated;
}

const kTextSearchMinQueryLength = 2;

// Folding every line on every keystroke is wasteful; cache per file
final _foldedLines = Expando<List<String>>();

List<String> _folded(OrgFileData file) =>
    _foldedLines[file] ??= file.lines.map(foldForSearch).toList();

final _propertyLine = RegExp(r'^\s*:[A-Za-z_]+:(\s|$)');
final _headline = RegExp(r'^\*+\s+(.*)$');
final _titleKeyword = RegExp(r'^\s*#\+title:\s*(.*)$', caseSensitive: false);

// Characters that are (or may be) Org markup; the in-document search runs on
// rendered text, so the jump text must avoid them
final _markupChars = RegExp(r'[*/_=~+\[\]$\\{}<>|#]');

String _fileTitle(OrgFileData file) {
  for (final line in file.lines) {
    final m = _titleKeyword.firstMatch(line);
    if (m != null && m[1]!.trim().isNotEmpty) return m[1]!.trim();
  }
  final dot = file.fileName.lastIndexOf('.');
  return dot > 0 ? file.fileName.substring(0, dot) : file.fileName;
}

/// Pick the longest markup-free stretch of [line] around [start]..[end],
/// capped at [maxLength] characters
String jumpTextFor(String line, int start, int end, {int maxLength = 40}) {
  var from = start;
  var to = end;
  bool plain(int i) => !_markupChars.hasMatch(line[i]);
  // The match itself must be plain, otherwise fall back to the match only
  for (var i = start; i < end; i++) {
    if (!plain(i)) return line.substring(start, end);
  }
  while (to - from < maxLength) {
    final canLeft = from > 0 && plain(from - 1);
    final canRight = to < line.length && plain(to);
    if (!canLeft && !canRight) break;
    if (canRight) to++;
    if (canLeft && to - from < maxLength) from--;
  }
  // Don't cut words in half at the edges
  if (from > 0 && from < start) {
    final space = line.indexOf(' ', from);
    if (space != -1 && space < start) from = space + 1;
  }
  if (to < line.length && to > end) {
    final space = line.lastIndexOf(' ', to - 1);
    if (space >= end) to = space;
  }
  return line.substring(from, to).trim();
}

TextSearchResult searchText(
  List<OrgFileData> files,
  String query, {
  int limit = 300,
}) {
  final terms = query
      .trim()
      .split(RegExp(r'\s+'))
      .where((t) => t.isNotEmpty)
      .map(foldForSearch)
      .toList();
  if (terms.join().length < kTextSearchMinQueryLength) {
    return TextSearchResult(const [], truncated: false);
  }

  // Most recently edited notes first
  final sorted = [...files]..sort((a, b) => b.modified.compareTo(a.modified));
  final hits = <TextHit>[];
  for (final file in sorted) {
    String? title;
    String? heading;
    final lines = file.lines;
    final foldedLines = _folded(file);
    for (var i = 0; i < lines.length; i++) {
      final raw = lines[i];
      final headline = _headline.firstMatch(raw);
      if (headline != null) heading = headline[1]!.trim();
      if (_propertyLine.hasMatch(raw)) continue;
      final folded = foldedLines[i];
      final positions = <int>{};
      int? firstStart;
      int? firstEnd;
      var all = true;
      for (final term in terms) {
        final idx = folded.indexOf(term);
        if (idx == -1) {
          all = false;
          break;
        }
        if (firstStart == null) {
          firstStart = idx;
          firstEnd = idx + term.length;
        }
        // Highlight every occurrence
        for (var j = idx; j != -1; j = folded.indexOf(term, j + term.length)) {
          for (var k = j; k < j + term.length; k++) {
            positions.add(k);
          }
        }
      }
      if (!all) continue;
      if (hits.length >= limit) {
        return TextSearchResult(hits, truncated: true);
      }
      final leading = raw.length - raw.trimLeft().length;
      final line = raw.trim();
      hits.add(
        TextHit(
          file: file,
          fileTitle: title ??= _fileTitle(file),
          lineNumber: i + 1,
          line: line,
          highlights: {
            for (final p in positions)
              if (p - leading >= 0 && p - leading < line.length) p - leading,
          },
          heading: headline != null ? null : heading,
          jumpText: jumpTextFor(raw, firstStart!, firstEnd!),
        ),
      );
    }
  }
  return TextSearchResult(hits, truncated: false);
}
