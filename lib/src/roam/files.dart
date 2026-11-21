// Find any file (not just org notes) in the folders Orgro has access to.

import 'dart:math';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:orgro/src/data_source.dart';
import 'package:orgro/src/debug.dart';
import 'package:orgro/src/roam/fuzzy.dart';

const _channel = MethodChannel('com.madlonkay.orgro/native_search');

class FileEntry {
  FileEntry({
    required this.dirIdentifier,
    required this.rootName,
    required this.relativePath,
    required this.fileName,
    required this.modified,
  });

  /// The granted folder the file is in
  final String dirIdentifier;

  /// That folder's name, shown as the start of the path
  final String rootName;

  final String relativePath;
  final String fileName;
  final DateTime modified;

  bool get isOrg => fileName.toLowerCase().endsWith('.org');

  String get extension {
    final dot = fileName.lastIndexOf('.');
    return dot > 0 ? fileName.substring(dot + 1).toLowerCase() : '';
  }

  /// Folder part of the path, e.g. "notes/5Semester/algobioII"
  String get folder {
    final slash = relativePath.lastIndexOf('/');
    return slash == -1
        ? rootName
        : '$rootName/${relativePath.substring(0, slash)}';
  }

  /// Read access to the file, resolved from its granted folder
  Future<NativeDataSource?> resolve() async {
    final result = await _channel.invokeMapMethod<String, String>(
      'resolveInRoot',
      {
        'rootIdentifier': dirIdentifier,
        'fileUri': '',
        'path': relativePath,
        'fromRoot': true,
      },
    );
    if (result == null) return null;
    final info = FileInfo.fromJson(result);
    return NativeDataSource(
      info.fileName ?? fileName,
      info.identifier,
      info.uri,
      persistable: info.persistable,
    );
  }

  @override
  String toString() => 'FileEntry($rootName/$relativePath)';
}

Future<List<FileEntry>> listFiles(String dirIdentifier) async {
  final result = await _channel.invokeMapMethod<String, Object?>('listFiles', {
    'dirIdentifier': dirIdentifier,
  });
  if (result == null) return const [];
  final rootName = result['rootName'] as String? ?? '';
  final files = (result['files'] as List<Object?>? ?? const [])
      .cast<Map<Object?, Object?>>();
  return [
    for (final f in files)
      FileEntry(
        dirIdentifier: dirIdentifier,
        rootName: rootName,
        relativePath: f['relativePath'] as String,
        fileName: f['fileName'] as String,
        modified: DateTime.fromMillisecondsSinceEpoch(
          (f['modified'] as num? ?? 0).round(),
        ),
      ),
  ];
}

/// All files in the given folders, cached while the app runs
class FileIndex {
  FileIndex._();

  static final instance = FileIndex._();

  final files = ValueNotifier<List<FileEntry>?>(null);
  final loading = ValueNotifier<bool>(false);
  List<String> _dirs = const [];
  Future<void>? _inFlight;

  Future<void> refresh(List<String> dirIdentifiers) {
    if (!listEquals(dirIdentifiers, _dirs)) {
      _dirs = List.of(dirIdentifiers);
      files.value = null;
    }
    return _inFlight ??= _scan(_dirs).whenComplete(() => _inFlight = null);
  }

  Future<void> _scan(List<String> dirs) async {
    loading.value = true;
    try {
      final all = <FileEntry>[];
      for (final dir in dirs) {
        try {
          all.addAll(await listFiles(dir));
        } on PlatformException catch (e, s) {
          logError(e, s);
        }
      }
      if (listEquals(dirs, _dirs)) files.value = dedupeNested(all);
    } finally {
      loading.value = false;
    }
  }
}

/// With nested folder grants the same file is listed twice; keep the entry
/// with the shortest path (the outermost folder)
List<FileEntry> dedupeNested(List<FileEntry> entries) {
  final seen = <String, FileEntry>{};
  for (final e in entries) {
    // Key by name + modification time + the tail of the path
    final key = '${e.fileName}|${e.modified.millisecondsSinceEpoch}';
    final existing = seen[key];
    if (existing == null) {
      seen[key] = e;
    } else if (existing.relativePath.endsWith(e.relativePath) ||
        e.relativePath.endsWith(existing.relativePath)) {
      if (e.relativePath.length > existing.relativePath.length) seen[key] = e;
    } else {
      // Same name and time but genuinely different files
      seen['$key|${e.dirIdentifier}|${e.relativePath}'] = e;
    }
  }
  return seen.values.toList(growable: false);
}

class FileMatch {
  FileMatch(this.file, this.score, this.nameHighlights);

  final FileEntry file;
  final double score;
  final Set<int> nameHighlights;
}

/// Space-separated components in any order, matched against the file name
/// (with initialisms) and its folder path. Empty query: newest first.
List<FileMatch> searchFiles(
  List<FileEntry> files,
  String query, {
  int limit = 300,
}) {
  final terms = splitSearchQuery(query);
  if (terms.isEmpty) {
    final sorted = [...files]..sort((a, b) => b.modified.compareTo(a.modified));
    return [for (final f in sorted.take(limit)) FileMatch(f, 0, const {})];
  }
  final results = <FileMatch>[];
  for (final file in files) {
    final name = foldForSearch(file.fileName);
    final folder = foldForSearch(file.folder);
    var total = 0.0;
    final highlights = <int>{};
    var all = true;
    for (final term in terms) {
      final inName = matchTerm(term, name, allowFlex: true);
      final inFolder = matchTerm(term, folder);
      final nameScore = (inName?.score ?? 0) * 1.0;
      final folderScore = (inFolder?.score ?? 0) * 0.5;
      if (inName == null && inFolder == null) {
        all = false;
        break;
      }
      if (nameScore >= folderScore) {
        total += nameScore;
        highlights.addAll(inName!.positions);
      } else {
        total += folderScore;
      }
    }
    if (!all) continue;
    // Prefer short paths and notes
    total -= min(file.relativePath.length, 80) * 0.05;
    if (file.isOrg) total += 3;
    results.add(FileMatch(file, total, highlights));
  }
  results.sort((a, b) {
    final byScore = b.score.compareTo(a.score);
    return byScore != 0 ? byScore : b.file.modified.compareTo(a.file.modified);
  });
  return results.length > limit ? results.sublist(0, limit) : results;
}
