import 'package:flutter/material.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/media_library/model/enum/media_node.dart'
    show MediaSortField;
import 'package:iris/features/media_library/model/media_lib/media_node.dart';
import 'package:iris/features/virtual_media/model/domain/vm_item.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/resolver/vm_resolver.dart';
import 'package:iris/features/virtual_media/rule/vm_naming.dart';
import 'package:iris/features/virtual_media/service/vm_overlay_service.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/view/vm_rule_editor_v2.dart';
import 'package:iris/features/virtual_media/view/vm_sheet.dart';
import 'package:iris/features/virtual_media/vm_gate.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/warning_dialogs.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/widgets/dialogs/show_confirm_suppressible_dialog.dart';

/// Entry command for the Virtual Media sheet (tag_play pattern: one function,
/// two doors — player more-menu now, gestures later).
///
/// Gated: when the metadata-driven stack is off the feature does not exist;
/// the command explains instead of opening anything.
Future<void> openVirtualMediaSheet(BuildContext context) async {
  // Gate first: when the metadata-driven stack is off the feature does not
  // exist — explain instead of opening anything. The legacy seal below stays
  // a silent no-op.
  if (!VirtualMediaGate.enabled) {
    await showDialog<void>(
      context: context,
      builder: (dialogCtx) {
        final t = getLocalizations(dialogCtx);
        return AlertDialog(
          title: Text(t.vm_unavailable_title),
          content: Text(t.vm_unavailable_body),
        );
      },
    );
    return;
  }
  // Sealed legacy entry: the More-menu sheet (session card + rule tiles)
  // must never open nor run its preview resolve / duration scan. Rule CRUD
  // lives in meta-settings (showVirtualMediaManager). Silent no-op keeps
  // playback unaware single-video.
  if (!VirtualMediaGate.legacySheetEnabled) return;
  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (_) => const VirtualMediaSheet(),
  );
}

/// Opens the rule editor (creating a new rule when [initial] is null).
///
/// Adaptive shell, same form: phones get a fixed bottom sheet with a drag
/// handle (keyboard-friendly M3 compact pattern), wide screens keep the
/// centered dialog. See [kVmEditorSheetBreakpoint].
///
/// V2 editor (vm_rule_editor_v2.dart): the V1 file stays untouched as a
/// fallback reference; V2 caches the form so keyboard frames never rebuild
/// fields (fixes tall-IME stalls, e.g. Baidu input).
/// Defaults for a brand-new rule: auto `rule+N` name per the configured
/// strategy plus a creation stamp (local, ms-precise) as description.
/// Editing an existing rule never calls this — originals are preserved.
Future<({String name, String description})> newVmRuleDefaults() async {
  final results = await Future.wait([
    DbModule.virtualMediaRepo.loadRules(),
    VmPrefs.namingSnapshot(),
  ]);
  final rules = results[0] as List<VirtualMediaRule>;
  final naming = results[1] as ({
    VmNamingStrategy strategy,
    String prefix,
    String numberFormat,
    int counter,
  });
  final name = nextVmRuleName(
    existing: [for (final r in rules) r.name],
    prefix: naming.prefix,
    numberFormat: naming.numberFormat,
    strategy: naming.strategy,
    counterHint: naming.counter,
  );
  return (name: name, description: formatVmTimestamp(DateTime.now()));
}

/// Thrown when [duplicateVmRule] cannot mint a unique name after retries.
/// Carries no user-visible text: callers render `vm_sheet_copy_failed*` ARB.
class VmNameExhaustedException implements Exception {
  final int attempts;
  const VmNameExhaustedException(this.attempts);

  @override
  String toString() => 'VmNameExhaustedException(attempts: $attempts)';
}

