import 'dart:async';

import 'package:material_ui/material_ui.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/pages/node_finder.dart';
import 'package:orgro/src/pages/voice_capture.dart';
import 'package:orgro/src/roam/index.dart';
import 'package:orgro/src/routes/document.dart';
import 'package:orgro/src/routes/routes.dart';
import 'package:orgro/theme.dart';

// Tabs for open documents, like centaur-tabs: every tab has its own navigator,
// so following links inside a tab builds up that tab's own back stack.

class _DocumentTab {
  _DocumentTab(this.args) : navigatorKey = GlobalKey<NavigatorState>();

  final DocumentRouteArgs args;
  final GlobalKey<NavigatorState> navigatorKey;
  final observer = _TabObserver();
  final title = ValueNotifier<String>('');
  final closed = Completer<void>();
  final key = UniqueKey();
  // Nested navigators each need their own hero controller
  final heroController = MaterialApp.createMaterialHeroController();
}

class _TabObserver extends NavigatorObserver {
  final routes = <Route<dynamic>>[];
  VoidCallback? onChanged;

  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.add(route);
    onChanged?.call();
  }

  @override
  void didPop(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    onChanged?.call();
  }

  @override
  void didRemove(Route<dynamic> route, Route<dynamic>? previousRoute) {
    routes.remove(route);
    onChanged?.call();
  }

  @override
  void didReplace({Route<dynamic>? newRoute, Route<dynamic>? oldRoute}) {
    if (oldRoute != null) routes.remove(oldRoute);
    if (newRoute != null) routes.add(newRoute);
    onChanged?.call();
  }
}

/// Marks the subtree of one tab so [openDocumentRoute] knows to push inside it
class _TabScope extends InheritedWidget {
  const _TabScope({required this.tab, required super.child, super.key});

  final _DocumentTab tab;

  @override
  bool updateShouldNotify(_TabScope oldWidget) => tab != oldWidget.tab;
}

class DocumentTabs extends ChangeNotifier {
  DocumentTabs._();

  static final instance = DocumentTabs._();

  final _tabs = <_DocumentTab>[];
  var _active = 0;

  /// Builds the first route of each tab; replaceable in tests
  @visibleForTesting
  Route<void> Function(RouteSettings) documentRouteBuilder =
      DocumentRoute.fromSettings;
  Route<void>? _hostRoute;

  int get length => _tabs.length;

  @visibleForTesting
  List<String> get titles => [
    for (final t in _tabs)
      t.title.value.isEmpty ? _titleFor(t.args) : t.title.value,
  ];

  int get activeIndex => _active;

  bool isInTab(BuildContext context) =>
      context.getInheritedWidgetOfExactType<_TabScope>() != null;

  /// Open a document in a new tab (or switch to the tab already showing it).
  /// The returned future completes when the tab's first document is closed.
  Future<void> open(BuildContext context, DocumentRouteArgs args) {
    final existing = _tabs.indexWhere(
      (t) => t.args.dataSource.id == args.dataSource.id,
    );
    if (existing != -1 && args.target == null) {
      _active = existing;
      notifyListeners();
      return _tabs[existing].closed.future;
    }
    final tab = _DocumentTab(args);
    // Navigator callbacks can fire during build; update tab state afterwards
    tab.observer.onChanged = () =>
        scheduleMicrotask(() => _onTabRoutesChanged(tab));
    _tabs.add(tab);
    _active = _tabs.length - 1;
    notifyListeners();
    if (_hostRoute == null) {
      final route = _hostRoute = PageRouteBuilder<void>(
        settings: const RouteSettings(name: '/tabs'),
        pageBuilder: (context, _, _) => const _TabsHost(),
        transitionsBuilder: (context, animation, _, child) => SlideTransition(
          position: Tween(
            begin: const Offset(0, 1),
            end: Offset.zero,
          ).chain(CurveTween(curve: Curves.easeOutCubic)).animate(animation),
          child: child,
        ),
      );
      Navigator.of(context, rootNavigator: true).push(route).whenComplete(() {
        if (_hostRoute == route) _hostRoute = null;
      });
    }
    return tab.closed.future;
  }

  void select(int index) {
    if (index == _active || index < 0 || index >= _tabs.length) return;
    _active = index;
    notifyListeners();
  }

  /// Close a tab, letting each of its documents run its normal close handling
  /// (e.g. saving changes). Stops if a document refuses to close.
  Future<void> close(int index) async {
    if (index < 0 || index >= _tabs.length) return;
    final tab = _tabs[index];
    final navigator = tab.navigatorKey.currentState;
    if (navigator == null) {
      _remove(tab);
      return;
    }
    while (_tabs.contains(tab) && tab.observer.routes.length > 1) {
      final before = tab.observer.routes.length;
      await navigator.maybePop();
      // Give pop handlers (save prompts etc.) a chance to finish
      await Future<void>.delayed(const Duration(milliseconds: 350));
      if (tab.observer.routes.length >= before) break; // Refused
    }
  }

  void _onTabRoutesChanged(_DocumentTab tab) {
    final top = tab.observer.routes.lastOrNull;
    final args = top?.settings.arguments;
    if (args is DocumentRouteArgs) {
      tab.title.value = _titleFor(args);
    } else if (tab.title.value.isEmpty) {
      tab.title.value = _titleFor(tab.args);
    }
    // Only the blank base route is left: the tab is done
    if (tab.observer.routes.length == 1 &&
        tab.observer.routes.single.settings.name == _kTabBaseRoute) {
      _remove(tab);
    }
  }

