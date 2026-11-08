import 'package:iris/features/fake_cut/store/use_fake_cut_store.dart';

/// Whether 简播 (a fake cut) makes 副音 unavailable for the foreground media.
///
/// The two features coexist by EXCLUSION, not by a global switch:
///  * a file playing a cut owns a virtual timeline that has no meaning on the
///    副音 side, so 副音 suspends itself for that file only
///    (see `BackgroundPlaybackStore.suspendForFakeCut`);
///  * every other media keeps using 副音 exactly as before — including under
///    the 「全部」scope, where the run simply pauses while the cut is on screen
///    and resumes when the foreground moves on.
///
/// The identity used here is the SAME canonical key the 副音 作用范围 uses
/// (`currentScopeKey()`), so the gate, the scope observer and the activation
/// guards can never disagree about which media is meant.
///
/// [playingKey] is `FakeCutStoreState.playingKey`: the file whose OPEN actually
/// adopted a cut. Deliberately NOT `activePaths` — that map only says a plan is
/// REMEMBERED for a file, and the EDL can fail to be prepared (unwritable temp
/// dir, vanished source) or lose the open to another backend / a Virtual-Media
/// session. Suspending 副音 on the plan alone left it silent under an untouched
/// source. Passed in rather than read here so the pure 副音 decision layer stays
/// pure; call sites that live in widgets select the field to subscribe, and the
/// non-widget guards use [fakeCutBlocksBackgroundNow].
bool fakeCutBlocksBackground(
  String? fgKey,
  String? playingKey,
) {
  if (fgKey == null || fgKey.isEmpty) return false;
  return fgKey == playingKey;
}

/// [fakeCutBlocksBackground] against the live store (for non-widget guards such
/// as the menu/action entry points, which have no subscription of their own).
bool fakeCutBlocksBackgroundNow(String? fgKey) =>
    fakeCutBlocksBackground(fgKey, useFakeCutStore().state.playingKey);
