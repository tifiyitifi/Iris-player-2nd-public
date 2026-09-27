import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:iris/features/app_update/services/release_notes.dart';
import 'package:iris/utils/get_latest_release.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/url.dart';

/// Legacy dialog kept for the About page's compatibility branch.
///
/// The real update dialogs live in `features/app_update/view`; this one only
/// adapts the legacy [Release] shape (a flat, already-resolved package) into
/// the module's markdown notes rendering. It has no download path of its own:
/// installing an update belongs to the module, because the legacy version could
/// only ever run the upstream `iris-updater.bat`, which this build does not
/// ship.
Future<void> showReleaseDialog(
  BuildContext context, {
  required Release release,
}) =>
    showDialog<void>(
      context: context,
      builder: (ctx) => _LegacyReleaseDialog(release: release),
    );

class _LegacyReleaseDialog extends StatelessWidget {
  const _LegacyReleaseDialog({required this.release});

  final Release release;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);

    final notes = localizedReleaseNotes(
      release.changeLog,
      notesLanguageForLocale(Localizations.localeOf(context).languageCode),
    );

    return AlertDialog(
      title: Text('${t.checked_new_version}: ${release.version}'),
      content: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 600),
        child: SingleChildScrollView(
          child: MarkdownBody(data: notes, shrinkWrap: true),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.cancel),
        ),
        TextButton(
          onPressed: () => launchURL(release.url),
          child: Text(t.releasePage),
        ),
      ],
    );
  }
}
