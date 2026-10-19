import 'dart:math';

import 'package:iris/features/background_playback/model/background_playback_state.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/scenario_playback/model/domain/effective_playback_item.dart';
import 'package:iris/features/scenario_playback/store/use_playback_scenario_store.dart';
import 'package:iris/features/tag_play/model/enum/tag_system_kind.dart';
import 'package:iris/features/tag_play/resolver/tag_view_resolver.dart';
import 'package:iris/models/db/db_module.dart';

/// The reserved 「副音备选」tag id, or null when it does not exist yet.
Future<int?> reservedBackgroundTagId() async {
  try {
    final tags = await DbModule.tagPlayRepo.tags();
    for (final t in tags) {
      if (t.systemKind == TagSystemKind.backgroundVoiceCandidate) return t.id;
    }
  } catch (_) {
    // No tag DB (store-free test): 副音 has no candidates.
  }
  return null;
}

/// A deterministic Fisher–Yates permutation of [input] under [seed].
///
/// Deterministic (not `Random()`): every resolve — the queue window, a slide
/// (`windowAt`), the 副音 browser — must agree on the order for the SAME pool
/// and seed, or a step would index a different list than the one that was
/// displayed. Pure so the ordering contract is unit-testable.
List<T> shuffleBySeed<T>(List<T> input, int seed) {
  final out = List<T>.of(input);
  if (out.length < 2 || seed == 0) return out;
  final rnd = Random(seed);
  for (var i = out.length - 1; i > 0; i--) {
    final j = rnd.nextInt(i + 1);
    final tmp = out[i];
    out[i] = out[j];
    out[j] = tmp;
  }
  return out;
}

/// The 副音 candidate stream: the reserved tag's active membership, ordered by
/// that tag's OWN view state — the SAME tag view the foreground tag play uses.
///
/// Empty when the reserved tag does not exist yet (nothing tagged for 副音).
/// VM merge is skipped (`withVmOverlay: false`): the 副音 list must stay real
/// single files, so the RAW pre-overlay stream is the candidate list.
///
/// 副音's own shuffle ([BackgroundPlaybackState.shuffleSeed]) is applied HERE
/// rather than written into the shared tag view: toggling shuffle in 副音 must
/// not reorder the foreground browser of the same tag.
Future<List<EffectivePlaybackItem>> resolveBackgroundCandidates({
  required String scenarioId,
}) async {
  final tagId = await reservedBackgroundTagId();
  if (tagId == null) return const [];
  final resolver = TagViewResolver(
    source: ResolverEffectiveItemsSource(usePlaybackScenarioStore().resolver),
    repo: DbModule.tagPlayRepo,
  );
  final snap = await resolver.resolve(
    tagId: tagId,
    scenarioId: scenarioId,
    ignoreScenario: true,
    withVmOverlay: false,
  );
  final bg = () {
    try {
      return useBackgroundPlaybackStore().state;
    } catch (_) {
      // Store-free test / very early boot: resolve unshuffled rather than fail.
      return const BackgroundPlaybackState();
    }
  }();
  final seed = bg.shuffle ? bg.shuffleSeed : 0;
  if (seed == 0) return snap.vmStream;
  return shuffleBySeed(snap.vmStream, seed);
}
