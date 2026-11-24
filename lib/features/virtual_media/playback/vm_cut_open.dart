import 'package:iris/features/fake_cut/playback/fake_cut_session.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';

/// What one merged cut-segment open produced.
typedef VmCutOpen = ({FakeCutSession? session, bool regroup});

/// Opens the plan a merged cut segment resolved and reports whether the LIVE
/// merge has to be re-derived afterwards (ADR 0034).
///
/// The player always re-reads the `.llc`, so a plan edited on disk (LosslessCut
/// keeps writing the same file) opens the FRESH timeline while the group still
/// displays the OLD kept length. [VmCutRange.planSignature] is the content
/// signature the group was built with; comparing it with the opened session
/// detects exactly that disagreement (and the plan disappearing, which reads as
/// a mismatch because [session] is then null).
///
/// [regroup] is a request, not a guarantee: the concrete re-derive is
/// idempotent — the next group carries the fresh signature, so the following
/// open does not ask again. A null session for an unrelated reason (unwritable
/// temp dir, unreadable source) also asks for one; that costs a re-resolve and
/// never loops, because the group shape did not change.
VmCutOpen vmCutOpenResult(VmCutRange range, FakeCutSession? session) => (
      session: session,
      regroup: session == null || session.signature != range.planSignature,
    );
