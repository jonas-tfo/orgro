import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:material_ui/material_ui.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/components/view_settings.dart';
import 'package:orgro/src/data_source.dart';
import 'package:orgro/src/debug.dart';
import 'package:orgro/src/file_picker.dart';
import 'package:orgro/src/navigation.dart';
import 'package:orgro/src/notes_settings.dart';
import 'package:orgro/src/preferences.dart';
import 'package:orgro/src/roam/index.dart';
import 'package:orgro/src/voice/voice.dart';
import 'package:orgro/theme.dart';

/// Open the voice note screen. With [autoStart] dictation begins right away
/// (used by the App Shortcut and the home screen quick action).
Future<void> showVoiceCapture(BuildContext context, {bool autoStart = false}) =>
    Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => VoiceCapturePage(autoStart: autoStart),
      ),
    );

// Offered in the language menu; any other supported locale can still be set
const _kCommonLocales = ['de-DE', 'en-US', 'en-GB'];

enum _State { idle, recording, stopping, saving }

class VoiceCapturePage extends StatefulWidget {
  const VoiceCapturePage({this.autoStart = false, super.key});

  final bool autoStart;

  @override
  State<VoiceCapturePage> createState() => _VoiceCapturePageState();
}

class _VoiceCapturePageState extends State<VoiceCapturePage> {
  final _text = TextEditingController();
  final _scroll = ScrollController();
  StreamSubscription<VoiceEvent>? _events;
  var _state = _State.idle;
  var _level = 0.0;
  String? _locale;
  List<String> _supported = const [];
  String? _error;

