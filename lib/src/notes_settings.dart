import 'package:flutter/foundation.dart';
import 'package:orgro/src/debug.dart';
import 'package:shared_preferences/shared_preferences.dart';

const kDefaultBibliographyPath = 'references/references.bib';

/// Settings for working with a folder of org-roam notes: which folder it is,
/// and where its bibliography lives. Kept separate from the main preferences
/// so it can load lazily.
class NotesSettings extends ChangeNotifier {
  NotesSettings._();

  static final instance = NotesSettings._();

  static const _kDirIdentifier = 'notes_dir_identifier';
  static const _kDirName = 'notes_dir_name';
  static const _kBibliographyPath = 'notes_bibliography_path';

  SharedPreferencesAsync? _prefsInstance;
  SharedPreferencesAsync get _prefs =>
      _prefsInstance ??= SharedPreferencesAsync();

  Future<void>? _loading;
  var _loaded = false;

  String? _dirIdentifier;
  String? _dirName;
  String _bibliographyPath = kDefaultBibliographyPath;

  /// The org-roam folder chosen in Settings, if any
  String? get dirIdentifier => _dirIdentifier;
  String? get dirName => _dirName;

  /// Path of the .bib file, relative to the notes folder
  String get bibliographyPath => _bibliographyPath;

  bool get isLoaded => _loaded;

  Future<void> ensureLoaded() => _loading ??= _load();

  Future<void> _load() async {
    try {
      _dirIdentifier = await _prefs.getString(_kDirIdentifier);
      _dirName = await _prefs.getString(_kDirName);
      final bib = await _prefs.getString(_kBibliographyPath);
      if (bib != null && bib.trim().isNotEmpty) _bibliographyPath = bib;
    } catch (e, s) {
      // E.g. no platform implementation in tests: keep defaults
      logError(e, s);
    }
    _loaded = true;
    notifyListeners();
  }

  /// The folder to index and save to: the chosen notes folder, or else the
  /// first folder Orgro was given access to
  String? effectiveDir(List<String> accessibleDirs) =>
      _dirIdentifier ?? accessibleDirs.firstOrNull;

  /// The folders the node finder and text search scan
  List<String> searchDirs(List<String> accessibleDirs) =>
      _dirIdentifier != null ? [_dirIdentifier!] : accessibleDirs;

  Future<void> setNotesDir({
    required String? identifier,
    required String? name,
  }) async {
    _dirIdentifier = identifier;
    _dirName = name;
    notifyListeners();
    await _setOrRemove(_kDirIdentifier, identifier);
    await _setOrRemove(_kDirName, name);
  }

  Future<void> setBibliographyPath(String path) async {
    final cleaned = normalizeBibliographyPath(path);
    _bibliographyPath = cleaned.isEmpty ? kDefaultBibliographyPath : cleaned;
    notifyListeners();
    await _setOrRemove(
      _kBibliographyPath,
      _bibliographyPath == kDefaultBibliographyPath ? null : _bibliographyPath,
    );
  }

  Future<void> _setOrRemove(String key, String? value) async {
    try {
      if (value == null) {
        await _prefs.remove(key);
      } else {
        await _prefs.setString(key, value);
      }
    } catch (e, s) {
      logError(e, s);
    }
  }
}

/// Trim and drop leading "./" or "/" so the path is relative to the folder
String normalizeBibliographyPath(String path) {
  var p = path.trim().replaceAll('\\', '/');
  while (p.startsWith('./')) {
    p = p.substring(2);
  }
  while (p.startsWith('/')) {
    p = p.substring(1);
  }
  return p;
}
