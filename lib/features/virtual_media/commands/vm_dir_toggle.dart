import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:iris/features/scenario_playback/playback/playback_provider_registry.dart';
import 'package:iris/features/virtual_media/commands/vm_master_actions.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/rule/vm_dir_use.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/utils/path_conv.dart';

/// Test seam: makes the folder-rule write throw AFTER the disable batch has
/// succeeded, so a test can prove the rollback covers the whole action and not
/// just the batch. Mirrors `VmPrefs.debugFailMasterWrite`.
@visibleForTesting
bool debugFailFolderRuleWrite = false;

/// How to resolve the global master switch when a folder action needs it ON.
///
/// A paused switch is a deliberate global stop (GATE-3), so the folder action
/// must never flip it on its own: the caller asks, then passes the answer back.
enum VmMasterOffChoice {
  /// Resume merging for THIS folder only: disable every other enabled rule
  /// first, then turn the switch on. The user asked for one folder, not for
  /// the whole feature to come back.
  keepOnlyCurrent,

  /// Turn the switch on and let every other enabled rule resume as it is.
  enableAll,
}

/// Outcome of the "use / not use this video's folder" toggle.
class VmDirToggleResult {
  const VmDirToggleResult({
    required this.usable,
    required this.nowUsing,
    this.rule,
    this.adopted = false,
    this.needsMasterChoice = false,
    this.otherEnabledCount = 0,
    this.disabledOtherRules = 0,
    this.masterPaused = false,
    this.failed = false,
    this.masterSaveFailed = false,
    this.notified = false,
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

  /// True when the request needs the global master switch ON and the caller has
  /// not answered yet. NOTHING was written: the caller must ask the user, then
  /// call again with [masterOffChoice]. A cancelled prompt therefore leaves the
  /// rule set exactly as it was.
  final bool needsMasterChoice;

  /// Enabled rules other than the acted-on folder's own rule. Drives the
  /// "N other rules would resume too" copy of the prompt.
  final int otherEnabledCount;

  /// Rules this call disabled for [VmMasterOffChoice.keepOnlyCurrent].
  final int disabledOtherRules;

  /// True when the rule was saved but merging stays paused (the action was
  /// "not use" while the master switch is off). The exclusion applies once the
  /// switch comes back on; the switch itself was not touched.
  final bool masterPaused;

  /// True when the action could not be applied at all and nothing changed:
  /// a "keep only this folder" disable failed and the rules already turned off
  /// were restored. The caller must explain instead of reporting success.
  final bool failed;

  /// True when the folder rule WAS saved but the master switch could not be
  /// turned on (its preference write failed). Merging stays paused; the caller
  /// must say so rather than claiming the folder resumed.
  final bool masterSaveFailed;

  /// True when this call already refreshed the open surfaces
  /// ([VirtualMediaService.notifyRulesChanged]). The manager uses it to avoid
  /// running the same fan-out a second time right after the command.
  final bool notified;
}

/// Disables every enabled rule except [ownRuleId] for "keep only this folder".
///
/// All-or-nothing: if a disable fails, the rules this call already turned off
/// are restored and null is returned. A partial disable is neither the old
/// state nor the chosen one, so the caller reports a failure instead.
///
/// Returns the rules it disabled, so the caller can restore them if a LATER
/// step of the same action (the folder-rule write) fails — "failed writes
/// change nothing" covers the whole folder action, not just this batch.
///
/// [setEnabled] is injected so the rollback is unit-testable without a failing
/// database.
Future<List<VirtualMediaRule>?> disableOtherRulesForKeepOnly({
  required List<VirtualMediaRule> rules,
  required String? ownRuleId,
  required Future<void> Function(String ruleId, bool enabled) setEnabled,
}) async {
  final targets = <VirtualMediaRule>[
    for (final r in rules)
      if (r.enabled && (ownRuleId == null || r.id != ownRuleId)) r,
  ];
  final disabled = <VirtualMediaRule>[];
  try {
    for (final r in targets) {
      await setEnabled(r.id, false);
      disabled.add(r);
    }
    return disabled;
  } catch (_) {
    for (final r in disabled) {
      try {
        await setEnabled(r.id, true);
      } catch (_) {
        // Best-effort restore: the caller still reports the failure.
      }
    }
    return null;
  }
}

/// Restores what a failed folder-rule write may have changed.
///
/// The disable batch already succeeded, so its rules are re-enabled. When an
/// existing rule was being edited, a partial write (polarity flipped, enable
/// not) is put back to its stored values. Best-effort: the caller still reports
/// the failure, and a restore that itself fails does not throw past it.
Future<void> _rollbackFolderWrite({
  required List<VirtualMediaRule> disabledOtherRules,
  required VirtualMediaRule? existing,
  /// A rule this call CREATED (only when [existing] was null). It is removed, so
  /// a failed action leaves no folder rule behind.
  VirtualMediaRule? created,
}) async {
  for (final r in disabledOtherRules) {
    try {
      await DbModule.virtualMediaRepo.setRuleEnabled(r.id, true);
    } catch (_) {
      // Best-effort restore.
    }
  }
  if (created != null) {
    try {
      await DbModule.virtualMediaRepo.deleteRule(created.id);
    } catch (_) {
      // Best-effort restore.
    }
    return;
  }
  if (existing == null) return;
  try {
    await DbModule.virtualMediaRepo.setRuleUseMode(existing.id, existing.useMode);
  } catch (_) {
    // Best-effort restore.
  }
  try {
    await DbModule.virtualMediaRepo.setRuleEnabled(existing.id, existing.enabled);
  } catch (_) {
    // Best-effort restore.
  }
}

/// Enabled rules other than [ownRuleId] — the ones a global resume would wake
/// up alongside the folder being acted on.
int _otherEnabledCount(List<VirtualMediaRule> rules, String? ownRuleId) {
  var count = 0;
  for (final rule in rules) {
    if (!rule.enabled) continue;
    if (ownRuleId != null && rule.id == ownRuleId) continue;
    count++;
  }
  return count;
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
///
/// Master switch: a `use` action can only mean something while the global
/// switch is ON. When it is OFF the call returns [VmDirToggleResult
/// .needsMasterChoice] WITHOUT writing anything; the caller asks the user and
/// repeats the call with [masterOffChoice]. "Keep only this folder" disables
/// the other enabled rules before the switch returns, so a paused feature is
/// never resumed wholesale behind the user's back.
Future<VmDirToggleResult> toggleVmDirUseMode({
  required String storageId,
  required String storageName,
  required String name,
  required List<String> path,
  required Iterable<String> storageBasePaths,
  String? uri,
  VmMasterOffChoice? masterOffChoice,
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

  // The master switch is the power source for every rule: while it is off a
  // freshly written `use` rule would resolve to nothing, which is exactly the
  // "clicked, nothing happened" report. Ask instead of writing a rule that
  // cannot apply, and write nothing until the user picks a way forward.
  final masterOn = await VmPrefs.masterEnabled();
  if (desiredUse && !masterOn && masterOffChoice == null) {
    return VmDirToggleResult(
      usable: true,
      nowUsing: false,
      needsMasterChoice: true,
      otherEnabledCount: _otherEnabledCount(rules, existing?.id),
    );
  }

  // "Keep only this folder": pause the other rules BEFORE the switch returns,
  // so resuming never flashes unrelated folders into merged rows. The folder's
  // own rule is left to the toggle below; every other enabled rule is closed
  // and can be reopened from the manager. All-or-nothing: a failed disable OR
  // a failed folder-rule write restores what this call already changed instead
  // of leaving a half state.
  List<VirtualMediaRule> disabledOtherRules = const <VirtualMediaRule>[];
  if (desiredUse &&
      !masterOn &&
      masterOffChoice == VmMasterOffChoice.keepOnlyCurrent) {
    final disabled = await disableOtherRulesForKeepOnly(
      rules: rules,
      ownRuleId: existing?.id,
      setEnabled: (id, enabled) =>
          DbModule.virtualMediaRepo.setRuleEnabled(id, enabled),
    );
    if (disabled == null) {
      return VmDirToggleResult(
        usable: true,
        nowUsing: false,
        failed: true,
        otherEnabledCount: _otherEnabledCount(rules, existing?.id),
      );
    }
    disabledOtherRules = disabled;
  }

  VirtualMediaRule rule;
  try {
    if (debugFailFolderRuleWrite) {
      throw StateError('debug: folder rule write failed');
    }
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
  } catch (_) {
    // The disable batch already landed; put it (and any partial edit of the
    // folder's own rule) back so the action truly changed nothing.
    await _rollbackFolderWrite(
      disabledOtherRules: disabledOtherRules,
      existing: existing,
    );
    return VmDirToggleResult(
      usable: true,
      nowUsing: false,
      failed: true,
      otherEnabledCount: _otherEnabledCount(rules, existing?.id),
    );
  }

  // A notification failure must never roll back the saved rule. `notified`
  // tells the caller whether the open surfaces were already refreshed, so the
  // manager does not run the same fan-out a second time.
  final turnedOn = desiredUse && !masterOn;
  var notified = false;
  var masterSaveFailed = false;
  try {
    if (turnedOn) {
      // One choke point: this drops the rule cache, re-resolves an active tag
      // view and emits BOTH revision signals (the same fan-out a plain
      // notifyRulesChanged does), so the resumed switch is visible everywhere.
      final applied = await setVmMasterEnabled(enabled: true);
      notified = applied;
      masterSaveFailed = !applied;
    } else {
      await VirtualMediaService.instance.notifyRulesChanged();
      notified = true;
    }
  } catch (_) {
    masterSaveFailed = turnedOn;
  }

  // The rule is saved but the global switch refused the write: merging stays
  // paused, so skip adoption and let the caller explain the partial outcome.
  if (masterSaveFailed) {
    // "Keep only this folder" closed the other rules BEFORE the switch write.
    // If that write failed, undo the whole choice: otherwise the user keeps a
    // half-applied state (their other folders closed, nothing resumed). The
    // folder rule this call created is removed; an edited one is restored.
    if (masterOffChoice == VmMasterOffChoice.keepOnlyCurrent &&
        disabledOtherRules.isNotEmpty) {
      await _rollbackFolderWrite(
        disabledOtherRules: disabledOtherRules,
        existing: existing,
        created: existing == null ? rule : null,
      );
      return VmDirToggleResult(
        usable: true,
        nowUsing: false,
        rule: existing,
        masterSaveFailed: true,
        notified: notified,
      );
    }
    return VmDirToggleResult(
      usable: true,
      nowUsing: false,
      rule: rule,
      disabledOtherRules: disabledOtherRules.length,
      masterSaveFailed: true,
      notified: notified,
    );
  }

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
    disabledOtherRules: disabledOtherRules.length,
    // "Not use" is a valid edit while paused: it is saved and applies when
    // merging resumes. Report it so the UI can say so instead of staying mute.
    masterPaused: !desiredUse && !masterOn,
    notified: notified,
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
