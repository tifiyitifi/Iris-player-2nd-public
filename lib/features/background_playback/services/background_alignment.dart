/// Alignment of a freshly picked 副音 file against the foreground timeline.
///
/// Alignment always targets the CURRENT REAL single file: the caller passes the
/// physical foreground window (a Virtual Media merge is undone before the
/// decision), never the merged virtual duration.
///
/// The anchor is a pair `(fgAnchorMs, bgAnchorMs)`: the foreground position that
/// maps to the 副音 position. All bg positions are derived from the fg progress
/// and this anchor (`bgPos = fgPos - (fgAnchorMs - bgAnchorMs)`), never read
/// from or written to the media-node progress rows.
///
/// The mode applied on every FRESH anchor (the first file of a run, a user
/// switch, or an explicit restart) is decided AUTOMATICALLY from the two real
/// durations by [resolveAutoAlignAnchor] — the persisted [BgAlignDefault] no
/// longer drives it (it is kept as a manual preference; see the known-issues
/// entry). There is no "ask on shorter bg" branch: a mandatory remaining-time
/// threshold ([shouldWarnBgRunningOut]) raises the prompt instead, and it is
/// skipped entirely for a tail-anchored pair.
library;

import 'package:iris/features/background_playback/model/enum/bg_align_default.dart';
import 'package:iris/features/background_playback/model/enum/bg_align_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_exhausted_action.dart';

/// Default "start from this share" when the user asks for a percentage.
const int kDefaultAlignPercent = 30;

/// Default remaining-副音 time (seconds) below which the alignment popup is
/// raised ("对齐后 bg 可播放时间 < xxx"). The setting is mandatory, so this is
/// always active.
const int kDefaultAlignWarnRemainSec = 5;

/// Lower bound of the mandatory remaining-time threshold.
const int kMinAlignWarnRemainSec = 1;

/// Upper bound of the mandatory remaining-time threshold.
const int kMaxAlignWarnRemainSec = 120;

/// Clamps a stored remaining-time threshold into the supported range.
int clampAlignWarnRemainSec(int seconds) =>
    seconds.clamp(kMinAlignWarnRemainSec, kMaxAlignWarnRemainSec);

/// The playable remainder of the aligned 副音, in milliseconds.
///
/// Without a 仅当前 window this is the raw file remainder (`bgDur - bgPos`).
/// With one, the window ceiling (the bg position mapped to fg 100%) caps it:
/// anything past the ceiling is unplayable (clamped/paused by the runtime
/// observer), so it must not count toward — or against — the threshold. A bg
/// already parked past the ceiling floors at zero.
int bgEffectiveRemainingMs({
  required int bgDurMs,
  required int bgPosMs,
  int? ceilingLocalMs,
}) {
  final int pos = bgPosMs < 0 ? 0 : bgPosMs;
  var remaining = bgDurMs - pos;
  if (ceilingLocalMs != null && ceilingLocalMs - pos < remaining) {
    remaining = ceilingLocalMs - pos;
  }
  return remaining < 0 ? 0 : remaining;
}

/// Whether the alignment popup should be raised because the aligned 副音 is
/// about to run out: `bgDur - bgPos < threshold`.
///
/// `bgPos` is the 副音 position AFTER alignment, so this is "对齐后 bg 可播放
/// 时间". An unknown duration never warns.
///
/// Under 仅当前 + 高同步 the [ceilingLocalMs] window ceiling caps the
/// remainder (see [bgEffectiveRemainingMs]); a bg parked past the ceiling is
/// NOT warned here — the runtime observer owns that state and the caller
/// skips the prompt for it.
bool shouldWarnBgRunningOut({
  required int bgDurMs,
  required int bgPosMs,
  int thresholdSec = kDefaultAlignWarnRemainSec,
  int? ceilingLocalMs,
}) {
  if (bgDurMs <= 0) return false;
  final int t = clampAlignWarnRemainSec(thresholdSec);
  final int remaining = bgEffectiveRemainingMs(
    bgDurMs: bgDurMs,
    bgPosMs: bgPosMs,
    ceilingLocalMs: ceilingLocalMs,
  );
  return remaining < t * 1000;
}