  /// Text from earlier recordings in this session (recording can be resumed)
  var _base = '';
  final _stopwatch = Stopwatch();
  Duration _previous = Duration.zero;
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    _events = VoiceApi.events.listen(_onEvent, onError: _onStreamError);
    _init();
  }

  Future<void> _init() async {
    try {
      final supported = await VoiceApi.locales();
      final stored = await VoiceApi.getLocale();
      final device = Platform.localeName.replaceAll('_', '-');
      String pick() {
        if (stored != null && supported.contains(stored)) return stored;
        if (supported.contains(device)) return device;
        final lang = device.split('-').first;
        return supported.firstWhere(
          (l) => l.startsWith('$lang-'),
          orElse: () => 'en-US',
        );
      }

      if (!mounted) return;
      setState(() {
        _supported = supported;
        _locale = pick();
      });
      if (widget.autoStart) await _start();
    } catch (e, s) {
      _fail(e, s);
    }
  }

  @override
  void dispose() {
    _events?.cancel();
    _ticker?.cancel();
    if (_state == _State.recording) VoiceApi.cancel();
    _text.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _fail(Object e, StackTrace s) {
    logError(e, s);
    if (!mounted) return;
    setState(() {
      _error = e is PlatformException ? (e.message ?? e.code) : e.toString();
      _state = _State.idle;
    });
  }

  void _onStreamError(Object e, StackTrace s) => _fail(e, s);

  void _onEvent(VoiceEvent event) {
    if (!mounted) return;
    switch (event) {
      case VoiceTranscript(:final text):
        if (_state != _State.recording && _state != _State.stopping) return;
        _setText(_join(_base, text));
      case VoiceLevel(:final value):
        setState(() => _level = value);
      case VoiceInterrupted(:final text):
        _setText(_join(_base, text));
        _stopClock();
        setState(() => _state = _State.idle);
      case VoiceError(:final message):
        setState(() => _error = message);
      case VoiceStarted():
      case VoiceStopped():
        break;
    }
  }

  String _join(String a, String b) =>
      [a.trim(), b.trim()].where((s) => s.isNotEmpty).join(' ');

  void _setText(String text) {
    _text.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: text.length),
    );
    // Follow the live transcript
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }
    });
  }

  Future<void> _start() async {
    final locale = _locale;
    if (locale == null) return;
    setState(() => _error = null);
    try {
      if (!await VoiceApi.requestPermissions()) {
        if (!mounted) return;
        setState(() {
          _error = AppLocalizations.of(context)!.voicePermissionDenied;
        });
        return;
      }
      _base = _text.text;
      await VoiceApi.start(locale);
      if (!mounted) return;
      setState(() => _state = _State.recording);
      _stopwatch
        ..reset()
        ..start();
      _ticker = Timer.periodic(
        const Duration(milliseconds: 500),
        (_) => setState(() {}),
      );
    } catch (e, s) {
      _fail(e, s);
    }
  }

  void _stopClock() {
    _stopwatch.stop();
    _previous += _stopwatch.elapsed;
    _stopwatch.reset();
    _ticker?.cancel();
    _level = 0;
  }

  Future<void> _stop() async {
    if (_state != _State.recording) return;
    setState(() => _state = _State.stopping);
    try {
      final transcript = await VoiceApi.stop();
      _setText(_join(_base, transcript));
    } catch (e, s) {
      _fail(e, s);
    }
    _stopClock();
    if (mounted) setState(() => _state = _State.idle);
  }

  Future<void> _save() async {
    if (_state == _State.recording) await _stop();
    final text = _text.text.trim();
    if (text.isEmpty || !mounted) return;
    final l10n = AppLocalizations.of(context)!;
    var dirs = Preferences.of(context, PrefsAspect.nil).accessibleDirs;
    if (dirs.isEmpty) {
      final dir = await pickDirectory();
      if (dir == null || !mounted) return;
      await Preferences.of(
        context,
        PrefsAspect.nil,
      ).addAccessibleDir(dir.identifier);
      dirs = [dir.identifier];
    }
    setState(() => _state = _State.saving);
    try {
      final info = await VoiceApi.appendToFile(
        // The notes folder from Settings, else the first granted folder
        dirIdentifier: NotesSettings.instance.effectiveDir(dirs)!,
        fileName: kVoiceNotesFileName,
        text: formatVoiceEntry(text, DateTime.now()),
        header: voiceNotesFileHeader(),
      );
      if (!mounted) return;
      // Make the new entry findable right away
      RoamNodeIndex.instance
          .refresh(NotesSettings.instance.searchDirs(dirs))
          .onError(logError);
      final navigator = Navigator.of(context);
      final messenger = ScaffoldMessenger.of(context);
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(l10n.voiceSaved(kVoiceNotesFileName)),
          action: info == null
              ? null
              : SnackBarAction(
                  label: l10n.voiceOpenFile,
                  onPressed: () => loadDocument(
                    navigator.context,
                    NativeDataSource(
                      info['fileName'] ?? kVoiceNotesFileName,
                      info['identifier']!,
                      info['uri']!,
                      persistable: true,
                    ),
                  ),
                ),
        ),
      );
    } catch (e, s) {
      _fail(e, s);
    }
  }

  Future<void> _discard() async {
    if (_state == _State.recording) await VoiceApi.cancel();
    if (mounted) Navigator.pop(context);
  }

  Future<void> _setLocale(String locale) async {
    final wasRecording = _state == _State.recording;
    if (wasRecording) await _stop();
    setState(() => _locale = locale);
    await VoiceApi.setLocale(locale);
    if (wasRecording) await _start();
  }

  String get _elapsed {
    final d = _previous + _stopwatch.elapsed;
    final m = d.inMinutes.toString().padLeft(2, '0');
    final s = (d.inSeconds % 60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final textStyle = ViewSettingsData.defaults(context).textStyle;
    final recording = _state == _State.recording;
    final busy = _state == _State.stopping || _state == _State.saving;
    final locales = {
      ..._kCommonLocales.where(_supported.contains),
      ?_locale,
    }.toList();
    return PopScope(
      canPop: !recording && _text.text.trim().isEmpty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _discard();
      },
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            tooltip: l10n.voiceDiscard,
            icon: const Icon(Icons.close),
            onPressed: busy ? null : _discard,
          ),
          title: Text(l10n.voiceTitle),
          actions: [
            if (_locale != null)
              PopupMenuButton<String>(
                tooltip: l10n.voiceLanguage,
                initialValue: _locale,
                onSelected: _setLocale,
                itemBuilder: (_) => [
                  for (final l in locales)
                    PopupMenuItem(value: l, child: Text(l)),
                ],
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Center(
                    child: Text(
                      _locale!,
                      style: const TextStyle(color: Horizon.yellow),
                    ),
                  ),
                ),
              ),
            TextButton(
              onPressed: busy || _text.text.trim().isEmpty ? null : _save,
              child: Text(l10n.voiceSave),
            ),
          ],
        ),
        body: SafeArea(
          child: Column(
            children: [
              if (_error != null)
                Container(
                  width: double.infinity,
                  color: Horizon.highlight,
                  padding: const EdgeInsets.all(12),
                  child: Text(
                    _error!,
                    style: const TextStyle(color: Horizon.red),
                  ),
                ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: TextField(
                    controller: _text,
                    scrollController: _scroll,
                    readOnly: recording || busy,
                    maxLines: null,
                    expands: true,
                    textAlignVertical: TextAlignVertical.top,
                    style: textStyle.copyWith(color: Horizon.fg),
                    cursorColor: Horizon.red,
                    onChanged: (_) => setState(() {}),
                    decoration: InputDecoration(
                      border: InputBorder.none,
                      hintText: recording
                          ? l10n.voiceListening
                          : l10n.voiceHint,
                      hintStyle: textStyle.copyWith(color: Horizon.comments),
                    ),
                  ),
                ),
              ),
              Text(
                _elapsed,
                style: textStyle.copyWith(
                  color: recording ? Horizon.red : Horizon.base4,
                ),
              ),
              const SizedBox(height: 8),
              // Input level
              AnimatedContainer(
                duration: const Duration(milliseconds: 100),
                height: 3,
                width: 40 + 200 * (recording ? _level : 0),
                color: Horizon.red,
              ),
              const SizedBox(height: 16),
              SizedBox(
                width: 72,
                height: 72,
                child: FloatingActionButton(
                  heroTag: 'voiceRecordFAB',
                  backgroundColor: recording
                      ? Horizon.red
                      : Horizon.highlightSelected,
                  foregroundColor: Horizon.fgAlt,
                  tooltip: recording ? l10n.voiceStop : l10n.voiceRecord,
                  onPressed: busy ? null : (recording ? _stop : _start),
                  child: busy
                      ? const CircularProgressIndicator(color: Horizon.fgAlt)
                      : Icon(recording ? Icons.stop : Icons.mic, size: 34),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
