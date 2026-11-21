// Orderless-style matching for org-roam nodes: the query is split on spaces and
// every component has to match somewhere (title, aliases, tags or outline), in
// any order. Each component matches literally if possible, otherwise as an
// initialism/word-prefix sequence against titles and aliases, so
// abbreviations are quick to type on a phone. Components starting with # only
// match tags.

import 'dart:math';

import 'package:orgro/src/roam/nodes.dart';

class RoamMatch {
  RoamMatch(this.node, this.score, this.titleHighlights);

  final RoamNode node;
  final double score;

  /// Indices into [RoamNode.title] that matched the query
  final Set<int> titleHighlights;
}

const _foldMap = {
  'à': 'a', 'á': 'a', 'â': 'a', 'ã': 'a', 'ä': 'a', 'å': 'a', 'æ': 'a', //
  'ç': 'c', 'è': 'e', 'é': 'e', 'ê': 'e', 'ë': 'e', 'ì': 'i', 'í': 'i', //
  'î': 'i', 'ï': 'i', 'ñ': 'n', 'ò': 'o', 'ó': 'o', 'ô': 'o', 'õ': 'o', //
  'ö': 'o', 'ø': 'o', 'ù': 'u', 'ú': 'u', 'û': 'u', 'ü': 'u', 'ý': 'y', //
  'ÿ': 'y', 'ß': 's',
};

/// Lowercase and strip diacritics while keeping a 1:1 index mapping with the
/// original string (needed for highlighting), so ß folds to a single "s".
String foldForSearch(String text) {
  final lower = text.toLowerCase();
  if (lower.length != text.length) return lower; // Rare; skip folding
  final buf = StringBuffer();
  for (var i = 0; i < lower.length; i++) {
    final c = lower[i];
    buf.write(_foldMap[c] ?? c);
  }
  return buf.toString();
}

class _Field {
  _Field(
    this.text,
    this.weight, {
    this.isTitle = false,
    this.isAlias = false,
    this.isTag = false,
  }) : folded = foldForSearch(text);

  final String text;
  final String folded;
  final double weight;
  final bool isTitle;
  final bool isAlias;
  final bool isTag;
}

class _TermMatch {
  _TermMatch(this.score, this.positions);

  final double score;
  final List<int> positions;
}

bool _isBoundary(String s, int i) {
  if (i == 0) return true;
  final prev = s.codeUnitAt(i - 1);
  // Not a letter or digit
  return !((prev >= 0x30 && prev <= 0x39) ||
      (prev >= 0x61 && prev <= 0x7a) ||
      prev > 0x7f);
}

_TermMatch? _matchLiteral(String term, String haystack) {
  var best = -1.0;
  var bestIdx = -1;
  var idx = haystack.indexOf(term);
  while (idx != -1) {
    var score = 100.0;
    if (idx == 0) {
      score += 60;
    } else if (_isBoundary(haystack, idx)) {
      score += 35;
    }
    score -= min(idx, 30) * 0.5;
    if (term.length == haystack.length) score += 40;
    if (score > best) {
      best = score;
      bestIdx = idx;
    }
    idx = haystack.indexOf(term, idx + 1);
  }
  if (bestIdx == -1) return null;
  return _TermMatch(best, [for (var i = 0; i < term.length; i++) bestIdx + i]);
}

