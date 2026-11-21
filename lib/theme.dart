import 'package:material_ui/material_ui.dart';
import 'package:org_flutter/org_flutter.dart';

// https://material.io/resources/color/#!/?view.left=0&view.right=0&primary.color=006058&secondary.color=ff6e40
const orgroPrimaryColor = Color(0xff006058);
const _kPrimaryColorVariant = Color(0xff00352f);
const _kSecondaryColor = Colors.deepOrangeAccent;
final _kSecondaryColorVariant = Colors.deepOrangeAccent.shade700;

// TODO(aaron): Revert 13570c217d60907ff898331c259a1317e6cdbc3d when moving to
// Material 3
const _kUseMaterial3 = false;

final orgroLightTheme = ThemeData.from(
  colorScheme: ColorScheme.light(
    primary: orgroPrimaryColor,
    primaryContainer: _kPrimaryColorVariant,
    onPrimary: Colors.white,
    secondary: _kSecondaryColor,
    secondaryContainer: _kSecondaryColorVariant,
    onSecondary: Colors.white,
  ),
  useMaterial3: _kUseMaterial3,
);

// Palette of doom-horizon (doom-themes), with derived colors computed the same
// way as `doom-lighten` (blend toward white).
abstract final class Horizon {
  static const bg = Color(0xff232530);
  static const bgAlt = Color(0xff1c1e26);
  static const base0 = Color(0xff16161c);
  static const base1 = Color(0xff1a1c23);
  static const base4 = Color(0xff6a6a6a);
  static const base5 = Color(0xfff9cec3);
  static const fg = Color(0xffc7c9cb);
  static const fgAlt = Color(0xfffdf0ed);
  static const red = Color(0xffe95678);
  static const orange = Color(0xfff09383);
  static const green = Color(0xff09f7a0);
  static const teal = Color(0xff87ceeb);
  static const yellow = Color(0xfffab795);
  static const blue = Color(0xff21bfc2);
  static const magenta = Color(0xff6c6f93);
  static const violet = Color(0xffb877db);
  static const cyan = Color(0xff59e3e3);
  // hor-highlight, hor-highlight-selected, hor-highlight-bright (= comments)
  static const highlight = Color(0xff2e303a);
  static const highlightSelected = Color(0xff393b45);
  static const comments = Color(0xff4f5159);
}

final orgroDarkTheme =
    ThemeData.from(
      colorScheme: const ColorScheme.dark(
        primary: Horizon.blue,
        primaryContainer: Horizon.bgAlt,
        onPrimary: Horizon.bg,
        secondary: Horizon.red,
        secondaryContainer: Horizon.highlightSelected,
        onSecondary: Horizon.bg,
        surface: Horizon.bg,
        onSurface: Horizon.fg,
        error: Horizon.red,
      ),
      useMaterial3: _kUseMaterial3,
    ).copyWith(
      scaffoldBackgroundColor: Horizon.bg,
      canvasColor: Horizon.bg,
      cardColor: Horizon.bgAlt,
      dividerColor: Horizon.base0,
      textSelectionTheme: const TextSelectionThemeData(
        cursorColor: Horizon.red,
        selectionColor: Horizon.highlightSelected,
        selectionHandleColor: Horizon.red,
      ),
      // Flat, mode-line-like bars
      appBarTheme: const AppBarTheme(
        backgroundColor: Horizon.bgAlt,
        foregroundColor: Horizon.fg,
        elevation: 0,
        scrolledUnderElevation: 0,
        toolbarHeight: 48,
      ),
      bottomAppBarTheme: const BottomAppBarThemeData(
        color: Horizon.bgAlt,
        elevation: 0,
      ),
      floatingActionButtonTheme: const FloatingActionButtonThemeData(
        backgroundColor: Horizon.highlightSelected,
        foregroundColor: Horizon.fgAlt,
        elevation: 0,
      ),
      dialogTheme: const DialogThemeData(backgroundColor: Horizon.bgAlt),
      popupMenuTheme: const PopupMenuThemeData(color: Horizon.bgAlt),
      snackBarTheme: const SnackBarThemeData(
        backgroundColor: Horizon.highlightSelected,
        contentTextStyle: TextStyle(color: Horizon.fgAlt),
      ),
      textButtonTheme: TextButtonThemeData(
        style: TextButton.styleFrom(foregroundColor: Horizon.blue),
      ),
    );

