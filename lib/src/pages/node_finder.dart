import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';
import 'package:open_file/open_file.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/cache.dart';
import 'package:orgro/src/components/view_settings.dart';
import 'package:orgro/src/data_source.dart';
import 'package:orgro/src/debug.dart';
import 'package:orgro/src/file_picker.dart';
import 'package:orgro/src/navigation.dart';
import 'package:orgro/src/notes_settings.dart';
import 'package:orgro/src/papers/index.dart';
import 'package:orgro/src/papers/papers.dart';
import 'package:orgro/src/preferences.dart';
import 'package:orgro/src/roam/files.dart';
import 'package:orgro/src/roam/fuzzy.dart';
import 'package:orgro/src/roam/index.dart';
import 'package:orgro/src/roam/nodes.dart';
import 'package:orgro/src/roam/text_search.dart';
import 'package:orgro/theme.dart';
import 'package:url_launcher/url_launcher.dart';

enum FinderMode { nodes, text, files, papers }

/// Like `org-roam-node-find` (and, in text mode, `consult-ripgrep`): search
/// all notes in the folders Orgro has access to, and open the chosen result.
Future<void> showNodeFinder(
  BuildContext context, {
  FinderMode? mode,
  bool newTab = false,
}) async {
  final result = await Navigator.push<Object>(
    context,
    MaterialPageRoute(
      fullscreenDialog: true,
      builder: (context) => NodeFinderPage(initialMode: mode),
    ),
  );
  if (result == null || !context.mounted) return;
  if (result is _OpenInNewTab) {
    await openFinderResult(context, result.result, newTab: true);
  } else {
    await openFinderResult(context, result, newTab: newTab);
  }
}

/// Popped from the finder when a result is long-pressed
class _OpenInNewTab {
  const _OpenInNewTab(this.result);

  final Object result;
}

/// Open a [RoamNode] or [TextHit] chosen in the finder, or a [Paper] in the
/// browser
Future<void> openFinderResult(
  BuildContext context,
  Object result, {
  bool newTab = false,
}) async {
  if (result is FileEntry) {
    await _openFileEntry(context, result, newTab: newTab);
    return;
  }
  if (result is Paper) {
    final link = result.link;
    if (link != null) {
      await launchUrl(link, mode: LaunchMode.externalApplication);
    }
    return;
  }
  final (OrgFileData file, String? target) = switch (result) {
    RoamNode node => (node.file, node.isFileNode ? null : 'id:${node.id}'),
    // A regexp search option lands on the hit, with matches highlighted
    TextHit hit => (hit.file, '/${RegExp.escape(hit.jumpText)}/'),
    _ => throw ArgumentError.value(result, 'result'),
  };
  final dataSource = NativeDataSource(
    file.fileName,
    file.identifier,
    file.uri,
    persistable: true,
  );
  await loadDocument(context, dataSource, target: target, newTab: newTab);
}

/// Org files open in Orgro; anything else in the app iOS picks for it
Future<void> _openFileEntry(
  BuildContext context,
  FileEntry entry, {
  required bool newTab,
}) async {
  try {
    final source = await entry.resolve();
    if (source == null) throw Exception('Couldn’t open ${entry.relativePath}');
    if (!context.mounted) return;
    if (entry.isOrg) {
      await loadDocument(context, source, newTab: newTab);
      return;
    }
    final tmp = await getTemporaryAttachmentsDirectory();
    final tmpFile = tmp.uri.resolveUri(
      Uri(path: '${source.id.hashCode}/${source.name}'),
    );
    await File.fromUri(tmpFile).parent.create(recursive: true);
    await source.copyTo(tmpFile);
    final result = await OpenFile.open(tmpFile.toFilePath());
    if (result.type != ResultType.done && context.mounted) {
      showErrorSnackBar(context, result.message);
    }
  } catch (e, s) {
    logError(e, s);
    if (context.mounted) showErrorSnackBar(context, e);
  }
}

class NodeFinderPage extends StatefulWidget {
  const NodeFinderPage({this.initialMode, super.key});

  final FinderMode? initialMode;

  @override
  State<NodeFinderPage> createState() => _NodeFinderPageState();
}

class _NodeFinderPageState extends State<NodeFinderPage> {
  // Remember the last mode while the app runs
  static var _lastMode = FinderMode.nodes;

  final _query = TextEditingController();
  final _index = RoamNodeIndex.instance;
  final _papers = PapersIndex.instance;
  final _files = FileIndex.instance;
  final _settings = NotesSettings.instance;
  List<String> _accessible = const [];
  List<String> _dirs = const [];
  late FinderMode _mode = widget.initialMode ?? _lastMode;

