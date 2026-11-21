import 'package:flutter/material.dart';
import 'package:iris/features/background_playback/engine/background_queue_logic.dart';
import 'package:iris/features/background_playback/model/domain/background_mapping.dart';
import 'package:iris/features/background_playback/model/domain/segment_edit_draft.dart';
import 'package:iris/features/background_playback/model/enum/mapping_action.dart';
import 'package:iris/features/background_playback/resolver/active_mapping_resolver.dart';
import 'package:iris/features/background_playback/services/background_duration_probe.dart';
import 'package:iris/features/background_playback/store/use_apb_edit_session_store.dart';
import 'package:iris/features/background_playback/store/use_background_mapping_staging_store.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/bg_save_dialogs.dart';
import 'package:iris/features/background_playback/view/segment_edit_context.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

/// The media key of the 副音 file a draft names, in the SAME space
/// [backgroundMediaKey] uses for a live file (a SAF document uri owns the
/// identity when the segment path is empty).
String draftBgMediaKey(String storageId, String path) {
  final List<String> segments =
      path.contains('://') ? const <String>[] : path.split('/');
  return canonicalProgressKey(storageId, segments, uri: path);
}

/// The [FileItem] view of a draft's bg file, for the shared duration reader.
FileItem draftBgFile(String storageId, String path) {
  final List<String> segments =
      path.contains('://') ? const <String>[] : path.split('/');
  return FileItem(
    storageId: storageId,
    name: segments.isEmpty ? path : segments.last,
    uri: path.contains('://') ? path : '',
    path: segments,
  );
}

/// The bg total a saved row must record: the duration of the file the DRAFT
/// names, never whatever the engine happens to hold.
///
/// [SegmentEditContext.bgDurMs] is the LIVE engine duration while an existing
/// segment keeps its own `bgStorageId`/`bgPath` from the DB row. Opening the
/// editor from a playhead that is not inside a segment (the engine still plays
/// another bg file, or the natural queue) measured and normalized A/B against a
/// FOREIGN duration: the persisted `bgStartN`/`bgEndN` then covered the wrong
/// region in the manager overview.
///
/// Null (unknown) is the honest answer when the draft's own file has no
/// resolvable duration — a fabricated axis is worse.
Future<int?> resolveDraftBgTotalMs({
  required SegmentEditDraft draft,
  required int engineBgDurMs,
  required String? engineBgKey,
  required Future<int?> Function(String storageId, String path) lookup,
}) async {
  final String? storageId = draft.bgStorageId;
  final String? path = draft.bgPath;
  if (storageId == null ||
      storageId.isEmpty ||
      path == null ||
      path.isEmpty ||
      !draft.isPlayMedia) {
    // A silence segment has no bg axis at all.
    return null;
  }
  if (engineBgDurMs > 0 &&
      engineBgKey != null &&
      engineBgKey == draftBgMediaKey(storageId, path)) {
    return engineBgDurMs;
  }
  final int? resolved = await lookup(storageId, path);
  return (resolved != null && resolved > 0) ? resolved : null;
}

/// Result of a commit attempt, surfaced to the user as a dialog.
class SegmentCommitOutcome {
  const SegmentCommitOutcome(
    this.ok,
    this.title,
    this.message, {
    this.segments,
  });

  final bool ok;
  final String title;
  final String message;

  /// The timeline written by a SUCCESSFUL save — the resolved axis preview.
  final List<MappingSegment>? segments;
}