/// Direct-fallback copy: duplicates every field of [src] under a fresh id,
/// auto name and creation-stamp description. The copy starts DISABLED
/// (`enabled: false`, `pinned` inherited) so it never double-merges before
/// the user edits it. Throws on DB failure — callers surface a Dialog.
Future<VirtualMediaRule> duplicateVmRule(VirtualMediaRule src) async {
  final naming = await VmPrefs.namingSnapshot();
  // Snapshot once; re-read only on a name collision so concurrent creators
  // can't steal our name.
  var rules = await DbModule.virtualMediaRepo.loadRules();
  for (var attempt = 0; attempt < 5; attempt++) {
    final names = [for (final r in rules) r.name];
    final ids = {for (final r in rules) r.id};
    var name = nextVmRuleName(
      existing: names,
      prefix: naming.prefix,
      numberFormat: naming.numberFormat,
      strategy: naming.strategy,
      counterHint: naming.counter + attempt,
    );
    if (names.contains(name)) {
      await VmPrefs.bumpNameCounter(naming.counter + attempt + 1);
      rules = await DbModule.virtualMediaRepo.loadRules();
      continue;
    }
    var id = 'vm_${DateTime.now().microsecondsSinceEpoch}';
    if (ids.contains(id)) {
      id = '${id}_$attempt';
    }
    final copy = src.copyWith(
      id: id,
      name: name,
      description: formatVmTimestamp(DateTime.now()),
      enabled: false,
      pinned: src.pinned,
    );
    await DbModule.virtualMediaRepo.saveRule(copy);
    final suffix = parseVmSuffix(name, naming.prefix);
    if (suffix > 0) await VmPrefs.bumpNameCounter(suffix);
    return copy;
  }
  throw const VmNameExhaustedException(5);
}

Future<bool?> openVmRuleEditor(BuildContext context,
    {VirtualMediaRule? initial,
    bool showConceptGuide = true,
    String? defaultName,
    VmMatchMode? defaultMatchMode,
    List<String>? defaultPaths}) async {
  // First-use explainer for a brand-new rule only — editing an existing rule
  // does not repeat it. Suppressible with the box ticked by default.
  if (initial == null && showConceptGuide) {
    final t = getLocalizations(context);
    await showInfoSuppressibleDialog(
      context,
      warningId: kWarningVmMergeConcept,
      title: t.dlg_warn_vm_concept_title,
      message: t.dlg_vm_concept_body,
      defaultDontAsk: true,
    );
    if (!context.mounted) return null;
  }
  // Prefill new-rule drafts only; edits keep their stored values verbatim.
  // An explicit [defaultName] (folder quick-add) bypasses the naming strategy.
  String? pfName;
  String? pfDescription;
  if (initial == null) {
    if (defaultName != null) {
      pfName = defaultName;
      pfDescription = formatVmTimestamp(DateTime.now());
    } else {
      try {
        final d = await newVmRuleDefaults();
        pfName = d.name;
        pfDescription = d.description;
      } catch (_) {}
    }
  }
  if (!context.mounted) return null;
  final narrow =
      MediaQuery.sizeOf(context).width < kVmEditorSheetBreakpoint;
  final bool? saved = narrow
      ? await showModalBottomSheet<bool>(
          context: context,
          isScrollControlled: true,
          useSafeArea: true,
          enableDrag: true,
          showDragHandle: true,
          shape: const RoundedRectangleBorder(
            borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
          ),
          builder: (_) => VmRuleEditorV2Sheet(
              initial: initial,
              defaultName: pfName,
              defaultDescription: pfDescription,
              defaultMatchMode: defaultMatchMode,
              defaultPaths: defaultPaths),
        )
      : await showDialog<bool>(
          context: context,
          builder: (_) => VmRuleEditorV2Dialog(
              initial: initial,
              defaultName: pfName,
              defaultDescription: pfDescription,
              defaultMatchMode: defaultMatchMode,
              defaultPaths: defaultPaths),
        );
  if (saved == true) {
    // Editor saves hit the repo directly; propagate the merge-layer change
    // to the scenario lists here (single choke point for editor saves).
    await VirtualMediaService.instance.notifyRulesChanged();
  }
  return saved;
}

/// Default values for a folder-scoped NEW virtual-merge rule (the media-browser
/// trailing quick-add). Pure so it can be unit-tested.
({String name, VmMatchMode matchMode, List<String> paths}) folderVmRuleDefaults({
  required String storageName,
  required String folderName,
  required String folderPath,
}) {
  final trimmed = folderName.trim();
  return (
    name: trimmed.isEmpty ? storageName : '$storageName - $trimmed',
    matchMode: VmMatchMode.specifiedDirRecursive,
    paths: <String>[folderPath],
  );
}

/// Quick-add entry for the media browsers: opens the virtual-merge editor
/// prefilled to merge [folderPath] (storage-relative, `''` = storage root)
/// recursively. Returns true when a rule was saved.
Future<bool?> openVmRuleEditorForFolder(
  BuildContext context, {
  required String storageName,
  required String folderName,
  required String folderPath,
  bool showConceptGuide = true,
}) {
  final defaults = folderVmRuleDefaults(
    storageName: storageName,
    folderName: folderName,
    folderPath: folderPath,
  );
  return openVmRuleEditor(
    context,
    showConceptGuide: showConceptGuide,
    defaultName: defaults.name,
    defaultMatchMode: defaults.matchMode,
    defaultPaths: defaults.paths,
  );
}

