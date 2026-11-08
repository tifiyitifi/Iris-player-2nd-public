/// Policy for replaying a multi-window neighbour decision in the RECEIVING
/// window (Shift+PageUp/PageDown).
///
/// WHY a shared, pure predicate: the source window decides the neighbour and
/// ships both the absolute index and that entry's file key, while the receiving
/// window resolves its own (freshly cloned) stream. The two indices can
/// disagree — the source resolves from its CACHED snapshot, the receiver from a
/// NEW one, so a membership or file change in between shifts positions. Feeding
/// the wrong entry here is invisible to the caller except as "the OSD named one
/// file and a different one played", which is exactly the symptom the shipped
/// index was meant to remove. The key turns that into a refused request.
library;

/// Whether the entry the receiving window resolved at the shipped index is the
/// one the source window decided on.
///
/// [expectedKey] is the file key the source shipped. A payload from an older
/// build (or a source without a resolved entry) carries none: trust the index
/// alone, which is all that build ever had.
bool neighborTargetMatches({
  String? expectedKey,
  required String actualKey,
}) {
  if (expectedKey == null || expectedKey.isEmpty) return true;
  return expectedKey == actualKey;
}
