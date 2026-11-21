import 'package:material_ui/material_ui.dart';
import 'package:orgro/l10n/app_localizations.dart';
import 'package:orgro/src/debug.dart';
import 'package:orgro/src/file_picker.dart';
import 'package:orgro/src/notes_settings.dart';
import 'package:orgro/src/preferences.dart';

/// Rebuilds when the notes settings change, loading them first
class _NotesSettingsBuilder extends StatefulWidget {
  const _NotesSettingsBuilder({required this.builder});

  final Widget Function(BuildContext, NotesSettings) builder;

  @override
  State<_NotesSettingsBuilder> createState() => _NotesSettingsBuilderState();
}

class _NotesSettingsBuilderState extends State<_NotesSettingsBuilder> {
  final _settings = NotesSettings.instance;

  @override
  void initState() {
    super.initState();
    _settings.addListener(_onChanged);
    _settings.ensureLoaded();
  }

  @override
  void dispose() {
    _settings.removeListener(_onChanged);
    super.dispose();
  }

  void _onChanged() => setState(() {});

  @override
  Widget build(BuildContext context) => widget.builder(context, _settings);
}

/// The org-roam notes folder: indexed by the node finder and text search,
/// where voice notes are saved, and the base of the bibliography path
class NotesFolderSettingListItem extends StatelessWidget {
  const NotesFolderSettingListItem({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _NotesSettingsBuilder(
      builder: (context, settings) => ListTile(
        title: Text(l10n.settingsItemNotesFolder),
        subtitle: Text(settings.dirName ?? l10n.settingsItemNotesFolderUnset),
        trailing: settings.dirIdentifier == null
            ? null
            : IconButton(
                tooltip: l10n.settingsItemNotesFolderClear,
                icon: const Icon(Icons.clear),
                onPressed: () =>
                    settings.setNotesDir(identifier: null, name: null),
              ),
        onTap: () => _pick(context, settings),
      ),
    );
  }

  Future<void> _pick(BuildContext context, NotesSettings settings) async {
    try {
      final dir = await pickDirectory();
      if (dir == null || !context.mounted) return;
      // Picking grants access too
      await Preferences.of(
        context,
        PrefsAspect.nil,
      ).addAccessibleDir(dir.identifier);
      await settings.setNotesDir(identifier: dir.identifier, name: dir.name);
    } catch (e, s) {
      logError(e, s);
      if (context.mounted) showErrorSnackBar(context, e);
    }
  }
}

/// Path of the .bib file inside the notes folder
class BibliographySettingListItem extends StatelessWidget {
  const BibliographySettingListItem({super.key});

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return _NotesSettingsBuilder(
      builder: (context, settings) => ListTile(
        title: Text(l10n.settingsItemBibliography),
        subtitle: Text(settings.bibliographyPath),
        onTap: () => _edit(context, settings),
      ),
    );
  }

  Future<void> _edit(BuildContext context, NotesSettings settings) async {
    final l10n = AppLocalizations.of(context)!;
    final controller = TextEditingController(text: settings.bibliographyPath);
    final result = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(l10n.settingsItemBibliography),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(l10n.settingsItemBibliographyHelp),
            TextField(
              controller: controller,
              autofocus: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(
                hintText: kDefaultBibliographyPath,
              ),
              onSubmitted: (value) => Navigator.pop(context, value),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, kDefaultBibliographyPath),
            child: Text(l10n.settingsItemBibliographyReset),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, controller.text),
            child: Text(l10n.voiceSave),
          ),
        ],
      ),
    );
    controller.dispose();
    if (result != null) await settings.setBibliographyPath(result);
  }
}