  void _setMode(FinderMode mode) {
    setState(() => _mode = _lastMode = mode);
    if (mode == FinderMode.papers) _refreshPapers();
    if (mode == FinderMode.files) _refreshFiles();
  }

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onSettingsChanged);
    _settings.ensureLoaded().then((_) {
      if (mounted) _onSettingsChanged();
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accessible = Preferences.of(
      context,
      PrefsAspect.accessibleDirs,
    ).accessibleDirs;
    if (_settings.isLoaded) _onSettingsChanged();
  }

  void _onSettingsChanged() {
    final dirs = _settings.searchDirs(_accessible);
    if (!listEquals(dirs, _dirs)) {
      setState(() => _dirs = dirs);
      if (dirs.isNotEmpty) _index.refresh(dirs).onError(_onError);
    }
    if (_mode == FinderMode.papers) _refreshPapers();
    if (_mode == FinderMode.files) _refreshFiles();
  }

  /// Every granted folder, plus the notes folder: files outside the notes
  /// folder are the point of this tab
  void _refreshFiles() {
    final dirs = {?_settings.dirIdentifier, ..._accessible}.toList();
    if (dirs.isEmpty) return;
    _files.refresh(dirs).onError(_onError);
  }

  void _refreshPapers() {
    // The notes folder first, then every other granted folder
    final dirs = {
      ?_settings.effectiveDir(_accessible),
      ..._accessible,
    }.toList();
    if (dirs.isEmpty) return;
    _papers
        .refresh(dirIdentifiers: dirs, relativePath: _settings.bibliographyPath)
        .onError(_onError);
  }

  void _onError(Object e, StackTrace s) {
    logError(e, s);
    if (mounted) showErrorSnackBar(context, e);
  }

  @override
  void dispose() {
    _settings.removeListener(_onSettingsChanged);
    _query.dispose();
    super.dispose();
  }

  Future<void> _grantAccess() async {
    try {
      final dir = await pickDirectory();
      if (dir == null || !mounted) return;
      await Preferences.of(
        context,
        PrefsAspect.nil,
      ).addAccessibleDir(dir.identifier);
    } catch (e, s) {
      _onError(e, s);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textStyle = ViewSettingsData.defaults(context).textStyle;
    return Scaffold(
      appBar: AppBar(
        titleSpacing: 0,
        title: TextField(
          controller: _query,
          autofocus: true,
          autocorrect: false,
          enableSuggestions: false,
          textInputAction: TextInputAction.go,
          style: textStyle.copyWith(color: Horizon.fgAlt),
          cursorColor: Horizon.red,
          decoration: InputDecoration(
            hintText: switch (_mode) {
              FinderMode.nodes => l10n.findNodeHint,
              FinderMode.text => l10n.findTextHint,
              FinderMode.files => l10n.findFileHint,
              FinderMode.papers => l10n.findPaperHint,
            },
            hintStyle: textStyle.copyWith(color: Horizon.comments),
            border: InputBorder.none,
          ),
          onChanged: (_) => setState(() {}),
          onSubmitted: (_) {
            final first = _firstResult();
            if (first != null) Navigator.pop(context, first);
          },
        ),
        actions: [
          if (_query.text.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.clear),
              onPressed: () => setState(_query.clear),
            ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(38),
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
                child: Row(
                  spacing: 8,
                  children: [
                    for (final (mode, label) in [
                      (FinderMode.nodes, l10n.finderModeNodes),
                      (FinderMode.text, l10n.finderModeText),
                      (FinderMode.files, l10n.finderModeFiles),
                      (FinderMode.papers, l10n.finderModePapers),
                    ])
                      ChoiceChip(
                        label: Text(label),
                        selected: _mode == mode,
                        onSelected: (_) => _setMode(mode),
                        visualDensity: VisualDensity.compact,
                        selectedColor: Horizon.highlightSelected,
                        backgroundColor: Horizon.bgAlt,
                        side: BorderSide.none,
                        showCheckmark: false,
                        labelStyle: TextStyle(
                          color: _mode == mode ? Horizon.fgAlt : Horizon.base4,
                        ),
                      ),
                  ],
                ),
              ),
              ValueListenableBuilder<bool>(
                valueListenable: switch (_mode) {
                  FinderMode.papers => _papers.loading,
                  FinderMode.files => _files.loading,
                  _ => _index.loading,
                },
                builder: (context, loading, _) => loading
                    ? const LinearProgressIndicator(
                        minHeight: 2,
                        color: Horizon.blue,
                        backgroundColor: Colors.transparent,
                      )
                    : const SizedBox(height: 2),
              ),
            ],
          ),
        ),
      ),
      body: _dirs.isEmpty
          ? _NoAccess(onGrant: _grantAccess)
          : switch (_mode) {
              FinderMode.nodes => ValueListenableBuilder<List<RoamNode>?>(
                valueListenable: _index.nodes,
                builder: (context, nodes, _) {
                  if (nodes == null) return const SizedBox.shrink();
                  final results = searchRoamNodes(nodes, _query.text);
                  return _ResultList(
                    results: results,
                    total: nodes.length,
                    textStyle: textStyle,
                  );
                },
              ),
              FinderMode.text => ValueListenableBuilder<List<OrgFileData>?>(
                valueListenable: _index.files,
                builder: (context, files, _) {
                  if (files == null) return const SizedBox.shrink();
                  return _TextResultList(
                    result: searchText(files, _query.text),
                    queryTooShort:
                        _query.text.trim().length < kTextSearchMinQueryLength,
                    textStyle: textStyle,
                  );
                },
              ),
              FinderMode.files => ValueListenableBuilder<List<FileEntry>?>(
                valueListenable: _files.files,
                builder: (context, files, _) {
                  if (files == null) return const SizedBox.shrink();
                  return _FileResultList(
                    results: searchFiles(files, _query.text),
                    total: files.length,
                    textStyle: textStyle,
                  );
                },
              ),
              FinderMode.papers => ValueListenableBuilder<List<Paper>?>(
                valueListenable: _papers.papers,
                builder: (context, papers, _) {
                  if (papers == null) return const SizedBox.shrink();
                  return _PaperResultList(
                    results: searchPapers(papers, _query.text),
                    total: papers.length,
                    error: _papers.error.value,
                    noteFor: _noteFor,
                    textStyle: textStyle,
                  );
                },
              ),
            },
    );
  }

  /// The citar-org-roam note for a paper (`references/<citekey>.org`), if any
  RoamNode? _noteFor(Paper paper) {
    final name = '${paper.key}.org';
    for (final node in _index.nodes.value ?? const <RoamNode>[]) {
      if (node.isFileNode && node.file.fileName == name) return node;
    }
    return null;
  }

  Object? _firstResult() => switch (_mode) {
    FinderMode.nodes => switch (_index.nodes.value) {
      null => null,
      final nodes => searchRoamNodes(nodes, _query.text).firstOrNull?.node,
    },
    FinderMode.text => switch (_index.files.value) {
      null => null,
      final files => searchText(files, _query.text).hits.firstOrNull,
    },
    FinderMode.files => switch (_files.files.value) {
      null => null,
      final files => searchFiles(files, _query.text).firstOrNull?.file,
    },
    FinderMode.papers => switch (_papers.papers.value) {
      null => null,
      final papers => searchPapers(papers, _query.text).firstOrNull?.paper,
    },
  };
}