/// Whether the mandatory remaining-副音 prompt should be raised at all.
///
/// The prompt exists so the user can react to a 副音 that is about to run out.
/// Under [BgExhaustedAction.nextBg] there is nothing to react to — the
/// continuation is automatic (the next queued file starts at the video moment
/// the previous one ended, looping the list), so the prompt is suppressed and
/// playback is never interrupted. It is kept for
/// [BgExhaustedAction.stopRestoreFg], where the user must be able to learn that
/// 副音 will stop and the video's own audio returns.
///
/// [tailAnchored] suppresses it too: a tail-anchored pair (see
/// [BgAlignMode.tailAtFg]) runs out exactly when the VIDEO does, so the prompt
/// could only fire in the last seconds of both — nothing to react to.
bool shouldRaiseAlignThreshold({
  required bool enabled,
  required bool gateOpen,
  required BgExhaustedAction exhaustedAction,
  required int bgDurMs,
  required int bgPosMs,
  required int thresholdSec,
  int? ceilingLocalMs,
  bool tailAnchored = false,
}) {
  if (!enabled || !gateOpen) return false;
  if (exhaustedAction == BgExhaustedAction.nextBg) return false;
  if (tailAnchored) return false;
  return shouldWarnBgRunningOut(
    bgDurMs: bgDurMs,
    bgPosMs: bgPosMs,
    thresholdSec: thresholdSec,
    ceilingLocalMs: ceilingLocalMs,
  );
}

/// The 副音 seek target for [percent]% of [bgDurMs] (clamped to 0..100%).
int alignPercentTargetMs(int bgDurMs, int percent) {
  if (bgDurMs <= 0) return 0;
  final int p = percent.clamp(0, 100);
  return (bgDurMs * p / 100).round().clamp(0, bgDurMs);
}

/// Resolves the running pair's alignment anchor pair for [mode].
///
/// [currentFgMs] is the foreground moment the anchor is taken at ("更新到
/// 当前"). The pair defines the fixed offset `fg - bg`.
///
/// [fgDurMs] is the foreground FILE duration — required by
/// [BgAlignMode.tailAtFg] (whose anchor is `fgDur ↔ bgDur`), ignored by the
/// other modes. When it is absent (or either duration is unknown) the tail mode
/// degrades to [BgAlignMode.sameClock] rather than inventing an anchor.
({int fgAnchorMs, int bgAnchorMs}) resolveAlignmentAnchor({
  required BgAlignMode mode,
  required int currentFgMs,
  required int bgDurMs,
  required int percent,
  int? fgDurMs,
}) {
  final int fg = currentFgMs < 0 ? 0 : currentFgMs;
  switch (mode) {
    case BgAlignMode.sameClock:
      return (fgAnchorMs: 0, bgAnchorMs: 0);
    case BgAlignMode.bgHeadAtFg:
      return (fgAnchorMs: fg, bgAnchorMs: 0);
    case BgAlignMode.bgPercent:
      return (
        fgAnchorMs: fg,
        bgAnchorMs: alignPercentTargetMs(bgDurMs, percent),
      );
    case BgAlignMode.tailAtFg:
      final int? fgDur = fgDurMs;
      if (fgDur == null || fgDur <= 0 || bgDurMs <= 0) {
        return (fgAnchorMs: 0, bgAnchorMs: 0);
      }
      return (fgAnchorMs: fgDur, bgAnchorMs: bgDurMs);
  }
}

/// The fixed `fg - bg` offset implied by an anchor pair.
int alignmentOffsetMs({required int fgAnchorMs, required int bgAnchorMs}) =>
    fgAnchorMs - bgAnchorMs;