/// Persists the in-progress A-B draft and reports the outcome.
///
/// v34 save semantics (activation order, not deletion):
///  * A NEW draft (no saved origin) is appended and takes the next activation
///    sequence — no question is asked, and the confirmation shows the RESOLVED
///    axis (overlap winners only) exactly like the manager overview.
///  * A draft opened ON an in-use saved segment asks overwrite-vs-new first:
///    overwrite replaces that row keeping its lit position (default), while
///    save-as-new appends with the next sequence so it wins wherever it
///    overlaps.
///
/// [action] is taken from the pressed button (add as bg / add as silence)
/// rather than the draft, so the same span can be committed either way.
///
/// On success the editor closes; on failure it stays open with the draft
/// intact so the user can fix the span.
Future<void> commitSegmentEdit(
  BuildContext context,
  SegmentEditContext ctx, {
  required MappingAction action,
  SegmentEditDraft? draftOverride,
}) async {
  final t = getLocalizations(context);
  final navigator = Navigator.of(context, rootNavigator: true);

  SegmentCommitOutcome fail(String message) =>
      SegmentCommitOutcome(false, t.bg_segment_save_fail_title, message);

  late SegmentCommitOutcome outcome;
  final draft = draftOverride ?? ctx.draft;
  if (draft == null) {
    outcome = fail(t.bg_segment_save_missing_draft);
  } else if (ctx.fgStorageId.isEmpty ||
      ctx.fgPath.isEmpty ||
      ctx.fgDurMs <= 0) {
    outcome = fail(t.bg_segment_save_no_fg);
  } else if (draft.span.lengthMs <
      useBackgroundPlaybackStore().state.minSegmentSpanMs) {
    outcome = fail(t.bg_segment_save_empty_span);
  } else if (action == MappingAction.playMedia &&
      (draft.bgStorageId == null ||
          draft.bgStorageId!.isEmpty ||
          draft.bgPath == null ||
          draft.bgPath!.isEmpty)) {
    outcome = fail(t.bg_segment_need_bg);
  } else {
    // A draft opened on an in-use saved segment must decide overwrite (default)
    // vs save-as-new; a brand-new draft never asks.
    var asNew = !draft.hasOrigin;
    if (draft.hasOrigin && context.mounted) {
      final choice = await showBgSaveConflictDialog(
        context,
        name: _displayName(draft, t.bg_mapping_manager_silence),
      );
      if (choice == null) return; // dismissed: keep editing
      asNew = choice == BgSaveConflictChoice.asNew;
    }
    if (!context.mounted) return;

    final seq = asNew
        ? ActiveMappingResolver.nextActiveSeq(ctx.allSegments)
        : draft.activeSeq;
    // The row records the duration of the file the DRAFT names: the live engine
    // duration only describes the file it happens to hold (see the helper).
    final int? bgTotalMs = await resolveDraftBgTotalMs(
      draft: draft,
      engineBgDurMs: ctx.bgDurMs,
      engineBgKey: ctx.bgFile == null ? null : backgroundMediaKey(ctx.bgFile!),
      lookup: (storageId, path) async {
        final byKey = await resolvedBgDurationsByKey(
          <FileItem>[draftBgFile(storageId, path)],
        );
        return byKey.isEmpty ? null : byKey.values.first;
      },
    );
    if (!context.mounted) return;
    final built = draft.copyWith(action: action, activeSeq: seq).toSegment(
          fgTotalMs: ctx.fgDurMs,
          bgTotalMs: bgTotalMs,
        );
    // A save-as-new row must be a fresh DB row (the draft still carries the
    // origin's id for the overwrite path).
    final next = asNew ? built.copyWith(id: 0, activeSeq: seq) : built;

    final finalSegments = ActiveMappingResolver.mergeSegment(
      all: ctx.allSegments,
      next: next,
      asNew: asNew,
      editingId: draft.editingId,
    );

    if (useBackgroundPlaybackStore().state.segmentEditStageOnly) {
      // Manager edit: write into the session staging draft, never the DB. The
      // manager's explicit Apply performs the actual commit.
      try {
        final staging = useBackgroundMappingStagingStore();
        final key = BackgroundMappingStagingStore.stagingKey(
          ctx.fgStorageId,
          ctx.fgPath,
        );
        final baseline =
            staging.stagedFor(key)?.baselineUpdatedAt ?? ctx.baselineUpdatedAt;
        staging.stage(
          BackgroundMappingTimeline(
            storageId: ctx.fgStorageId,
            path: ctx.fgPath,
            fgTotalMs: ctx.fgDurMs,
            segments: finalSegments,
          ),
          baselineUpdatedAt: baseline,
        );
        outcome = SegmentCommitOutcome(
          true,
          t.bg_segment_save_ok_title,
          t.bg_mapping_manager_staged_ok_body,
          segments: finalSegments,
        );
      } catch (e) {
        outcome = fail('${t.bg_segment_save_write_failed}\n$e');
      }
    } else {
      var writeFailed = false;
      try {
        await DbModule.bgMappingRepo.saveTimeline(
          storageId: ctx.fgStorageId,
          path: ctx.fgPath,
          fgTotalMs: ctx.fgDurMs,
          segments: finalSegments,
        );
      } catch (e) {
        writeFailed = true;
        outcome = fail('${t.bg_segment_save_write_failed}\n$e');
      }
      if (!writeFailed) {
        // Post-write verification: re-read the timeline and confirm as many
        // rows landed as were requested. A silently rejected/mis-counted write
        // is reported instead of claimed as success.
        int written;
        try {
          final reloaded = await DbModule.bgMappingRepo.getTimelineForFg(
            storageId: ctx.fgStorageId,
            path: ctx.fgPath,
          );
          written = reloaded?.segments.length ?? 0;
        } catch (_) {
          written = -1;
        }
        if (written == finalSegments.length) {
          outcome = SegmentCommitOutcome(
            true,
            t.bg_mapping_manager_save_preview_title,
            t.bg_mapping_manager_save_preview_body,
            segments: finalSegments,
          );
        } else {
          outcome = fail(
            written < 0
                ? t.bg_segment_save_verify_failed
                : t.bg_segment_save_count_mismatch(
                    finalSegments.length, written),
          );
        }
      }
    }
  }

  if (outcome.ok) {
    // A real save supersedes any session overlay for this fg: drop it so the
    // freshly committed DB row is what the runtime reads from here on.
    useBackgroundMappingStagingStore().discardApbOverlay(
      BackgroundMappingStagingStore.stagingKey(ctx.fgStorageId, ctx.fgPath),
    );
    useBackgroundPlaybackStore().exitSegmentEdit();
    // A manager-driven edit opened a transient single-fg context; close it so
    // the previous playback context (SystemPlaying / another entry) resumes.
    await closeActiveApbEditSession();
    if (navigator.mounted) {
      // Show the RESOLVED axis after the save (winners only), matching the
      // manager overview rather than the raw full values.
      await showBgSaveResultDialog(
        navigator.context,
        segments: outcome.segments ?? const <MappingSegment>[],
        fgTotalMs: ctx.fgDurMs,
        title: outcome.title,
        message: outcome.message,
      );
    }
    return;
  }
  if (navigator.mounted) {
    await showMessageDialog(
      navigator,
      title: outcome.title,
      message: outcome.message,
      type: MessageDialogType.error,
    );
  }
}