class _ResultList extends StatelessWidget {
  const _ResultList({
    required this.results,
    required this.total,
    required this.textStyle,
  });

  final List<RoamMatch> results;
  final int total;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final small = textStyle.copyWith(
      fontSize: (textStyle.fontSize ?? 14) * 0.8,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // Like vertico's candidate count in the minibuffer prompt
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(
            '${results.length}/$total',
            style: small.copyWith(color: Horizon.comments),
          ),
        ),
        Expanded(
          child: results.isEmpty
              ? Center(
                  child: Text(
                    AppLocalizations.of(context)!.findNodeNoResults,
                    style: small.copyWith(color: Horizon.base4),
                  ),
                )
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: results.length,
                  itemBuilder: (context, i) => _NodeTile(
                    match: results[i],
                    textStyle: textStyle,
                    smallStyle: small,
                    selected: i == 0,
                  ),
                ),
        ),
      ],
    );
  }
}

class _NodeTile extends StatelessWidget {
  const _NodeTile({
    required this.match,
    required this.textStyle,
    required this.smallStyle,
    required this.selected,
  });

  final RoamMatch match;
  final TextStyle textStyle;
  final TextStyle smallStyle;

  /// The first candidate is what the keyboard's Go key opens
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final node = match.node;
    final secondary = [
      if (!node.isFileNode) node.breadcrumb,
      if (node.aliases.isNotEmpty) node.aliases.join(', '),
    ].join('  ·  ');
    return InkWell(
      onTap: () => Navigator.pop(context, node),
      onLongPress: () => Navigator.pop(context, _OpenInNewTab(node)),
      child: Container(
        color: selected ? Horizon.highlight : null,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(
                children: [
                  ..._highlighted(node.title, match.titleHighlights),
                  for (final tag in node.tags)
                    TextSpan(
                      text: '  #$tag',
                      style: smallStyle.copyWith(color: Horizon.yellow),
                    ),
                ],
              ),
              style: textStyle.copyWith(
                color: node.isFileNode ? Horizon.fg : Horizon.teal,
              ),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
            ),
            if (secondary.isNotEmpty)
              Text(
                secondary,
                style: smallStyle.copyWith(color: Horizon.base4),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
          ],
        ),
      ),
    );
  }
}