  void _remove(_DocumentTab tab) {
    final index = _tabs.indexOf(tab);
    if (index == -1) return;
    _tabs.removeAt(index);
    if (!tab.closed.isCompleted) tab.closed.complete();
    if (_active >= _tabs.length) _active = _tabs.length - 1;
    if (_active < 0) _active = 0;
    notifyListeners();
    if (_tabs.isEmpty) {
      final route = _hostRoute;
      _hostRoute = null;
      if (route != null && route.isActive) route.navigator?.removeRoute(route);
    }
  }
}

String _titleFor(DocumentRouteArgs args) {
  final source = args.dataSource;
  final fileTitle = RoamNodeIndex.instance.titleForUri(source.id);
  if (fileTitle != null) return fileTitle;
  final name = source.name;
  return name.endsWith('.org') ? name.substring(0, name.length - 4) : name;
}

const _kTabBaseRoute = '/tab-base';

/// Push a document route: inside the current tab if [context] is in one and
/// [newTab] is false, otherwise in a new tab.
Future<void> openDocumentRoute(
  BuildContext context,
  DocumentRouteArgs args, {
  bool newTab = false,
}) {
  final tabs = DocumentTabs.instance;
  if (!newTab && tabs.isInTab(context)) {
    return Navigator.pushNamed(context, Routes.document, arguments: args);
  }
  return tabs.open(context, args);
}

class _TabsHost extends StatefulWidget {
  const _TabsHost();

  @override
  State<_TabsHost> createState() => _TabsHostState();
}

class _TabsHostState extends State<_TabsHost> {
  final _tabs = DocumentTabs.instance;

  @override
  void initState() {
    super.initState();
    _tabs.addListener(_onChanged);
  }

  @override
  void dispose() {
    _tabs.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) {
    final tabs = _tabs._tabs;
    if (tabs.isEmpty) return const ColoredBox(color: Horizon.bg);
    return PopScope(
      canPop: false,
      // Android back: go back within the active tab
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) tabs[_tabs._active].navigatorKey.currentState?.maybePop();
      },
      child: Material(
        color: Horizon.bgAlt,
        child: Column(
          children: [
            SafeArea(bottom: false, child: _TabBar(tabs: _tabs)),
            Expanded(
              child: MediaQuery.removePadding(
                context: context,
                removeTop: true,
                child: IndexedStack(
                  index: _tabs._active,
                  children: [
                    for (final tab in tabs)
                      _TabScope(
                        key: tab.key,
                        tab: tab,
                        child: HeroControllerScope(
                          controller: tab.heroController,
                          child: Navigator(
                            key: tab.navigatorKey,
                            observers: [tab.observer],
                            onGenerateInitialRoutes: (_, _) => [
                              PageRouteBuilder<void>(
                                settings: const RouteSettings(
                                  name: _kTabBaseRoute,
                                ),
                                pageBuilder: (_, _, _) =>
                                    const ColoredBox(color: Horizon.bg),
                              ),
                              _tabs.documentRouteBuilder(
                                RouteSettings(
                                  name: Routes.document,
                                  arguments: tab.args,
                                ),
                              ),
                            ],
                            onGenerateRoute: onGenerateRoute,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBar extends StatelessWidget {
  const _TabBar({required this.tabs});

  final DocumentTabs tabs;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return SizedBox(
      height: 32,
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: tabs._tabs.length,
              itemBuilder: (context, i) => _TabChip(
                tab: tabs._tabs[i],
                active: i == tabs._active,
                onTap: () => tabs.select(i),
                onClose: () => tabs.close(i),
              ),
            ),
          ),
          IconButton(
            tooltip: l10n.voiceTitle,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: Horizon.base4,
            icon: const Icon(Icons.mic_none),
            onPressed: () => showVoiceCapture(context),
          ),
          IconButton(
            tooltip: l10n.tooltipNewTab,
            visualDensity: VisualDensity.compact,
            iconSize: 18,
            color: Horizon.base4,
            icon: const Icon(Icons.add),
            onPressed: () => showNodeFinder(context, newTab: true),
          ),
        ],
      ),
    );
  }
}

class _TabChip extends StatelessWidget {
  const _TabChip({
    required this.tab,
    required this.active,
    required this.onTap,
    required this.onClose,
  });

  final _DocumentTab tab;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Container(
        decoration: BoxDecoration(
          color: active ? Horizon.bg : Horizon.bgAlt,
          // centaur-tabs style active bar
          border: Border(
            top: BorderSide(
              color: active ? Horizon.red : Colors.transparent,
              width: 2,
            ),
            right: const BorderSide(color: Horizon.base0),
          ),
        ),
        padding: const EdgeInsets.only(left: 10),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 150),
              child: ValueListenableBuilder<String>(
                valueListenable: tab.title,
                builder: (context, title, _) => Text(
                  title.isEmpty ? _titleFor(tab.args) : title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: active ? Horizon.fgAlt : Horizon.base4,
                  ),
                ),
              ),
            ),
            SizedBox(
              width: 28,
              height: 28,
              child: IconButton(
                tooltip: AppLocalizations.of(context)!.tooltipCloseTab,
                padding: EdgeInsets.zero,
                iconSize: 14,
                color: active ? Horizon.fg : Horizon.base4,
                icon: const Icon(Icons.close),
                onPressed: onClose,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
