import 'dart:math';

import 'package:flutter/services.dart';

const _channel = MethodChannel('com.madlonkay.orgro/voice');
const _events = EventChannel('com.madlonkay.orgro/voice_events');

const kVoiceNotesFileName = 'voice-notes.org';

sealed class VoiceEvent {
  const VoiceEvent();

  static VoiceEvent? fromMap(Map<Object?, Object?> map) =>
      switch (map['type']) {
        'transcript' => VoiceTranscript(map['text'] as String? ?? ''),
        'level' => VoiceLevel((map['value'] as num? ?? 0).toDouble()),
        'started' => VoiceStarted(onDevice: map['onDevice'] == true),
        'stopped' => const VoiceStopped(),
        'interrupted' => VoiceInterrupted(map['text'] as String? ?? ''),
        'error' => VoiceError(map['message'] as String? ?? ''),
        _ => null,
      };
}

class VoiceTranscript extends VoiceEvent {
  const VoiceTranscript(this.text);
  final String text;
}

class VoiceLevel extends VoiceEvent {
  const VoiceLevel(this.value);

  /// 0..1
  final double value;
}

class VoiceStarted extends VoiceEvent {
  const VoiceStarted({required this.onDevice});
  final bool onDevice;
}

class VoiceStopped extends VoiceEvent {
  const VoiceStopped();
}

class VoiceInterrupted extends VoiceEvent {
  const VoiceInterrupted(this.text);
  final String text;
}

class VoiceError extends VoiceEvent {
  const VoiceError(this.message);
  final String message;
}

abstract final class VoiceApi {
  static final Stream<VoiceEvent> events = _events
      .receiveBroadcastStream()
      .map((e) => VoiceEvent.fromMap(e as Map<Object?, Object?>))
      .where((e) => e != null)
      .cast<VoiceEvent>();

  static Future<bool> requestPermissions() async =>
      await _channel.invokeMethod<bool>('requestPermissions') ?? false;

  static Future<List<String>> locales() async =>
      await _channel.invokeListMethod<String>('locales') ?? const [];

  static Future<String?> getLocale() =>
      _channel.invokeMethod<String>('getLocale');

  static Future<void> setLocale(String locale) =>
      _channel.invokeMethod('setLocale', {'locale': locale});

  static Future<void> start(String locale) =>
      _channel.invokeMethod('start', {'locale': locale});

  /// Stops recording and returns the final transcript
  static Future<String> stop() async =>
      await _channel.invokeMethod<String>('stop') ?? '';

  static Future<void> cancel() => _channel.invokeMethod('cancel');

  /// Tell the native side which notes folder recordings started from the Lock
  /// Screen (without the app's UI) are saved to
  static Future<void> configure({required String? dirIdentifier}) =>
      _channel.invokeMethod('configure', {'dirIdentifier': dirIdentifier});

  /// Returns file info compatible with file_picker_writable's FileInfo
  static Future<Map<String, String>?> appendToFile({
    required String dirIdentifier,
    required String fileName,
    required String text,
    required String header,
  }) => _channel.invokeMapMethod<String, String>('appendToFile', {
    'dirIdentifier': dirIdentifier,
    'fileName': fileName,
    'text': text,
    'header': header,
  });

  /// An action requested from outside the app (App Shortcut) before Flutter
  /// was listening
  static Future<String?> consumePendingAction() =>
      _channel.invokeMethod<String>('consumePendingAction');

  static void setActionHandler(void Function(String action) handler) {
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'action') handler(call.arguments as String);
      return null;
    });
  }
}

const _weekdays = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

String _two(int n) => n.toString().padLeft(2, '0');

/// Org inactive timestamp, e.g. [2026-11-21 Sat 14:03]
String orgInactiveTimestamp(DateTime t) =>
    '[${t.year}-${_two(t.month)}-${_two(t.day)} '
    '${_weekdays[t.weekday - 1]} ${_two(t.hour)}:${_two(t.minute)}]';

/// Headline for an entry: the first few words of the transcript
String voiceEntryTitle(String transcript, {int maxWords = 8}) {
  final words = transcript
      .trim()
      .split(RegExp(r'\s+'))
      .where((w) => w.isNotEmpty)
      .toList();
  if (words.isEmpty) return 'Voice note';
  final taken = words.take(maxWords).join(' ');
  // Drop trailing punctuation, then mark truncation
  final cleaned = taken.replaceFirst(RegExp(r'[.,;:!?]+$'), '');
  return words.length > maxWords ? '$cleaned…' : cleaned;
}

/// An entry appended to the voice notes file, in the style of the user's
/// capture templates: headline, inactive timestamp, then the text.
String formatVoiceEntry(String transcript, DateTime time) {
  // Lines starting with * would become headlines; escape them like Org does
  final body = transcript
      .trim()
      .split('\n')
      .map((l) => l.startsWith('*') ? ',$l' : l)
      .join('\n');
  return '* ${voiceEntryTitle(transcript)}\n'
      '${orgInactiveTimestamp(time)}\n'
      '$body\n';
}

String _uuidV4([Random? random]) {
  final r = random ?? Random.secure();
  final bytes = List<int>.generate(16, (_) => r.nextInt(256));
  bytes[6] = (bytes[6] & 0x0f) | 0x40;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-'
      '${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Header for a newly created voice notes file; it's an org-roam node so it
/// shows up in the node finder
String voiceNotesFileHeader([Random? random]) =>
    ':PROPERTIES:\n'
    ':ID:       ${_uuidV4(random)}\n'
    ':END:\n'
    '#+title: Voice Notes\n'
    '#+filetags: :voice:\n'
    '\n';
