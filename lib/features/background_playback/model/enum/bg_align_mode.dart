/// How the current 副音 file is anchored onto the foreground timeline.
///
/// The anchor is a pair `(fgAnchorMs, bgAnchorMs)`: the foreground position that
/// maps to the 副音 position. All bg positions are derived from the fg progress
/// and this anchor (`bgPos = fgPos - (fgAnchorMs - bgAnchorMs)`), never read
/// from or written to the media-node progress rows.
///
/// All four modes answer ONE question — which 副音 moment maps to the video's
/// current moment — and differ only in WHICH 副音 moment that is:
///
/// - [sameClock]: the 副音 moment EQUAL to the video's (`bgPos = fgPos`), i.e.
///   both share one clock (the default). The video's 00:00 and the 副音's 00:00
///   coincide, so dragging anywhere keeps 副音 under the playhead. A 副音
///   shorter than the video's current position lands at its end.
/// - [bgHeadAtFg]: 副音 00:00 at the video's current moment — 副音 restarts from
///   its head and the two advance in lockstep from here.
/// - [bgPercent]: [alignPercent]% of the 副音 file at the video's current
///   moment — the remaining share is split between "can drag back" and "still
///   plays forward".
/// - [tailAtFg]: the 副音 file's END at the video's END — the 副音 can never run
///   out early, at the cost of skipping its opening. NOT offered as a manual
///   choice: it is the AUTOMATIC rule's answer when the 副音 is shorter than the
///   video and the video's remaining time fits inside it (see
///   `resolveAutoAlignAnchor`). It needs the foreground DURATION, which the other
///   modes do not.
///
/// The anchor moment is always the LIVE foreground position at apply time — no
/// anchor is stored.
///
/// NOTE: the derived offset (`resolveAlignmentOffsetMs`) is FILE-LOCAL (the
/// aligned 副音 FILE's axis). The position mirror works on the queue's VIRTUAL
/// axis and subtracts the file's prefix; see `BackgroundRuntimeScope`.
enum BgAlignMode {
  sameClock,
  bgHeadAtFg,
  bgPercent,
  tailAtFg,
}
