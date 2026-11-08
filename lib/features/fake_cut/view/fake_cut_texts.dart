import 'package:iris/features/fake_cut/core/fake_cut_preflight.dart';
import 'package:iris/features/fake_cut/model/domain/fake_cut_plan.dart';
import 'package:iris/l10n/app_localizations.dart';

/// Localized explanation for a blocked 简播 environment.
///
/// Kept out of the widget so every mapping is unit-testable and no user-facing
/// text can drift into a hardcoded literal (house rule: l10n only).
String fakeCutBlockedText(AppLocalizations t, FakeCutBlockReason reason) {
  switch (reason) {
    case FakeCutBlockReason.backend:
      return t.fake_cut_blocked_backend;
    case FakeCutBlockReason.unsupportedStorage:
      return t.fake_cut_blocked_storage;
    case FakeCutBlockReason.notVideo:
      return t.fake_cut_blocked_not_video;
    case FakeCutBlockReason.none:
      return '';
  }
}

/// One notice line plus how prominently it should be shown.
///
/// A marker being ignored is EXPECTED LosslessCut behaviour (many projects carry
/// markers), so it is informational; a dropped/clamped range or a foreign
/// project is a warning the user must see.
class FakeCutNoticeLine {
  const FakeCutNoticeLine(this.text, {required this.isWarning});

  final String text;
  final bool isWarning;
}

/// One localized line per notice the plan builder recorded, in display order.
///
/// Each notice is a PRODUCT TRADEOFF surfaced to the user (markers excluded,
/// ranges clamped, …) rather than a silent adjustment.
List<FakeCutNoticeLine> fakeCutNoticeLines(AppLocalizations t, FakeCutPlan plan) {
  return plan.notices.map((FakeCutNotice notice) {
    switch (notice.kind) {
      case FakeCutNoticeKind.markersIgnored:
        return FakeCutNoticeLine(t.fake_cut_markers_ignored(notice.count),
            isWarning: false);
      case FakeCutNoticeKind.deselectedIgnored:
        return FakeCutNoticeLine(t.fake_cut_deselected_ignored(notice.count),
            isWarning: false);
      case FakeCutNoticeKind.selectedFallback:
        return FakeCutNoticeLine(t.fake_cut_selected_fallback,
            isWarning: false);
      case FakeCutNoticeKind.invalidDropped:
        return FakeCutNoticeLine(t.fake_cut_invalid_dropped(notice.count),
            isWarning: true);
      case FakeCutNoticeKind.clampedToSource:
        return FakeCutNoticeLine(t.fake_cut_clamped(notice.count),
            isWarning: true);
      case FakeCutNoticeKind.tooShort:
        return FakeCutNoticeLine(t.fake_cut_too_short(notice.count),
            isWarning: true);
      case FakeCutNoticeKind.fileMismatch:
        return FakeCutNoticeLine(
            t.fake_cut_file_mismatch(notice.detail ?? ''),
            isWarning: true);
    }
  }).toList();
}
