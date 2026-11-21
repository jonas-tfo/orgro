import 'package:flutter_test/flutter_test.dart';
import 'package:material_ui/material_ui.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/data_source.dart';
import 'package:orgro/src/preferences.dart';
import 'package:orgro/src/routes/document.dart';
import 'package:orgro/src/tabs.dart';

class _FakeDocPage extends StatelessWidget {
  const _FakeDocPage(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: Text('doc:$name')),
    body: Column(
      children: [
        // Following a link inside a tab
        TextButton(
          onPressed: () => openDocumentRoute(
            context,
            DocumentRouteArgs(dataSource: AssetDataSource('$name-linked.org')),
          ),
          child: Text('link:$name'),
        ),
      ],
    ),
  );
}

Route<void> _fakeRoute(RouteSettings settings) {
  final args = settings.arguments as DocumentRouteArgs;
  return MaterialPageRoute(
    settings: settings,
    fullscreenDialog: true,
    builder: (_) => _FakeDocPage(args.dataSource.name),
  );
}

void main() {
  late BuildContext rootContext;
  final tabs = DocumentTabs.instance;

  setUp(() => tabs.documentRouteBuilder = _fakeRoute);

  Future<void> pumpApp(WidgetTester tester) => tester.pumpWidget(
    Preferences(
      isTest: true,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        onGenerateRoute: (settings) => _fakeRoute(settings),
        home: Builder(
          builder: (context) {
            rootContext = context;
            return const Scaffold(body: Text('start'));
          },
        ),
      ),
    ),
  );

  DocumentRouteArgs doc(String name) =>
      DocumentRouteArgs(dataSource: AssetDataSource(name));

  testWidgets('open, dedupe, switch, follow links, close', (tester) async {
    await pumpApp(tester);

    var firstClosed = false;
    openDocumentRoute(rootContext, doc('a.org')).then((_) {
      firstClosed = true;
    });
    await tester.pumpAndSettle();
    expect(tabs.titles, ['a']);
    expect(find.text('doc:a.org'), findsOneWidget);

    // Same document from outside: switch, don't duplicate
    openDocumentRoute(rootContext, doc('a.org'));
    await tester.pumpAndSettle();
    expect(tabs.length, 1);

    openDocumentRoute(rootContext, doc('b.org'));
    await tester.pumpAndSettle();
    expect(tabs.titles, ['a', 'b']);
    expect(tabs.activeIndex, 1);

    // A link inside tab b stays in tab b and updates its title
    await tester.tap(find.text('link:b.org'));
    await tester.pumpAndSettle();
    expect(tabs.length, 2);
    expect(tabs.titles, ['a', 'b.org-linked']);

    // Back within the tab
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(tabs.titles, ['a', 'b']);

    // Switch by tapping the tab chip
    await tester.tap(find.text('a'));
    await tester.pumpAndSettle();
    expect(tabs.activeIndex, 0);
    expect(find.text('doc:a.org'), findsOneWidget);

    // Closing a tab's last document closes the tab
    await tester.tap(find.byType(CloseButton));
    await tester.pumpAndSettle();
    expect(tabs.titles, ['b']);
    expect(firstClosed, isTrue);

    // Closing the last tab via its tab chip returns to the start page
    await tester.tap(find.byTooltip('Close tab'));
    // close() waits between pops so documents can run their close handling
    await tester.pump(const Duration(milliseconds: 400));
    await tester.pumpAndSettle();
    expect(tabs.length, 0);
    expect(find.text('start'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
