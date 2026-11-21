import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:orgro/src/debug.dart';
import 'package:orgro/src/roam/nodes.dart';

const _channel = MethodChannel('com.madlonkay.orgro/native_search');

Future<List<OrgFileData>?> readOrgFiles({
  required String requestId,
  required String dirIdentifier,
}) async {
  final result = await _channel.invokeListMethod<Object?>('readOrgFiles', {
    'requestId': requestId,
    'dirIdentifier': dirIdentifier,
  });
  return result
      ?.cast<Map<Object?, Object?>>()
      .map(OrgFileData.fromJson)
      .toList(growable: false);
}

Future<bool> cancelReadOrgFiles({required String requestId}) async {
  final result = await _channel.invokeMethod<bool>('cancelReadOrgFiles', {
    'requestId': requestId,
  });
  return result ?? false;
}

/// In-memory cache of the node index, so reopening the finder is instant while
/// a fresh scan runs in the background.
class RoamNodeIndex {
  RoamNodeIndex._();

  static final instance = RoamNodeIndex._();

  final nodes = ValueNotifier<List<RoamNode>?>(null);

  /// All scanned files, for full-text search. Duplicate paths from nested
  /// directory grants are removed.
  final files = ValueNotifier<List<OrgFileData>?>(null);
  final loading = ValueNotifier<bool>(false);
  List<String> _dirs = const [];
  Future<void>? _inFlight;
  String? _requestId;

  /// Scan [dirIdentifiers] (the directories the user granted access to). Files
  /// found in several directories (nested grants) are de-duplicated by ID.
  Future<void> refresh(List<String> dirIdentifiers) {
    if (!listEquals(dirIdentifiers, _dirs)) {
      _dirs = List.of(dirIdentifiers);
      nodes.value = null;
      files.value = null;
    }
    return _inFlight ??= _scan(_dirs).whenComplete(() => _inFlight = null);
  }

  Future<void> _scan(List<String> dirs) async {
    loading.value = true;
    final requestId = _requestId = Object().hashCode.toString();
    try {
      final found = <String, OrgFileData>{};
      for (final dir in dirs) {
        try {
          final result = await readOrgFiles(
            requestId: requestId,
            dirIdentifier: dir,
          );
          // null means cancelled or inaccessible
          for (final file in result ?? const <OrgFileData>[]) {
            found[file.uri] = file;
          }
        } on PlatformException catch (e, s) {
          // A stale directory bookmark shouldn't break the whole index
          logError(e, s);
        }
        if (_requestId != requestId) return; // Cancelled
      }
      final scanned = found.values.toList(growable: false);
      final index = await compute(buildRoamIndex, scanned);
      if (listEquals(dirs, _dirs)) {
        files.value = scanned;
        nodes.value = index;
      }
    } finally {
      if (_requestId == requestId) _requestId = null;
      loading.value = false;
    }
  }

  /// The #+title of a scanned file, if known
  String? titleForUri(String uri) {
    for (final node in nodes.value ?? const <RoamNode>[]) {
      if (node.isFileNode && node.file.uri == uri) return node.title;
    }
    return null;
  }

  Future<void> cancel() async {
    final requestId = _requestId;
    if (requestId != null) {
      _requestId = null;
      await cancelReadOrgFiles(requestId: requestId);
    }
  }
}