/// Initialism/prefix matching: every query character must either start a word
/// or directly follow the previous matched character, so "kmp" finds
/// "Knuth-Morris-Pratt" and "kmpalg" finds "Knuth-Morris-Pratt Algorithmus",
/// but scattered letters across a word don't count.
_TermMatch? _matchFlex(String term, String haystack) {
  if (term.length < 2) return null;
  final positions = List<int>.filled(term.length, -1);

  bool search(int ti, int from) {
    if (ti == term.length) return true;
    final c = term[ti];
    // Prefer continuing the current word
    if (ti > 0 && from < haystack.length && haystack[from] == c) {
      positions[ti] = from;
      if (search(ti + 1, from + 1)) return true;
    }
    for (var i = from; i < haystack.length; i++) {
      if (haystack[i] != c || !_isBoundary(haystack, i)) continue;
      if (ti > 0 && i == from) continue; // Already tried as continuation
      positions[ti] = i;
      if (search(ti + 1, i + 1)) return true;
    }
    return false;
  }

  if (!search(0, 0)) return null;
  var score = 45.0;
  var words = 1;
  for (var i = 1; i < positions.length; i++) {
    if (positions[i] != positions[i - 1] + 1) words++;
  }
  // Fewer word jumps is a tighter match
  score -= words * 3;
  score -= min(positions.first, 20) * 0.5;
  return _TermMatch(score, positions);
}

/// Score of one query component against an already folded haystack, with the
/// matched positions; null if it doesn't match. [allowFlex] enables
/// initialism/word-prefix matching.
({double score, List<int> positions})? matchTerm(
  String term,
  String foldedHaystack, {
  bool allowFlex = false,
}) {
  final m =
      _matchLiteral(term, foldedHaystack) ??
      (allowFlex ? _matchFlex(term, foldedHaystack) : null);
  return m == null ? null : (score: m.score, positions: m.positions);
}

/// Query components, folded for matching
List<String> splitSearchQuery(String query) =>
    _splitQuery(query).map(foldForSearch).toList();

List<_Field> _fieldsFor(RoamNode node) => [
  _Field(node.title, 1.0, isTitle: true),
  for (final alias in node.aliases) _Field(alias, 0.9, isAlias: true),
  for (final tag in node.tags) _Field(tag, 0.6, isTag: true),
  if (!node.isFileNode) _Field(node.breadcrumb, 0.45),
];

List<String> _splitQuery(String query) =>
    query.trim().split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

/// Return nodes matching [query], best first. An empty query lists all nodes,
/// most recently modified file first.
List<RoamMatch> searchRoamNodes(List<RoamNode> nodes, String query) {
  final terms = _splitQuery(query).map(foldForSearch).toList();
  if (terms.isEmpty) {
    final sorted = [...nodes]
      ..sort((a, b) {
        final byDate = b.file.modified.compareTo(a.file.modified);
        if (byDate != 0) return byDate;
        if (a.isFileNode != b.isFileNode) return a.isFileNode ? -1 : 1;
        return a.title.compareTo(b.title);
      });
    return [for (final n in sorted) RoamMatch(n, 0, const {})];
  }

  final results = <RoamMatch>[];
  for (final node in nodes) {
    final fields = _fieldsFor(node);
    var total = 0.0;
    final highlights = <int>{};
    var matchedAll = true;
    for (final rawTerm in terms) {
      final tagOnly = rawTerm.startsWith('#') && rawTerm.length > 1;
      final term = tagOnly ? rawTerm.substring(1) : rawTerm;
      _TermMatch? best;
      _Field? bestField;
      var bestScore = 0.0;
      for (final field in fields) {
        if (tagOnly && !field.isTag) continue;
        final m =
            _matchLiteral(term, field.folded) ??
            (field.isTitle || field.isAlias
                ? _matchFlex(term, field.folded)
                : null);
        if (m == null) continue;
        final weighted = m.score * field.weight;
        if (weighted > bestScore) {
          bestScore = weighted;
          best = m;
          bestField = field;
        }
      }
      if (best == null) {
        matchedAll = false;
        break;
      }
      total += bestScore;
      if (bestField!.isTitle) highlights.addAll(best.positions);
    }
    if (!matchedAll) continue;
    // Prefer file nodes and shorter titles, like vertico's length sorting
    if (node.isFileNode) total += 5;
    total -= min(node.title.length, 60) * 0.1;
    results.add(RoamMatch(node, total, highlights));
  }
  results.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    if (byScore != 0) return byScore;
    return b.node.file.modified.compareTo(a.node.file.modified);
  });
  return results;
}
