import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts_lite.dart';
import 'package:material_ui/material_ui.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/pages/node_finder.dart';
import 'package:orgro/src/preferences.dart';

void main() {
  GoogleFontsLite.config.allowRuntimeFetching = false;

  // The finder is pushed as its own route, so it must only depend on app-level
  // providers (not document-scoped ones like ViewSettings).
  testWidgets('Node finder builds with only app-level providers', (
    tester,
  ) async {
    await tester.pumpWidget(
      Preferences(
        isTest: true,
        child: MaterialApp(
          localizationsDelegates: [
            AppLocalizations.delegate,
            ...GlobalMaterialLocalizations.delegates,
          ],
          supportedLocales: AppLocalizations.supportedLocales,
          home: const NodeFinderPage(),
        ),
      ),
    );
    await tester.pump();
    expect(tester.takeException(), isNull);
    expect(find.text('Find node…'), findsOneWidget);
    // No folder granted in a fresh install
    expect(find.text('Grant access'), findsOneWidget);
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pump();
  });
}