class ResolvedRules {
  final List<VirtualMediaRule> rules;
  final Map<String, List<VirtualMediaItem>> byRuleId;

  /// Size of the library snapshot the rules were resolved against. Shown in
  /// the management UI so "0 匹配" is immediately attributable: library==0
  /// means nothing scanned; library>0 with 0 matches means a rule/path
  /// mismatch.
  final int libraryCount;

  ResolvedRules(this.rules, this.byRuleId, {this.libraryCount = 0});

  Iterable<MapEntry<VirtualMediaRule, List<VirtualMediaItem>>> get entries =>
      rules.map((r) => MapEntry(r, byRuleId[r.id] ?? const []));
}

/// Human-readable summary of WHAT a rule matches (stored paths / activated
/// pattern entries) — surfaced in previews so a stored-but-wrong path is
/// visible without opening the editor.
String vmMatchSummary(VirtualMediaRule rule, AppLocalizations t) {
  final mode = switch (rule.matchMode) {
    VmMatchMode.specifiedDir => t.vm_editor_match_specified,
    VmMatchMode.specifiedDirRecursive =>
      t.vm_editor_match_specified_recursive,
    VmMatchMode.patternDir => t.vm_editor_match_pattern,
    VmMatchMode.patternDirRecursive => t.vm_editor_match_pattern_recursive,
  };
  final parts = <String>[];
  if (rule.matchMode == VmMatchMode.specifiedDir ||
      rule.matchMode == VmMatchMode.specifiedDirRecursive) {
    parts.addAll([
      for (final p in rule.paths) p.isEmpty ? t.vm_editor_library_root : p,
    ]);
  } else {
    parts.addAll([
      for (final p in rule.patterns)
        if (p.activated && p.text.trim().isNotEmpty)
          '${switch (p.kind) { VmPatternKind.prefix => t.vm_sheet_kind_prefix, VmPatternKind.suffix => t.vm_sheet_kind_suffix, VmPatternKind.contains => t.vm_sheet_kind_contains, VmPatternKind.regex => t.vm_sheet_kind_regex }}:${p.text.trim()}',
    ]);
  }
  if (parts.isEmpty) return '$mode · ${t.vm_sheet_no_conditions}';
  return '$mode · ${parts.join(', ')}';
}

/// PREVIEW-ONLY library snapshot for the rules management UI: a paged drift
/// read over the WHOLE `media_nodes` table (storage-agnostic). The playback
/// pipeline never uses this — VM groups in playback derive from each
/// scenario's own effective stream (vm_stream_merge.dart).
Future<List<VirtualSegment>> loadPreviewLibrarySegments() async {
  final out = <VirtualSegment>[];
  var page = 1;
  while (true) {
    final result = await DbModule.mediaNodeRepo.getAllMedia(
      page: page,
      pageSize: 1000,
      mediaType: MediaType.video,
      sortField: MediaSortField.name,
      sortDirection: SortDirection.asc,
    );
    for (final node in result.items) {
      final f = node.maybeMap(file: (f) => f, orElse: () => null);
      if (f == null) continue;
      out.add(VirtualSegment(
        mediaKey: canonicalKey(f.storageId, f.path.join('/')),
        storageId: f.storageId,
        path: f.path,
        name: f.name,
        parentPath: canonicalPath(f.parentPath ?? ''),
        uri: f.uri,
        durationMs: f.durationMs,
        width: f.width,
        height: f.height,
      ));
    }
    if (result.items.length < 1000 || page >= 50) break;
    page++;
  }
  return out;
}

/// Loads enabled rules and resolves each against a fresh library snapshot
/// (sheet-local PREVIEW; the playback merge layer derives per scenario —
/// see vm_stream_merge.dart).
Future<ResolvedRules> resolveEnabledRules() async {
  final all = await DbModule.virtualMediaRepo.loadRules();
  final lib = await loadPreviewLibrarySegments();
  final map = <String, List<VirtualMediaItem>>{};
  for (final r in all.where((r) => r.enabled)) {
    // The preview reads the WHOLE library, but the boundary freeze is seeded
    // from one scenario's stream — applying it here would drop members outside
    // that scenario, so the preview always re-derives.
    map[r.id] = resolveVirtualMedia(rules: [r], library: lib, applyPin: false);
  }
  return ResolvedRules(all, map, libraryCount: lib.length);
}
