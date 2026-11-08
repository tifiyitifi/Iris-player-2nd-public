import 'dart:io';

import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/features/fake_cut/services/fake_cut_edl_builder.dart';
import 'package:iris/features/fake_cut/services/fake_cut_subtitle_remapper.dart';
import 'package:iris/models/file.dart';
import 'package:iris/utils/logger.dart';
import 'package:path_provider/path_provider.dart';

final _log = AreaKeyLog(LogKeys.legacyPlayer);

/// One live 简播 playback: the plan plus the EDL media that was opened for it.
///
/// The session is a SNAPSHOT. The player hook keeps it in a ref and reads it at
/// every progress write, so switching plans cannot retroactively re-map the
/// position of the file that was just left with the new plan's timeline.
class FakeCutSession {
  const FakeCutSession({
    required this.plan,
    required this.edlPath,
    required this.sourceDurationMs,
    required this.signature,
  });

  final FakeCutPlan plan;

  /// Absolute path of the generated `.edl` (the media handed to media_kit).
  final String edlPath;

  /// KNOWN container duration of the source, 0 when never probed.
  ///
  /// The EDL's own duration is the CUT length and must never be written to
  /// `media_nodes.duration_ms`, so every duration write uses this value (or is
  /// skipped when it is unknown).
  final int sourceDurationMs;

  /// Plan content signature (see [fakeCutPlanSignature]).
  final String signature;

  /// Virtual (cut) position → source position, for persistence.
  int toSourceMs(int fakeMs) => plan.timeline.toSourceMs(fakeMs);

  /// Source duration when known, else null (the DB column stays untouched).
  int? get sourceDurationOrNull => sourceDurationMs > 0 ? sourceDurationMs : null;

  /// Duration for DISPLAY only, on the source axis: the real duration when
  /// known, else the plan's furthest range end (a lower bound).
  int get displaySourceDurationMs => sourceDurationMs > 0
      ? sourceDurationMs
      : plan.sourceSpanEndMs;

  @override
  String toString() => 'FakeCutSession(${plan.displayName}, '
      '${plan.segments.length} segs, srcDur=$sourceDurationMs)';
}

/// Builds the EDL for [plan] and returns the session to open.
///
/// Returns null when the timeline cannot be prepared (unwritable temp dir, or a
/// source path that is not a readable file). The caller then opens the plain
/// source: 简播 must never make a playable file unplayable.
Future<FakeCutSession?> prepareFakeCutSession({
  required FakeCutPlan plan,
  required FileItem file,
}) async {
  if (plan.segments.isEmpty) return null;
  if (!await File(file.uri).exists()) {
    _log.w('fake cut: source is not a readable file: ${file.uri}');
    return null;
  }
  final String signature = fakeCutPlanSignature(plan);
  try {
    final Directory tempRoot = await getTemporaryDirectory();
    final FakeCutEdlFile edl = await prepareFakeCutEdl(
      plan: plan,
      sourcePath: file.uri,
      signature: signature,
      tempRoot: tempRoot,
    );
    return FakeCutSession(
      plan: plan,
      edlPath: edl.path,
      sourceDurationMs: file.durationMs ?? 0,
      signature: signature,
    );
  } catch (e) {
    _log.w('fake cut: could not prepare the EDL: $e');
    return null;
  }
}

/// The session an OPEN may use for [file], or null for the untouched source.
///
/// TOTAL by contract, unlike the two halves it composes:
///  * [resolvePlan] (`FakeCutStore.ensureActivePlan`) reads and parses the `.llc`
///    — a hand-edited project used to throw out of it, which aborted the whole
///    player `init`;
///  * [prepareFakeCutSession] can still fail on an unwritable temp dir.
///
/// Either way the answer is "play the source": a broken project must cost the
/// cut, never the open. The caller MUST also start from "no session" (assign
/// null before awaiting this), so a failure can never leave the PREVIOUS file's
/// plan attached to the file being opened.
Future<FakeCutSession?> resolveFakeCutSessionFor({
  required FileItem file,
  required Future<FakeCutPlan?> Function(FileItem file) resolvePlan,
}) async {
  try {
    final FakeCutPlan? plan = await resolvePlan(file);
    if (plan == null) return null;
    return await prepareFakeCutSession(plan: plan, file: file);
  } catch (e) {
    _log.w('fake cut: no usable session, playing the source: ${file.uri}: $e');
    return null;
  }
}

/// Re-times an external subtitle for [session], or reports why it could not.
Future<FakeCutSubtitleResult> remapFakeCutSubtitle({
  required FakeCutSession session,
  required String subtitlePath,
}) async {
  final Directory tempRoot = await getTemporaryDirectory();
  return FakeCutSubtitleRemapper.remap(
    plan: session.plan,
    subtitlePath: subtitlePath,
    signature: session.signature,
    tempRoot: tempRoot,
  );
}
