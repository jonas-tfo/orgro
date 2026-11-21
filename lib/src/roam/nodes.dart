// Org-roam style node index: every file or headline with an :ID: property is a
// node, like `org-roam-node-find` sees them.

/// An org file as read by the native directory scan
class OrgFileData {
  OrgFileData({
    required this.identifier,
    required this.uri,
    required this.fileName,
    required this.relativePath,
    required this.modified,
    required this.content,
  });

  factory OrgFileData.fromJson(Map<Object?, Object?> json) => OrgFileData(
    identifier: json['identifier'] as String,
    uri: json['uri'] as String,
    fileName: json['fileName'] as String,
    relativePath: json['relativePath'] as String? ?? '',
    modified: DateTime.fromMillisecondsSinceEpoch(
      (json['modified'] as num? ?? 0).round(),
    ),
    content: json['content'] as String? ?? '',
  );

  /// Persistent native identifier (bookmark) used to open the file
  final String identifier;
  final String uri;
  final String fileName;

  /// Path relative to the scanned root directory
  final String relativePath;
  final DateTime modified;
  final String content;

  late final List<String> lines = content.split(_newline);
}

final _newline = RegExp(r'\r?\n');

class RoamNode {
  RoamNode({
    required this.id,
    required this.title,
    required this.file,
    required this.fileTitle,
    this.level = 0,
    this.outline = const [],
    this.aliases = const [],
    this.tags = const [],
  });

  final String id;
  final String title;

  /// 0 for file-level nodes, otherwise the headline level
  final int level;

  /// Titles of ancestor headlines (excluding this node)
  final List<String> outline;
  final List<String> aliases;
  final List<String> tags;
  final OrgFileData file;
  final String fileTitle;

  bool get isFileNode => level == 0;

  /// Breadcrumb shown for headline nodes, like org-roam's olp display
  String get breadcrumb => [fileTitle, ...outline].join(' › ');

  @override
  String toString() => 'RoamNode($id, $title)';
}

// org-todo-keywords from the user's config plus Org defaults
const _todoKeywords = {'TODO', 'NEXT', 'WAIT', 'DONE', 'CANCELLED', 'CANCELED'};

final _headlinePattern = RegExp(r'^(\*+)\s+(.*)$');
final _propertyPattern = RegExp(r'^\s*:([A-Za-z_]+):\s*(.*?)\s*$');
final _keywordPattern = RegExp(r'^\s*#\+([A-Za-z_]+):\s*(.*?)\s*$');
final _tagsSuffixPattern = RegExp(r'\s+(:[^\s:]+(?::[^\s:]+)*:)\s*$');
final _priorityPattern = RegExp(r'^\[#[A-Za-z0-9]\]\s*');
final _cookiePattern = RegExp(r'\s*\[\d*(?:/\d*|%)\]');
final _linkPattern = RegExp(r'\[\[([^\]]*)\](?:\[([^\]]*)\])?\]');

/// Strip org link markup, keeping descriptions (or targets when there is no
/// description)
String _stripLinks(String text) =>
    text.replaceAllMapped(_linkPattern, (m) => m[2] ?? m[1] ?? '');

({String title, List<String> tags}) _parseHeadlineText(String text) {
  var rest = text;
  var tags = const <String>[];
  final tagMatch = _tagsSuffixPattern.firstMatch(rest);
  if (tagMatch != null) {
    tags = tagMatch[1]!.split(':').where((t) => t.isNotEmpty).toList();
    rest = rest.substring(0, tagMatch.start);
  }
  final firstSpace = rest.indexOf(' ');
  final firstWord = firstSpace == -1 ? rest : rest.substring(0, firstSpace);
  if (_todoKeywords.contains(firstWord)) {
    rest = firstSpace == -1 ? '' : rest.substring(firstSpace + 1);
  }
  rest = rest.replaceFirst(_priorityPattern, '');
  rest = rest.replaceAll(_cookiePattern, '');
  return (title: _stripLinks(rest).trim(), tags: tags);
}

List<String> _parseFileTags(String value) =>
    value.split(RegExp(r'[:\s]+')).where((t) => t.isNotEmpty).toList();

