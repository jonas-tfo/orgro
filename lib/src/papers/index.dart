import 'dart:convert';

import 'package:file_picker_writable/file_picker_writable.dart';
import 'package:flutter/foundation.dart';
import 'package:orgro/src/papers/papers.dart';
import 'package:orgro/src/roam/files.dart';

/// The bibliography, loaded from a path inside the notes folder and cached
/// while the app runs
class PapersIndex {
  PapersIndex._();

  static final instance = PapersIndex._();

  final papers = ValueNotifier<List<Paper>?>(null);
  final loading = ValueNotifier<bool>(false);

  /// A user-facing problem (missing file etc.), or null
  final error = ValueNotifier<String?>(null);

  (List<String>, String)? _source;
  Future<void>? _inFlight;

  /// Load [relativePath] from the first of [dirIdentifiers] that has it (the
  /// notes folder first). If none has it at that path, any file whose path
  /// ends with it (or with the same name) is used, which copes with granting
  /// a folder above or below the notes root.
  Future<void> refresh({
    required List<String> dirIdentifiers,
    required String relativePath,
  }) {
    final source = (List.of(dirIdentifiers), relativePath);
    if (_source == null ||
        !listEquals(source.$1, _source!.$1) ||
        source.$2 != _source!.$2) {
      _source = source;
      papers.value = null;
      error.value = null;
    }
    return _inFlight ??= _load(
      source.$1,
      relativePath,
    ).whenComplete(() => _inFlight = null);
  }

  bool _isCurrent(List<String> dirs, String path) =>
      _source != null && listEquals(_source!.$1, dirs) && _source!.$2 == path;

  Future<void> _load(List<String> dirs, String path) async {
    loading.value = true;
    final searched = <String>[];
    try {
      final file = await _find(dirs, path, searched);
      if (file == null) {
        throw StateError(
          'not found in ${searched.isEmpty ? 'any folder' : searched.join(', ')}',
        );
      }
      final text = await FilePickerWritable().readFile(
        identifier: file.identifier,
        reader: (_, f) async =>
            utf8.decode(await f.readAsBytes(), allowMalformed: true),
      );
      final parsed = await compute(parseBibliography, text);
      if (_isCurrent(dirs, path)) {
        papers.value = parsed;
        error.value = null;
      }
    } catch (e) {
      if (_isCurrent(dirs, path)) {
        papers.value = const [];
        error.value = '$path: $e';
      }
    } finally {
      loading.value = false;
    }
  }

  Future<({String identifier})?> _find(
    List<String> dirs,
    String path,
    List<String> searched,
  ) async {
    // Exact path in each folder, with access to the folder held open
    for (final dir in dirs) {
      final entry = FileEntry(
        dirIdentifier: dir,
        rootName: '',
        relativePath: path,
        fileName: path.split('/').last,
        modified: DateTime(0),
      );
      final found = await entry.resolve().catchError((_) => null);
      if (found != null) return (identifier: found.identifier);
    }
    // Otherwise look through the folders' files
    final name = path.split('/').last.toLowerCase();
    FileEntry? best;
    var bestRank = 0;
    for (final dir in dirs) {
      final files = await listFiles(dir).catchError((_) => <FileEntry>[]);
      if (files.isNotEmpty) searched.add(files.first.rootName);
      for (final f in files) {
        final rank =
            f.relativePath.endsWith('/$path') ||
                '${f.rootName}/${f.relativePath}'.endsWith('/$path')
            ? 2
            : f.fileName.toLowerCase() == name
            ? 1
            : 0;
        if (rank > bestRank ||
            (rank == bestRank &&
                rank > 0 &&
                f.relativePath.length < best!.relativePath.length)) {
          best = f;
          bestRank = rank;
        }
      }
    }
    final resolved = await best?.resolve();
    return resolved == null ? null : (identifier: resolved.identifier);
  }
}
