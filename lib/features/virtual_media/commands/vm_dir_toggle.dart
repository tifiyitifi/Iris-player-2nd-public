import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/rule/vm_dir_use.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';

/// Outcome of the "use / not use this video's folder" toggle.
class VmDirToggleResult {
  const VmDirToggleResult({
    required this.usable,
    required this.nowUsing,
    this.rule,
    this.adopted = false,
  });

  /// False when the current file has no folder (e.g. a SAF single document
  /// pick). The caller shows the explanatory copy instead of a dead button.
  final bool usable;

  /// Whether the folder now participates in virtual merging.
  final bool nowUsing;

  final VirtualMediaRule? rule;

  /// True when the file that was ALREADY playing was bound to its merged group
  /// on the spot (no reopen, position preserved). False when it keeps playing
  /// as a single until the next feed (the play queue moved on, the group is
  /// infeasible, or playback is not scenario/tag driven).
  final bool adopted;
}

/// Flips the virtual-merge use state of the current video's DIRECT folder
/// (non-recursive).
///
/// Contract (product):
/// - no covering rule: create one from the default chunk config and enable it
///   ([use] when nothing merges the file, [notUse] when only a recursive rule
///   covers it, so only this folder is carved out);
/// - an existing non-recursive `specifiedDir` rule for this path: toggle ITS
///   polarity and make sure it is enabled (never create a duplicate);
/// - when the folder is switched OFF while its own session is playing, stop
///   merging immediately and let the current physical file continue as a
///   single;
/// - when it is switched ON for the file that is playing, bind that live feed
///   to its merged group without reopening it ("立刻生效，继续当前进度").
Future<VmDirToggleResult> toggleVmDirUseMode({
  required String storageId,
  required String storageName,
  required String name,
  required List<String> path,
  required Iterable<String> storageBasePaths,
  String? uri,
}) async {
  // A SAF single pick stores an EMPTY path; it has no parent directory.
  if (path.isEmpty) {
    return const VmDirToggleResult(usable: false, nowUsing: false);
  }
  final parentRaw =
      path.length <= 1 ? '' : path.sublist(0, path.length - 1).join('/');
  final folderPath = relativeToStoragePath(parentRaw, storageBasePaths);
  final seg = VirtualSegment(
    mediaKey: canonicalMediaKey(storageId, path, uri: uri),
    storageId: storageId,
    path: path,
    name: name,
    parentPath: folderPath,
    uri: uri,
  );

  final rules = await DbModule.virtualMediaRepo.loadRules();
  // Rule identity follows the backing filesystem: a Windows/SMB storage may
  // spell the same folder with different case, which must not mint a duplicate.
  final caseInsensitive = storageBasePaths.any(pathRidesCaseInsensitiveFs);
  final existing =
      vmFindDirRule(rules, folderPath, caseInsensitive: caseInsensitive);
  // "Currently used" means a covering rule WINS as an inclusion. An excluded
  // folder and an uncovered folder both offer "use".
  final desiredUse = vmFileUseState(rules, seg) != VmFileUseState.merged;
  final desiredMode = desiredUse ? VmRuleUseMode.use : VmRuleUseMode.notUse;

  VirtualMediaRule rule;
  if (existing != null) {
    // Reuse THE rule for this path: toggling its polarity cannot create a
    // second enabled rule for the same folder.
    if (existing.useMode != desiredMode) {
      await DbModule.virtualMediaRepo.setRuleUseMode(existing.id, desiredMode);
    }
    if (!existing.enabled) {
      await DbModule.virtualMediaRepo.setRuleEnabled(existing.id, true);
    }
    rule = (await DbModule.virtualMediaRepo.ruleById(existing.id)) ??
        existing.copyWith(useMode: desiredMode, enabled: true);
  } else {
    final folderName =
        folderPath.isEmpty ? storageName : folderPath.split('/').last;
    final base =
        storageName.trim().isEmpty ? folderName : '$storageName - $folderName';
    final created = vmMakeDirRule(
      id: 'vm_${DateTime.now().microsecondsSinceEpoch}',
      name: vmUniqueDirRuleName(base, rules),
      folderPath: folderPath,
      use: desiredUse,
    );
    await DbModule.virtualMediaRepo.saveRule(created);
    rule = created;
  }

  // A notification failure must never roll back the saved rule.
  try {
    await VirtualMediaService.instance.notifyRulesChanged();
  } catch (_) {}

  // Apply the change to the feed that is ALREADY playing. Order matters: the
  // provider resolves its merge groups through version/revision-keyed caches,
  // so the notification above must have invalidated them first.
  var adopted = false;
  if (desiredUse) {
    // "Use" must take effect on the current video, not on the next one: bind
    // the live feed to its merged group WITHOUT reopening it (progress and
    // audio continue; only the VM timeline attaches).
    try {
      adopted = await PlaybackProviderRegistry.adoptCurrentFeedAsVirtual(
        expectedMediaKey: seg.mediaKey,
      );
    } catch (_) {
      adopted = false;
    }
  } else {
    await _fallbackToSingleAfterRuleChange();
  }
  return VmDirToggleResult(
    usable: true,
    nowUsing: desiredUse,
    rule: rule,
    adopted: adopted,
  );
}

/// Stops the live merge when the change made the segment the session is
/// actually playing un-mergeable.
///
/// Deliberately keyed on the LIVE segment and the FRESH rules, not on the
/// toggled rule's id: a folder can be carved out of a session that belongs to a
/// DIFFERENT rule (a recursive rule above it), and that session must stop too.
///
/// `deactivateForNavigation` clears the session state/timers but leaves the
/// play queue and autoplay alone, so the already-open physical file keeps
/// playing — exactly "fall back to single-file playback" without a black
/// flash. The scenario re-resolve publishes the un-merged list.
Future<void> _fallbackToSingleAfterRuleChange() async {
  try {
    final ctrl = VirtualMediaController.instance;
    final live = ctrl.currentSegmentOrNull;
    if (live == null) return;
    final rules = await DbModule.virtualMediaRepo.loadRules();
    if (vmFileUseState(rules, live) != VmFileUseState.merged) {
      // The polarity flip already dropped this rule's anchors in the same
      // transaction; a teardown flush would write them straight back.
      await ctrl.deactivateForNavigation(flushAnchor: false);
    }
  } catch (_) {
    // No live session (or controller unavailable): nothing to fall back from.
  }
}