/// Split like Emacs' `split-string-and-unquote`, used for :ROAM_ALIASES:
List<String> parseAliases(String value) {
  final result = <String>[];
  final pattern = RegExp(r'"((?:[^"\\]|\\.)*)"|(\S+)');
  for (final m in pattern.allMatches(value)) {
    final quoted = m[1];
    result.add(
      quoted != null ? quoted.replaceAll(RegExp(r'\\(.)'), r'$1') : m[2]!,
    );
  }
  return result;
}

String _fileNameStem(String fileName) {
  final dot = fileName.lastIndexOf('.');
  return dot > 0 ? fileName.substring(0, dot) : fileName;
}

class _Entity {
  _Entity({required this.level, required this.title, required this.tags});

  final int level;
  final String title;
  final List<String> tags;
  String? id;
  List<String> aliases = const [];
  bool exclude = false;
}

/// Extract the nodes of a single file
List<RoamNode> parseRoamNodes(OrgFileData file) {
  String? fileTitle;
  var fileTags = const <String>[];
  final fileEntity = _Entity(level: 0, title: '', tags: const []);
  final headlines = <_Entity>[];
  final stack = <_Entity>[];
  final ancestry = <_Entity, List<_Entity>>{};

  _Entity current = fileEntity;
  for (final line in file.lines) {
    final headline = _headlinePattern.firstMatch(line);
    if (headline != null) {
      final level = headline[1]!.length;
      final parsed = _parseHeadlineText(headline[2]!);
      while (stack.isNotEmpty && stack.last.level >= level) {
        stack.removeLast();
      }
      final entity = _Entity(
        level: level,
        title: parsed.title,
        tags: parsed.tags,
      );
      ancestry[entity] = List.of(stack);
      stack.add(entity);
      headlines.add(entity);
      current = entity;
      continue;
    }
    final keyword = _keywordPattern.firstMatch(line);
    if (keyword != null) {
      // In-buffer settings apply to the file no matter where they appear
      switch (keyword[1]!.toUpperCase()) {
        case 'TITLE':
          fileTitle ??= _stripLinks(keyword[2]!).trim();
        case 'FILETAGS':
          fileTags = [...fileTags, ..._parseFileTags(keyword[2]!)];
      }
      continue;
    }
    final property = _propertyPattern.firstMatch(line);
    if (property != null) {
      final value = property[2]!;
      switch (property[1]!.toUpperCase()) {
        case 'ID':
          if (value.isNotEmpty) current.id ??= value;
        case 'ROAM_ALIASES':
          current.aliases = parseAliases(value);
        case 'ROAM_EXCLUDE':
          current.exclude = value.isNotEmpty && value != 'nil';
      }
    }
  }

  final resolvedFileTitle = fileTitle?.isNotEmpty == true
      ? fileTitle!
      : _fileNameStem(file.fileName);
  final nodes = <RoamNode>[];
  if (fileEntity.id != null && !fileEntity.exclude) {
    nodes.add(
      RoamNode(
        id: fileEntity.id!,
        title: resolvedFileTitle,
        file: file,
        fileTitle: resolvedFileTitle,
        aliases: fileEntity.aliases,
        tags: fileTags,
      ),
    );
  }
  for (final entity in headlines) {
    final id = entity.id;
    if (id == null || entity.exclude || entity.title.isEmpty) continue;
    final ancestors = ancestry[entity]!;
    // Excluding a headline excludes its descendants too
    if (ancestors.any((a) => a.exclude)) continue;
    nodes.add(
      RoamNode(
        id: id,
        title: entity.title,
        file: file,
        fileTitle: resolvedFileTitle,
        level: entity.level,
        outline: [for (final a in ancestors) a.title],
        aliases: entity.aliases,
        // org-use-tag-inheritance: file tags and ancestors' tags apply
        tags: {
          ...fileTags,
          for (final a in ancestors) ...a.tags,
          ...entity.tags,
        }.toList(),
      ),
    );
  }
  return nodes;
}

/// Build the node list for many files. When the same ID appears in several
/// files (e.g. sync conflict copies like "note 2.org"), the most recently
/// modified file wins.
List<RoamNode> buildRoamIndex(Iterable<OrgFileData> files) {
  final byId = <String, RoamNode>{};
  for (final file in files) {
    for (final node in parseRoamNodes(file)) {
      final existing = byId[node.id];
      if (existing == null ||
          node.file.modified.isAfter(existing.file.modified)) {
        byId[node.id] = node;
      }
    }
  }
  return byId.values.toList(growable: false);
}