Iterable<TextSpan> _highlighted(String text, Set<int> highlights) sync* {
  if (highlights.isEmpty) {
    yield TextSpan(text: text);
    return;
  }
  // Group consecutive runs to keep the span count low
  var start = 0;
  while (start < text.length) {
    final hl = highlights.contains(start);
    var end = start + 1;
    while (end < text.length && highlights.contains(end) == hl) {
      end++;
    }
    yield TextSpan(
      text: text.substring(start, end),
      style: hl
          ? const TextStyle(color: Horizon.red, fontWeight: FontWeight.bold)
          : null,
    );
    start = end;
  }
}

class _NoAccess extends StatelessWidget {
  const _NoAccess({required this.onGrant});

  final VoidCallback onGrant;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          spacing: 16,
          children: [
            Text(l10n.findNodeNeedsDirectory, textAlign: TextAlign.center),
            FilledButton(
              onPressed: onGrant,
              child: Text(l10n.snackbarActionGrantAccess),
            ),
          ],
        ),
      ),
    );
  }
}

class _TextResultList extends StatelessWidget {
  const _TextResultList({
    required this.result,
    required this.queryTooShort,
    required this.textStyle,
  });

  final TextSearchResult result;
  final bool queryTooShort;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final small = textStyle.copyWith(
      fontSize: (textStyle.fontSize ?? 14) * 0.8,
    );
    final hits = result.hits;
    if (queryTooShort) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(
            result.truncated ? '${hits.length}+' : '${hits.length}',
            style: small.copyWith(color: Horizon.comments),
          ),
        ),
        Expanded(
          child: hits.isEmpty
              ? Center(
                  child: Text(
                    l10n.findNodeNoResults,
                    style: small.copyWith(color: Horizon.base4),
                  ),
                )
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: hits.length,
                  itemBuilder: (context, i) {
                    final hit = hits[i];
                    // Group header when the file changes
                    final newFile = i == 0 || hits[i - 1].file != hit.file;
                    return Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        if (newFile)
                          Container(
                            color: Horizon.bgAlt,
                            padding: const EdgeInsets.fromLTRB(16, 6, 16, 4),
                            child: Text(
                              hit.fileTitle,
                              style: small.copyWith(
                                color: Horizon.blue,
                                fontWeight: FontWeight.bold,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        _TextHitTile(
                          hit: hit,
                          textStyle: textStyle,
                          smallStyle: small,
                          selected: i == 0,
                        ),
                      ],
                    );
                  },
                ),
        ),
      ],
    );
  }
}

class _TextHitTile extends StatelessWidget {
  const _TextHitTile({
    required this.hit,
    required this.textStyle,
    required this.smallStyle,
    required this.selected,
  });

  final TextHit hit;
  final TextStyle textStyle;
  final TextStyle smallStyle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: () => Navigator.pop(context, hit),
      onLongPress: () => Navigator.pop(context, _OpenInNewTab(hit)),
      child: Container(
        color: selected ? Horizon.highlight : null,
        padding: const EdgeInsets.fromLTRB(16, 6, 16, 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text.rich(
              TextSpan(children: [..._highlighted(hit.line, hit.highlights)]),
              style: textStyle.copyWith(color: Horizon.fg),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            Text(
              [
                if (hit.heading != null) hit.heading!,
                ':${hit.lineNumber}',
              ].join('  '),
              style: smallStyle.copyWith(color: Horizon.base4),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ],
        ),
      ),
    );
  }
}

class _PaperResultList extends StatelessWidget {
  const _PaperResultList({
    required this.results,
    required this.total,
    required this.error,
    required this.noteFor,
    required this.textStyle,
  });

