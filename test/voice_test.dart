import 'dart:math';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts_lite.dart';
import 'package:material_ui/material_ui.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/pages/voice_capture.dart';
import 'package:orgro/src/preferences.dart';
import 'package:orgro/src/voice/voice.dart';

void main() {
  GoogleFontsLite.config.allowRuntimeFetching = false;

  group('formatting', () {
    final time = DateTime(2026, 11, 21, 14, 3);

    test('inactive timestamp', () {
      expect(orgInactiveTimestamp(time), '[2026-11-21 Sat 14:03]');
    });

    test('entry: title from first words, body escaped', () {
      final entry = formatVoiceEntry(
        'Remember to review the Boyer Moore good suffix rule before Friday.\n'
        '* not a headline',
        time,
      );
      expect(
        entry,
        '* Remember to review the Boyer Moore good suffix…\n'
        '[2026-11-21 Sat 14:03]\n'
        'Remember to review the Boyer Moore good suffix rule before Friday.\n'
        ',* not a headline\n',
      );
    });

    test('short title drops trailing punctuation', () {
      expect(voiceEntryTitle('Buy milk.'), 'Buy milk');
      expect(voiceEntryTitle('   '), 'Voice note');
    });

    test('file header is an org-roam node', () {
      final header = voiceNotesFileHeader(Random(1));
      expect(
        header,
        matches(
          RegExp(
            r'^:PROPERTIES:\n:ID:       [0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-'
            r'[89ab][0-9a-f]{3}-[0-9a-f]{12}\n:END:\n#\+title: Voice Notes\n',
          ),
        ),
      );
    });
  });

  testWidgets('Voice page: record, live transcript, stop, edit', (
    tester,
  ) async {
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    final calls = <String>[];
    messenger.setMockMethodCallHandler(
      const MethodChannel('com.madlonkay.orgro/voice'),
      (call) async {
        calls.add(call.method);
        return switch (call.method) {
          'locales' => ['de-DE', 'en-US'],
          'getLocale' => 'de-DE',
          'requestPermissions' => true,
          'stop' => 'Hallo Welt',
          _ => null,
        };
      },
    );
    // Event channel: capture the sink-side so the test can push events
    const codec = StandardMethodCodec();
    messenger.setMockMessageHandler('com.madlonkay.orgro/voice_events', (
      message,
    ) async {
      final call = codec.decodeMethodCall(message);
      calls.add('events:${call.method}');
      return codec.encodeSuccessEnvelope(null);
    });
    Future<void> sendEvent(Map<String, Object?> event) =>
        messenger.handlePlatformMessage(
          'com.madlonkay.orgro/voice_events',
          codec.encodeSuccessEnvelope(event),
          (_) {},
        );

    await tester.pumpWidget(
      Preferences(
        isTest: true,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: const VoiceCapturePage(autoStart: true),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(
      calls,
      containsAllInOrder(['locales', 'requestPermissions', 'start']),
    );
    expect(find.text('de-DE'), findsOneWidget);
    expect(find.byIcon(Icons.stop), findsOneWidget);

    await sendEvent({'type': 'transcript', 'text': 'Hallo'});
    await tester.pump();
    expect(find.text('Hallo'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.stop));
    await tester.pumpAndSettle();
    expect(calls, contains('stop'));
    expect(find.text('Hallo Welt'), findsOneWidget);
    expect(find.byIcon(Icons.mic), findsOneWidget);

    // Editable after stopping
    await tester.enterText(find.byType(TextField), 'Hallo Welt, bearbeitet');
    await tester.pump();
    expect(find.text('Hallo Welt, bearbeitet'), findsOneWidget);
    expect(tester.takeException(), isNull);
    // Flush the asynchronous system-font notification before teardown
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });
}