// Org faces as doom-themes maps them for doom-horizon
final orgroHorizonOrgTheme = OrgThemeData.dark().copyWith(
  levelColors: const [
    Horizon.blue, // outline-1
    Horizon.magenta, // outline-2
    Horizon.violet, // outline-3
    Color(0xff58cfd1), // outline-4: (doom-lighten blue 0.25)
    Color(0xff9193ae), // outline-5: (doom-lighten magenta 0.25)
    Color(0xff90dfe0), // outline-6: (doom-lighten blue 0.5)
    Color(0xffb6b7c9), // outline-7: (doom-lighten magenta 0.5)
    Color(0xffd3f2f3), // outline-8: (doom-lighten blue 0.8)
  ],
  todoColor: Horizon.green, // org-todo
  doneColor: Horizon.base5, // org-done -> org-headline-done
  priorityColor: Horizon.red, // org-priority
  drawerColor: Horizon.comments, // org-drawer
  dateColor: Horizon.yellow, // org-date
  codeColor: Horizon.orange, // org-code
  linkColor: Horizon.yellow, // org-link (horizon override)
  metaColor: Horizon.yellow, // org-meta-line (doc-comments)
  infoColor: Horizon.violet, // org-document-info (builtin)
  macroColor: Horizon.orange,
  tableColor: Horizon.violet, // org-table
  keywordColor: Horizon.yellow, // org-special-keyword (doc-comments)
  highlightColor: Horizon.highlightSelected,
  footnoteColor: Horizon.orange, // org-footnote
  citationColor: Horizon.yellow,
  transcludeColor: Horizon.teal,
  srcTheme: const {
    'root': TextStyle(backgroundColor: Colors.transparent),
    'subst': TextStyle(color: Horizon.red),
    'comment': TextStyle(color: Horizon.comments),
    'keyword': TextStyle(color: Horizon.violet),
    'attribute': TextStyle(color: Horizon.violet),
    'selector-tag': TextStyle(color: Horizon.teal),
    'meta-keyword': TextStyle(color: Horizon.violet),
    'doctag': TextStyle(color: Horizon.yellow),
    'name': TextStyle(color: Horizon.teal),
    'type': TextStyle(color: Horizon.teal),
    'string': TextStyle(color: Horizon.yellow),
    'number': TextStyle(color: Horizon.orange),
    'selector-id': TextStyle(color: Horizon.teal),
    'selector-class': TextStyle(color: Horizon.teal),
    'quote': TextStyle(color: Horizon.yellow),
    'template-tag': TextStyle(color: Horizon.teal),
    'deletion': TextStyle(color: Horizon.red),
    'title': TextStyle(color: Horizon.teal),
    'section': TextStyle(color: Horizon.blue),
    'regexp': TextStyle(color: Horizon.yellow),
    'symbol': TextStyle(color: Horizon.orange),
    'variable': TextStyle(color: Horizon.red),
    'template-variable': TextStyle(color: Horizon.red),
    'link': TextStyle(color: Horizon.yellow),
    'selector-attr': TextStyle(color: Horizon.teal),
    'selector-pseudo': TextStyle(color: Horizon.teal),
    'literal': TextStyle(color: Horizon.orange),
    'built_in': TextStyle(color: Horizon.violet),
    'bullet': TextStyle(color: Horizon.base4),
    'code': TextStyle(color: Horizon.orange),
    'addition': TextStyle(color: Horizon.green),
    'meta': TextStyle(color: Horizon.yellow),
    'meta-string': TextStyle(color: Horizon.yellow),
    'emphasis': TextStyle(fontStyle: FontStyle.italic),
    'strong': TextStyle(fontWeight: FontWeight.bold),
  },
);
