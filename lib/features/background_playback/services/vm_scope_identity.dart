/// Effective 作用范围 identity for a Virtual Merge foreground.
///
/// The 作用范围 observers compare an opaque "media key" against the run's
/// anchor. For a VM session the play queue holds the PHYSICAL block currently
/// on screen, so the natural key changes on every block switch. When the user
/// asked to treat the whole virtual video as one media
/// ([BgVmScopeMode.wholeVirtual]) the VM side publishes a stable identity here
/// instead, and the 副音 feature consumes it without knowing VM exists.
library;

import 'package:iris/features/background_playback/model/enum/bg_vm_scope_mode.dart';

/// Prefix that keeps a virtual-video identity from ever colliding with a real
/// `storageId:path` media key.
const String kVmScopeKeyPrefix = 'vm:';

/// Stable 作用范围 identity of one virtual video ([VirtualMediaItem.scopeKey]).
String vmScopeItemKey(String itemScopeKey) => '$kVmScopeKeyPrefix$itemScopeKey';

/// The identity override to publish, or null when the physical file key must
/// be used.
///
/// - no active VM session → null (ordinary single-file playback);
/// - [BgVmScopeMode.perBlock] → null: each block IS the current media, so the
///   anchor follows the physical file and a block switch is a media switch;
/// - [BgVmScopeMode.wholeVirtual] → the virtual video's identity, so internal
///   block switches no longer look like a media change and 副音 keeps playing
///   until the user leaves for another video.
///
/// [pinnedItemKey] pins the whole treatment to "当时的当前": the virtual item
/// that was current when the tiling run started. A LATER virtual item (a
/// different key) falls back to the physical block identity, so under `smart`
/// only its blocks carrying a saved timeline trigger 副音. Null/empty means
/// "not pinned yet" and publishes the current item (the caller pins it).
String? vmScopeIdentityOverride({
  required bool vmActive,
  required String? vmItemKey,
  required BgVmScopeMode mode,
  String? pinnedItemKey,
}) {
  if (!vmActive) return null;
  final key = vmItemKey;
  if (key == null || key.isEmpty) return null;
  if (mode != BgVmScopeMode.wholeVirtual) return null;
  if (pinnedItemKey != null &&
      pinnedItemKey.isNotEmpty &&
      pinnedItemKey != key) {
    return null;
  }
  return key;
}
