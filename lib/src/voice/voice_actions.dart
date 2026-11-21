import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:orgro/src/debug.dart';
import 'package:orgro/src/notes_settings.dart';
import 'package:orgro/src/pages/voice_capture.dart';
import 'package:orgro/src/preferences.dart';
import 'package:orgro/src/routes/routes.dart';
import 'package:orgro/src/voice/voice.dart';

/// Handles the "Record Voice Note" App Shortcut (Shortcuts app, Siri, Action
/// button, Lock Screen / Control Center Shortcut control), whether it launched
/// the app or arrived while it was running.
class VoiceActions extends StatefulWidget {
  const VoiceActions({required this.child, super.key});

  final Widget child;

  @override
  State<VoiceActions> createState() => _VoiceActionsState();
}

class _VoiceActionsState extends State<VoiceActions>
    with WidgetsBindingObserver {
  var _open = false;
  String? _configuredDir;

  List<String> _accessible = const [];

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _accessible = Preferences.of(
      context,
      PrefsAspect.accessibleDirs,
    ).accessibleDirs;
    _configure();
  }

  /// Tell the native side where background recordings go
  void _configure() {
    final dir = NotesSettings.instance.effectiveDir(_accessible);
    if (dir != _configuredDir) {
      _configuredDir = dir;
      VoiceApi.configure(dirIdentifier: dir).onError(logError);
    }
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    NotesSettings.instance.addListener(_configure);
    NotesSettings.instance.ensureLoaded();
    try {
      VoiceApi.setActionHandler(_handle);
    } catch (e, s) {
      logError(e, s);
    }
    // Launched by the shortcut before we were listening
    WidgetsBinding.instance.addPostFrameCallback((_) => _consumePending());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    NotesSettings.instance.removeListener(_configure);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _consumePending();
  }

  Future<void> _consumePending() async {
    try {
      final action = await VoiceApi.consumePendingAction();
      if (action != null) _handle(action);
    } catch (e, s) {
      // Not available on this platform
      logError(e, s);
    }
  }

  void _handle(String action) {
    if (action != 'voiceNote' || _open) return;
    final context = navigatorKey.currentContext;
    if (context == null) return;
    _open = true;
    unawaited(
      showVoiceCapture(
        context,
        autoStart: true,
      ).whenComplete(() => _open = false),
    );
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