  final List<PaperMatch> results;
  final int total;
  final String? error;
  final RoamNode? Function(Paper) noteFor;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final small = textStyle.copyWith(
      fontSize: (textStyle.fontSize ?? 14) * 0.8,
    );
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            l10n.findPaperLoadError(error!),
            textAlign: TextAlign.center,
            style: small.copyWith(color: Horizon.red),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(
            '${results.length}/$total',
            style: small.copyWith(color: Horizon.comments),
          ),
        ),
        Expanded(
          child: results.isEmpty
              ? Center(
                  child: Text(
                    l10n.findNodeNoResults,
                    style: small.copyWith(color: Horizon.base4),
                  ),
                )
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: results.length,
                  itemBuilder: (context, i) => _PaperTile(
                    match: results[i],
                    note: noteFor(results[i].paper),
                    textStyle: textStyle,
                    smallStyle: small,
                    selected: i == 0,
                  ),
                ),
        ),
      ],
    );
  }
}

class _PaperTile extends StatelessWidget {
  const _PaperTile({
    required this.match,
    required this.note,
    required this.textStyle,
    required this.smallStyle,
    required this.selected,
  });

  final PaperMatch match;
  final RoamNode? note;
  final TextStyle textStyle;
  final TextStyle smallStyle;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    final paper = match.paper;
    final hasLink = paper.link != null;
    final meta = [
      if (paper.authorsShort.isNotEmpty) paper.authorsShort,
      ?paper.year,
      ?paper.venue,
    ].join(' · ');
    return InkWell(
      onTap: hasLink ? () => Navigator.pop(context, paper) : null,
      child: Container(
        color: selected ? Horizon.highlight : null,
        padding: const EdgeInsets.fromLTRB(16, 7, 4, 7),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text.rich(
                    TextSpan(
                      children: [
                        ..._highlighted(paper.title, match.titleHighlights),
                      ],
                    ),
                    style: textStyle.copyWith(
                      color: hasLink ? Horizon.fg : Horizon.base4,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                  if (meta.isNotEmpty)
                    Text(
                      meta,
                      style: smallStyle.copyWith(color: Horizon.base4),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  Text(
                    paper.doi != null
                        ? 'doi:${cleanDoi(paper.doi!)}'
                        : (paper.url ?? paper.key),
                    style: smallStyle.copyWith(color: Horizon.yellow),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            if (note != null)
              IconButton(
                tooltip: AppLocalizations.of(context)!.findPaperOpenNote,
                color: Horizon.teal,
                icon: const Icon(Icons.description_outlined),
                onPressed: () => Navigator.pop(context, note),
              ),
          ],
        ),
      ),
    );
  }
}

class _FileResultList extends StatelessWidget {
  const _FileResultList({
    required this.results,
    required this.total,
    required this.textStyle,
  });

  final List<FileMatch> results;
  final int total;
  final TextStyle textStyle;

  @override
  Widget build(BuildContext context) {
    final small = textStyle.copyWith(
      fontSize: (textStyle.fontSize ?? 14) * 0.8,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 6, 16, 2),
          child: Text(
            '${results.length}/$total',
            style: small.copyWith(color: Horizon.comments),
          ),
        ),
        Expanded(
          child: results.isEmpty
              ? Center(
                  child: Text(
                    AppLocalizations.of(context)!.findNodeNoResults,
                    style: small.copyWith(color: Horizon.base4),
                  ),
                )
              : ListView.builder(
                  keyboardDismissBehavior:
                      ScrollViewKeyboardDismissBehavior.onDrag,
                  itemCount: results.length,
                  itemBuilder: (context, i) {
                    final match = results[i];
                    final file = match.file;
                    return InkWell(
                      onTap: () => Navigator.pop(context, file),
                      onLongPress: file.isOrg
                          ? () => Navigator.pop(context, _OpenInNewTab(file))
                          : null,
                      child: Container(
                        color: i == 0 ? Horizon.highlight : null,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 7,
                        ),
                        child: Row(
                          spacing: 12,
                          children: [
                            Icon(
                              _iconFor(file),
                              size: 20,
                              color: file.isOrg ? Horizon.blue : Horizon.base4,
                            ),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text.rich(
                                    TextSpan(
                                      children: [
                                        ..._highlighted(
                                          file.fileName,
                                          match.nameHighlights,
                                        ),
                                      ],
                                    ),
                                    style: textStyle.copyWith(
                                      color: Horizon.fg,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                  Text(
                                    file.folder,
                                    style: small.copyWith(color: Horizon.base4),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
        ),
      ],
    );
  }

  IconData _iconFor(FileEntry file) => switch (file.extension) {
    'org' => Icons.description_outlined,
    'png' ||
    'jpg' ||
    'jpeg' ||
    'gif' ||
    'webp' ||
    'heic' ||
    'svg' => Icons.image_outlined,
    'pdf' => Icons.picture_as_pdf_outlined,
    _ => Icons.insert_drive_file_outlined,
  };
}