String _displayName(SegmentEditDraft draft, String silenceLabel) {
  final path = draft.bgPath;
  if (path == null || path.isEmpty) return silenceLabel;
  final i = path.lastIndexOf('/');
  return i < 0 ? path : path.substring(i + 1);
}

/// Stages the in-progress draft as an A-B editor SESSION overlay, so a
/// commit-less exit still makes the alignment live in memory for the current
/// playback (the runtime keeps reading the committed DB until this overlay
/// exists, and drops it on session close / file switch / stop).
///
/// Mirrors the save path's overlap resolution ([ActiveMappingResolver.mergeSegment])
/// so the in-memory result is exactly what Save would have written. No-op when
/// the context has no usable foreground or an empty span.
void stageApbOverlayFromDraft(SegmentEditContext ctx, SegmentEditDraft draft) {
  if (ctx.fgStorageId.isEmpty || ctx.fgPath.isEmpty || ctx.fgDurMs <= 0) return;
  if (draft.span.lengthMs <
      useBackgroundPlaybackStore().state.minSegmentSpanMs) {
    return;
  }
  // Overwrite semantics: a draft with no origin is a newly appended row taking
  // the next activation sequence; a re-edited row keeps its own id/sequence.
  final bool asNew = !draft.hasOrigin;
  final int seq = asNew
      ? ActiveMappingResolver.nextActiveSeq(ctx.allSegments)
      : draft.activeSeq;
  final built = draft.copyWith(activeSeq: seq).toSegment(
        fgTotalMs: ctx.fgDurMs,
        bgTotalMs: ctx.bgDurMs > 0 ? ctx.bgDurMs : null,
      );
  final next = asNew ? built.copyWith(id: 0, activeSeq: seq) : built;
  final merged = ActiveMappingResolver.mergeSegment(
    all: ctx.allSegments,
    next: next,
    asNew: asNew,
    editingId: draft.editingId,
  );
  useBackgroundMappingStagingStore().stageApbOverlay(
    BackgroundMappingTimeline(
      storageId: ctx.fgStorageId,
      path: ctx.fgPath,
      fgTotalMs: ctx.fgDurMs,
      segments: merged,
    ),
  );
}