/// Converts a FILE-LOCAL alignment offset into the queue-VIRTUAL offset the
/// position mirror compares against.
///
/// [resolveAlignmentOffsetMs] derives its offset on the aligned 副音 FILE's axis
/// (the axis [bgAlignTargetMs] seeks on), while the mirror, the seek window and
/// the cross-file continuation all work on the queue's VIRTUAL axis — where a
/// position additionally carries the file's prefix. Leaving the units mixed made
/// the pair report a phantom drift equal to that prefix, which the 高同步
/// correction then kept "fixing": the reported 对齐偏颇.
int alignmentVirtualOffsetMs({
  required int fileLocalOffsetMs,
  required int fileVirtualStartMs,
}) =>
    fileLocalOffsetMs - fileVirtualStartMs;

/// The queue index of the aligned file, or null when it is not in the window.
///
/// The queue-VIRTUAL pin is `fileLocalOffset - prefix`, and the prefix belongs
/// to the CURRENT window, so the aligned file must be located by its media KEY.
/// A numeric index is meaningless across a window rebuild: the runtime keeps the
/// PLAYING file and re-pages around it (a shuffle toggle, a candidate
/// re-resolve, a tag sync), so an index taken in the old order points at
/// unrelated content and no longer carries the aligned file's prefix.
///
/// [fallbackIndex] covers the moments BEFORE the first pin, when the aligned file
/// IS the open one and no key has been recorded yet. A key that is not in
/// [queueKeys] (the aligned file left the window) deliberately resolves to null:
/// its prefix is unknowable, so the caller must keep the previous pin instead of
/// re-deriving one from someone else's prefix.
int? resolveAlignAnchorIndex({
  required String? anchorKey,
  required List<String> queueKeys,
  int? fallbackIndex,
}) {
  if (anchorKey != null) {
    final int i = queueKeys.indexOf(anchorKey);
    return i >= 0 ? i : null;
  }
  if (fallbackIndex != null &&
      fallbackIndex >= 0 &&
      fallbackIndex < queueKeys.length) {
    return fallbackIndex;
  }
  return null;
}

/// The fixed `fg - bg` offset implied by aligning [mode] at [currentFgMs].
///
/// The counterpart of [bgAlignTargetMs] for the AUTHORITATIVE offset: a user
/// alignment (「更新到当前」/「00:00↔00:00」/ percent) stores this so the runtime
/// observer can keep the pair on the user's offset instead of re-deriving one
/// from position samples. See `BackgroundPlaybackState.alignOffsetMs`.
///
/// UNIT: this offset is FILE-LOCAL — it lives on the aligned 副音 FILE's axis
/// (the same axis [bgAlignTargetMs] seeks on). The queue's VIRTUAL axis (which
/// the position mirror and the seek window compare against) additionally carries
/// the file's prefix, so a consumer on that axis must subtract it
/// (`offset - timeline.offsetOf(index)`); otherwise the pair shows a phantom
/// drift equal to the prefix and the 高同步 correction keeps "fixing" it — the
/// reported 对齐偏颇.
int resolveAlignmentOffsetMs({
  required BgAlignMode mode,
  required int currentFgMs,
  required int bgDurMs,
  required int percent,
  int? fgDurMs,
}) {
  final anchor = resolveAlignmentAnchor(
    mode: mode,
    currentFgMs: currentFgMs,
    bgDurMs: bgDurMs,
    percent: percent,
    fgDurMs: fgDurMs,
  );
  return alignmentOffsetMs(
    fgAnchorMs: anchor.fgAnchorMs,
    bgAnchorMs: anchor.bgAnchorMs,
  );
}

/// The 副音 seek target for [mode] anchored at foreground moment [fgPosMs].
///
/// `target = fgPos - (fgAnchor - bgAnchor)`, clamped into the 副音 file. The
/// single source of truth for the popup's 「更新」区 and the runtime observer.
int bgAlignTargetMs({
  required BgAlignMode mode,
  required int fgPosMs,
  required int bgDurMs,
  required int percent,
  int? fgDurMs,
}) {
  final anchor = resolveAlignmentAnchor(
    mode: mode,
    currentFgMs: fgPosMs,
    bgDurMs: bgDurMs,
    percent: percent,
    fgDurMs: fgDurMs,
  );
  return (fgPosMs -
          alignmentOffsetMs(
            fgAnchorMs: anchor.fgAnchorMs,
            bgAnchorMs: anchor.bgAnchorMs,
          ))
      .clamp(0, bgDurMs <= 0 ? 0 : bgDurMs);
}

