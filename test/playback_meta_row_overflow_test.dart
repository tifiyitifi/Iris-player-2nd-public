import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/scenario_playback/view/widgets/playback_meta_row.dart';
import 'package:iris/features/window/playlist_dock/resolve_playlist_theme.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/widgets/chip.dart' as iris_widgets;

MediaNode _video({int size = 3 * 1024 * 1024 * 1024, int duration = 0}) =>
    MediaNode.file(
      id: 'st1:Shorts/1.mp4',
      storageId: 'st1',
      path: const ['Shorts', '1.mp4'],
      parentPath: 'Shorts',
      name: '1.mp4',
      mediaType: MediaType.video,
      sizeInBytes: size,
      durationMs: duration,
    );

PlaybackMetaRow _worstCaseMergedRow() => PlaybackMetaRow(
      // Merged totals + both secondary badges + sort date + progress, i.e. the
      // full content set a merged row can carry.
      size: 12 * 1024 * 1024 * 1024,
      durationMs: 12 * 3600 * 1000,
      isMerged: true,
      segmentCount: 12,
      sortValue: '2026-09-19 14:30',
      showProgress: true,
      media: _video(),
      fileDurationMs: 3600 * 1000,
      isCurrent: true,
      duplicated: true,
      occurrenceIndex: 2,
      explicit: true,
    );

Future<void> _pumpInTile(
  WidgetTester tester,
  PlaybackMetaRow row, {
  ThemeData? theme,
}) async {
  await tester.pumpWidget(MaterialApp(
    theme: theme,
    localizationsDelegates: AppLocalizations.localizationsDelegates,
    supportedLocales: AppLocalizations.supportedLocales,
    home: Scaffold(
      body: ListView(
        children: [
          ListTile(
            contentPadding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
            leading: const Icon(Icons.graphic_eq, size: 16),
            // Mirrors the queue tile trailing: 40px disclosure + 48px menu.
            trailing: const SizedBox(
              width: 88,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [SizedBox(width: 40), SizedBox(width: 48)],
              ),
            ),
            title: const Text('[vm] Shorts · 1/3 · 001-012'),
            subtitle: row,
          ),
        ],
      ),
    ),
  ));
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('merged meta row never overflows a 320px phone', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpInTile(tester, _worstCaseMergedRow());

    expect(tester.takeException(), isNull);
  });

  testWidgets('summary line is a single ellipsized Text', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpInTile(tester, _worstCaseMergedRow());

    final summary = tester.widget<Text>(find.textContaining('seg'));
    expect(summary.maxLines, 1);
    expect(summary.overflow, TextOverflow.ellipsis);
  });

  testWidgets('secondary badges get their own line when present',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpInTile(tester, _worstCaseMergedRow());

    // Duplicate badge and the explicit-item chip are rendered, but below the
    // summary line. The chip text is localized (never the old hardcoded
    // "Added", which read like the "added to play queue" state).
    final summaryTop = tester.getTopLeft(find.textContaining('seg')).dy;
    final explicitTop = tester.getTopLeft(find.text('explicit item')).dy;
    expect(explicitTop, greaterThan(summaryTop));
    expect(find.text('Added'), findsNothing);
  });

  testWidgets('ordinary (non-merged) row still renders its size and duration',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await _pumpInTile(
      tester,
      PlaybackMetaRow(
        size: 700 * 1024 * 1024,
        durationMs: 65 * 1000,
        isMerged: false,
        segmentCount: 1,
        showProgress: false,
        media: _video(),
        fileDurationMs: 65 * 1000,
        isCurrent: false,
        duplicated: false,
        occurrenceIndex: 0,
        explicit: false,
      ),
    );

    expect(tester.takeException(), isNull);
    expect(find.textContaining('01:05'), findsOneWidget);
  });

  testWidgets('the explicit marker is plain, aligned, and deliberately grey',
      (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 640));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    // Both surfaces the queue is painted on: the desktop dock's fixed dark
    // PotPlayer palette (where the old badge was reported) and a light theme.
    for (final theme in <ThemeData?>[potlikeDarkTheme(), null]) {
      await _pumpInTile(tester, _worstCaseMergedRow(), theme: theme);

      final marker = find.text('explicit item');
      expect(marker, findsOneWidget);
      // Ordinary text — no pill, no chip, no bold: every container shape still
      // pulled the eye away from the row title. (The duplicate-occurrence badge
      // on the same line keeps its pill; only THIS marker is plain.)
      expect(
        find.ancestor(of: marker, matching: find.byType(iris_widgets.Chip)),
        findsNothing,
      );
      expect(
          tester.widget<Text>(marker).style?.fontWeight, isNot(FontWeight.bold));
      // Aligned with the meta line above (same left edge), one line below it.
      final summary = find.textContaining('seg');
      expect(tester.getTopLeft(marker).dx, tester.getTopLeft(summary).dx);
      expect(tester.getTopLeft(marker).dy,
          greaterThan(tester.getTopLeft(summary).dy));

      // Deliberately grey: neither full-strength body text nor the backdrop,
      // with a visible margin from BOTH so it reads as a recessed label and
      // still stays legible (the old badge competed with the row title; a
      // marker that vanishes is equally wrong).
      final scheme = Theme.of(tester.element(marker)).colorScheme;
      final ink = tester.widget<Text>(marker).style!.color!;
      final onSurface = Color.alphaBlend(ink, scheme.surface).computeLuminance();
      final backdrop = scheme.surface.computeLuminance();
      final text = scheme.onSurface.computeLuminance();
      expect((onSurface - text).abs(), greaterThan(0.15));
      expect((onSurface - backdrop).abs(), greaterThan(0.05));
    }
  });
}