/// The 副音 seek a MODAL close must land on when the dialog left the engine on a
/// file the run had not aligned yet (see [modalCloseNeedsRealign]).
///
/// A named, [fgDurMs]-REQUIRED wrapper on purpose: the close path is an async
/// handler (no hooks), it used to call [bgAlignTargetMs] without the foreground
/// duration, and 尾部锚定 then degraded to 同刻度 — the closing dialog seeked to
/// the foreground moment instead of the tail-anchored position, silently, only
/// in the one mode whose anchor depends on that duration.
int modalCloseRealignTargetMs({
  required BgAlignMode mode,
  required int fgPosMs,
  required int fgDurMs,
  required int bgDurMs,
  required int percent,
}) =>
    bgAlignTargetMs(
      mode: mode,
      fgPosMs: fgPosMs,
      bgDurMs: bgDurMs,
      percent: percent,
      fgDurMs: fgDurMs,
    );

/// The AUTOMATIC anchoring decision, applied at every FRESH anchor: enabling
/// 副音, a user switch to another 副音 file (list click or panel step), or an
/// explicit restart-for-current.
///
/// It answers one question — which 副音 moment maps to the video's current
/// moment — from the two REAL durations alone. The 副音 side never virtualizes
/// and never takes an estimated duration, so this only needs the current
/// physical foreground file and the 副音 file being opened.
///
/// 1. 副音 NOT shorter than the video (`bgDur >= fgDur`): 同刻度 — the two share
///    one clock, so the 副音 position equals the video position and the 副音
///    keeps playing past the video's end (it ends exactly with it when the two
///    durations are equal).
/// 2. 副音 shorter AND the video's remaining time FITS inside it
///    (`fgDur - fgPos <= bgDur`): 尾部锚定 — the 副音's end lands on the video's
///    end, so the 副音 never runs out early. The price is that the 副音's
///    opening is skipped by exactly `bgDur - (fgDur - fgPos)`.
/// 3. Otherwise (`fgDur - fgPos > bgDur`): 副音 00:00 at the video's current
///    moment — start the 副音 from its head now.
///
/// Continuous at both boundaries: at `rem == bgDur` branches 2 and 3 both seek
/// to 00:00, and at `bgDur == fgDur` branches 1 and 2 both map the video
/// position onto itself — a millisecond of duration difference can never flip
/// the 副音 position. A degenerate duration (either side unknown) falls back to
/// 同刻度 instead of inventing a tail/head anchor.
({BgAlignMode mode, int fgAnchorMs, int bgAnchorMs}) resolveAutoAlignAnchor({
  required int bgDurMs,
  required int fgDurMs,
  required int fgPosMs,
}) {
  final int fg = fgDurMs < 0 ? 0 : fgDurMs;
  final int pos = fgPosMs < 0 ? 0 : fgPosMs;
  final int bg = bgDurMs < 0 ? 0 : bgDurMs;
  if (bg <= 0 || fg <= 0) {
    return (mode: BgAlignMode.sameClock, fgAnchorMs: 0, bgAnchorMs: 0);
  }
  if (bg >= fg) {
    return (mode: BgAlignMode.sameClock, fgAnchorMs: 0, bgAnchorMs: 0);
  }
  // `pos` may overshoot `fg` transiently; that still means "the video has no
  // time left", so the tail branch owns it (the 副音 parks at its own end and
  // its own exhaustion rules take over).
  if (fg - pos <= bg) {
    return (mode: BgAlignMode.tailAtFg, fgAnchorMs: fg, bgAnchorMs: bg);
  }
  return (mode: BgAlignMode.bgHeadAtFg, fgAnchorMs: pos, bgAnchorMs: 0);
}

/// Maps a session anchor mode back onto its persisted default counterpart.
///
/// LEGACY: the alignment editor no longer offers a persisted default — its
/// 「默认对齐」 tab is read-only (the automatic rule owns the default) — so
/// nothing calls this at runtime. Kept together with the frozen [BgAlignDefault]
/// data and its tests.
///
/// NOTE: this persisted preference does NOT drive the AUTOMATIC anchoring —
/// every fresh anchor is decided by [resolveAutoAlignAnchor].
BgAlignDefault defaultForAlignMode(BgAlignMode m) => switch (m) {
      BgAlignMode.sameClock => BgAlignDefault.sameClock,
      BgAlignMode.bgHeadAtFg => BgAlignDefault.bgHead,
      BgAlignMode.bgPercent => BgAlignDefault.bgPercent,
      // 尾部锚定 is the automatic rule's own answer, not a persisted default.
      BgAlignMode.tailAtFg => BgAlignDefault.sameClock,
    };

/// Decodes a persisted `bg.alignDefault` value, tolerating the LEGACY names
/// (`ask`/`fromHead`/`fromMid`) so an upgraded install keeps its preference.
///
/// Accepts the frozen persisted keys (`fgHead`/`fgPosition`, see
/// [BgAlignDefault.key]), the legacy pre-split names, and — defensively — the
/// current enum names.
///
/// - `ask` (the old "always prompt") → [BgAlignDefault.sameClock] (the new
///   default; the mandatory threshold now owns the prompt);
/// - `fromHead` (bg 00:00 at the fg moment) → [BgAlignDefault.bgHead];
/// - `fromMid` (from the remembered share) → [BgAlignDefault.bgPercent].
BgAlignDefault? bgAlignDefaultFromName(String? name) {
  if (name == null) return null;
  final direct = BgAlignDefault.values.asNameMap()[name];
  if (direct != null) return direct;
  for (final v in BgAlignDefault.values) {
    if (v.key == name) return v;
  }
  switch (name) {
    case 'ask':
      return BgAlignDefault.sameClock;
    case 'fromHead':
      return BgAlignDefault.bgHead;
    case 'fromMid':
      return BgAlignDefault.bgPercent;
  }
  return null;
}

/// Whether the modal alignment prompt must align on close because the 副音
/// file changed behind it (natural completion advanced the queue while the
/// dialog was open).
///
/// The runtime observer skips the new file while the prompt is up
/// (`askingForRun`), so without this the newcomer would play unaligned. A
/// terminal run ([bgExhausted]) or a disabled subsystem never realigns.
bool modalCloseNeedsRealign({
  required String? entryKey,
  required String? exitKey,
  required bool enabled,
  required bool bgExhausted,
}) =>
    enabled &&
    !bgExhausted &&
    entryKey != null &&
    exitKey != null &&
    entryKey != exitKey;

/// Whether the modal alignment prompt may resume 副音 playback on close.
///
/// A run that terminated behind the dialog (`bgExhausted`, e.g. the file
/// completed under `stopRestoreFg`) must never be revived: restoring it would
/// restart a dead run and re-duck the foreground. The foreground side is
/// restored unconditionally by the caller.
///
/// The user gate must still be open: a gate stop pressed while the dialog is up
/// owns the transport, and the modal must not revive 副音 behind it.
bool shouldRestoreBgAfterModal({
  required bool bgWasPlaying,
  required bool bgExhausted,
  bool gateOpen = true,
}) =>
    bgWasPlaying && !bgExhausted && gateOpen;

/// The two bg-only choices offered by the VM tiled manual-switch dialog (no
/// foreground restart: the VM link cannot drive the foreground runtime there).
enum BgAlignChoice {
  /// 副音 00:00 aligned to the video's current position.
  fromHead,

  /// 副音 starts at [percent]% of its duration, aligned to the video.
  percent,
}

/// The 副音 seek target (ms) for a VM tiled manual [choice].
int resolveBgAlignmentChoice({
  required BgAlignChoice choice,
  required int bgDurMs,
  int percent = kDefaultAlignPercent,
}) =>
    choice == BgAlignChoice.percent && bgDurMs > 0
        ? alignPercentTargetMs(bgDurMs, percent)
        : 0;
