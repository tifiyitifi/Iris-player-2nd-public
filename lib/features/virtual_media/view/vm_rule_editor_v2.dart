import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/virtual_media/model/domain/vm_rule.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';
import 'package:iris/features/virtual_media/rule/vm_title_composer.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/features/virtual_media/view/vm_info_banner.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/db/db_module.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/logger.dart';
import 'package:iris/utils/path_conv.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/adaptive/keyboard_inset_padder.dart';
import 'package:saf_util/saf_util.dart';

final _log = AreaKeyLog(LogKeys.legacyDb);

/// Width below which the editor opens as a bottom sheet instead of a centered
/// dialog (M3 compact breakpoint). Consumed by the editor command's shell
/// choice; lives here now that the V1 editor is gone.
const double kVmEditorSheetBreakpoint = 600.0;

/// V2 rule editor: same fields and save semantics as the V1 editor, but the
/// widget structure follows the industry keyboard pattern (iOS
/// keyboardLayoutGuide / Android adjustResize equivalent): the heavy form
/// subtree is built EXACTLY ONCE and cached in shell state, while keyboard
/// height is consumed by ONE AnimatedPadding in the shell. Keyboard frames
/// therefore only move pixels — they never rebuild a single field.
///
/// Why V1 stalled tall third-party keyboards (e.g. Baidu IME): every widget
/// that reads `MediaQuery.viewInsetsOf` rebuilds on each keyboard frame,
/// and a parent rebuild re-runs every child build below it. V1 read
/// viewInsets inside the form (maxHeight, footer padding) and inside a
/// DraggableScrollableSheet that re-resolved its extent per frame — the
/// whole form (dozens of fields, 7 dropdowns, title preview) rebuilt on
/// every frame, each frame slower than the last ("一级级往上").
///
/// V2 rules (enforced by `test/vm_rule_editor_v2_layout_test.dart`):
/// - Only the shell reads viewInsets/size. The cached form never touches
///   MediaQuery — width branching uses LayoutBuilder constraints.
/// - The form instance is created once in shell `initState` and reused;
///   shell rebuilds must not re-run `VmRuleEditorFormV2.build`.

/// Centered-dialog shell for wide screens (desktop / tablet landscape).
class VmRuleEditorV2Dialog extends StatefulWidget {
  const VmRuleEditorV2Dialog(
      {super.key,
      this.initial,
      this.defaultName,
      this.defaultDescription,
      this.defaultMatchMode,
      this.defaultPaths});

  final VirtualMediaRule? initial;

  /// Prefill for NEW drafts only (null when editing); see [VmRuleEditorFormV2].
  final String? defaultName;
  final String? defaultDescription;
  final VmMatchMode? defaultMatchMode;
  final List<String>? defaultPaths;

  @override
  State<VmRuleEditorV2Dialog> createState() => _VmV2DialogState();
}

class _VmV2DialogState extends State<VmRuleEditorV2Dialog> {
  late final Widget _form = VmRuleEditorFormV2(
      initial: widget.initial,
      defaultName: widget.defaultName,
      defaultDescription: widget.defaultDescription,
      defaultMatchMode: widget.defaultMatchMode,
      defaultPaths: widget.defaultPaths);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final narrow = size.width < 600;
    return Dialog(
      insetPadding: narrow
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 12)
          : const EdgeInsets.symmetric(horizontal: 16, vertical: 24),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: size.height * 0.92,
        ),
        child: KeyboardInsetPadder(child: _form),
      ),
    );
  }
}

/// Bottom-sheet shell for phones: fixed-height sheet, keyboard avoidance is
/// the single [KeyboardInsetPadder] — no DraggableScrollableSheet (it
/// re-resolves extent + rebuilds content on every keyboard frame).
class VmRuleEditorV2Sheet extends StatefulWidget {
  const VmRuleEditorV2Sheet(
      {super.key,
      this.initial,
      this.defaultName,
      this.defaultDescription,
      this.defaultMatchMode,
      this.defaultPaths});

  final VirtualMediaRule? initial;

  /// Prefill for NEW drafts only (null when editing); see [VmRuleEditorFormV2].
  final String? defaultName;
  final String? defaultDescription;
  final VmMatchMode? defaultMatchMode;
  final List<String>? defaultPaths;

  @override
  State<VmRuleEditorV2Sheet> createState() => _VmV2SheetState();
}

class _VmV2SheetState extends State<VmRuleEditorV2Sheet> {
  late final Widget _form = VmRuleEditorFormV2(
      initial: widget.initial,
      defaultName: widget.defaultName,
      defaultDescription: widget.defaultDescription,
      defaultMatchMode: widget.defaultMatchMode,
      defaultPaths: widget.defaultPaths,
      fillViewport: true);

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return KeyboardInsetPadder(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * 0.92),
        child: _form,
      ),
    );
  }
}

/// Shared editor form (state + sticky header / scrollable fields / sticky
/// footer). Built once per shell — see the file doc comment. Reads NO
/// MediaQuery: width branching via LayoutBuilder, theme via Theme (stable
/// across keyboard frames).
class VmRuleEditorFormV2 extends HookWidget {
  const VmRuleEditorFormV2({
    super.key,
    this.initial,
    this.defaultName,
    this.defaultDescription,
    this.defaultMatchMode,
    this.defaultPaths,
    this.fillViewport = false,
  });

  final VirtualMediaRule? initial;

  /// Prefill text for the name/description fields when creating a new rule
  /// (`initial == null`). Ignored when editing — stored values stay verbatim.
  final String? defaultName;
  final String? defaultDescription;

  /// Prefill for the match mode / specified paths when creating a new rule
  /// (`initial == null`). Ignored when editing.
  final VmMatchMode? defaultMatchMode;
  final List<String>? defaultPaths;

  /// True inside the bottom-sheet shell (fill the sheet); false inside the
  /// dialog shell (shrink to content).
  final bool fillViewport;

  /// Test seam: counts form rebuilds to prove keyboard frames don't re-run
  /// the form (see `vm_rule_editor_v2_layout_test.dart`). Null in prod.
  static void Function()? debugOnFormBuild;

  @override
  Widget build(BuildContext context) {
    debugOnFormBuild?.call();
    final t = getLocalizations(context);
    final r = initial;
    final name =
        useTextEditingController(text: r?.name ?? defaultName ?? '');
    final description = useTextEditingController(
        text: r?.description ?? defaultDescription ?? '');
    final matchMode = useState(
        r?.matchMode ?? defaultMatchMode ?? VmMatchMode.patternDir);
    final paths = useState<List<String>>(r != null
        ? (r.paths.isNotEmpty ? [...r.paths] : const [])
        : (defaultPaths == null ? const [] : [...defaultPaths!]));
    final patterns = useState<List<VmPatternEntry>>(
        r != null && r.patterns.isNotEmpty ? [...r.patterns] : const []);
    final sortField = useState(r?.sortField ?? VmSortField.fileName);
    final sortDir = useState(r?.sortDir ?? SortDirection.asc);
    final boundary = useState(r?.boundary ?? VmBoundaryMode.sameDirOnly);
    final maxMinutes =
        useState(r?.maxDurationMinutes ?? kVmDefaultMaxDurationMinutes);
    final maxCount =
        useState(r?.maxItemCount ?? kVmDefaultMaxItemCount);
    final useDuration = useState(r?.useDurationCap ?? true);
    final useCount = useState(r?.useCountCap ?? true);
    final useExcludeOverlong = useState(r?.useExcludeOverlong ?? true);
    final maxSingleMinutes = useState(
        r?.maxSingleDurationMinutes ?? kVmDefaultMaxSingleDurationMinutes);
    final skipSingle = useState(r?.skipSingleSegment ?? true);
    final titleTags = useState<List<VmTitleTag>>(
        r != null ? [...r.titleTags] : const [VmTitleTag.dirName, VmTitleTag.seq]);
    final enabled = useState(r?.enabled ?? true);
    final separator = useState(r?.playerTitleSeparator ?? ':');

    Future<void> save() async {
      if (name.text.trim().isEmpty) {
        if (!context.mounted) return;
        final t = getLocalizations(context);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(t.vm_editor_name),
            content: Text(t.vm_editor_name_required),
          ),
        );
        return;
      }
      // Matcher sanity: specified modes need ≥1 path, pattern modes need ≥1
      // activated non-empty condition — otherwise the rule matches nothing.
      // Invalid regexes fail closed in the resolver; surface them here.
      final specified = matchMode.value == VmMatchMode.specifiedDir ||
          matchMode.value == VmMatchMode.specifiedDirRecursive;
      final activePatterns = [
        for (final p in patterns.value)
          if (p.activated && p.text.trim().isNotEmpty) p,
      ];
      final hasMatcher = specified
          ? paths.value.isNotEmpty
          : activePatterns.isNotEmpty;
      if (!hasMatcher) {
        if (!context.mounted) return;
        final t = getLocalizations(context);
        await showDialog<void>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(t.vm_editor_match_mode_label),
            content: Text(t.vm_editor_no_matcher),
          ),
        );
        return;
      }
      for (final p in activePatterns) {
        if (p.kind == VmPatternKind.regex) {
          var bad = false;
          try {
            RegExp(p.text.trim());
          } catch (_) {
            bad = true;
          }
          if (bad) {
            if (!context.mounted) return;
            final t = getLocalizations(context);
            await showDialog<void>(
              context: context,
              builder: (_) => AlertDialog(
                title: Text(t.vm_editor_match_mode_label),
                content: Text(t.vm_editor_bad_regex(p.text.trim())),
              ),
            );
            return;
          }
        }
      }
      // Both caps unchecked is allowed: the resolver enforces the hard
      // ceilings (5h / 32 items) regardless. Confirm so the user knows.
      if (!useDuration.value && !useCount.value) {
        if (!context.mounted) return;
        final t = getLocalizations(context);
        final ok = await showDialog<bool>(
          context: context,
          builder: (_) => AlertDialog(
            title: Text(t.vm_editor_confirm_caps_title),
            content: Text(t.vm_editor_confirm_caps_body),
            actions: [
              TextButton(
                  onPressed: () => Navigator.pop(context, false),
                  child: Text(t.vm_editor_cancel)),
              TextButton(
                  onPressed: () => Navigator.pop(context, true),
                  child: Text(t.vm_editor_confirm)),
            ],
          ),
        );
        if (ok != true) return;
      }
      if (!context.mounted) return;
      final rule = VirtualMediaRule(
        id: r?.id ?? 'vm_${DateTime.now().microsecondsSinceEpoch}',
        name: name.text.trim(),
        description: description.text.trim(),
        matchMode: matchMode.value,
        // '' is a MEANINGFUL entry: the storage root (picking the storage
        // base relativizes to ''). Dropping it silently produced rules that
        // match nothing — keep it; the resolver treats '' as the root.
        // Legacy entries that somehow stored a raw `content://...` URI are
        // normalized to their readable relative directory on save (a rule
        // path must never be a content URI).
        paths: [
          for (final p in paths.value)
            isSafPath(p.trim()) ? _v2RelativizeToLibrary(p.trim()) : p.trim(),
        ],
        patterns: [
          for (final p in patterns.value)
            if (p.text.trim().isNotEmpty) p,
        ],
        sortField: sortField.value,
        sortDir: sortDir.value,
        boundary: boundary.value,
        maxDurationMinutes: maxMinutes.value
            .clamp(1, kVmHardMaxDurationMinutes),
        maxItemCount: maxCount.value.clamp(1, kVmHardMaxItemCount),
        useDurationCap: useDuration.value,
        useCountCap: useCount.value,
        useExcludeOverlong: useExcludeOverlong.value,
        maxSingleDurationMinutes:
            maxSingleMinutes.value.clamp(1, kVmHardMaxDurationMinutes),
        skipSingleSegment: skipSingle.value,
        titleTags: titleTags.value,
        enabled: enabled.value,
        pinned: r?.pinned ?? false,
        playerTitleSeparator:
            separator.value.isEmpty ? ':' : separator.value[0],
      );
      // Structural change warning (spec §2): changing match/sort/boundary/
      // caps/title config may shift chunk boundaries and invalidates
      // per-scenario virtual progress (v21 vm_progress). Warn once.
      // Deep comparison: pattern contents (kind/text/activation) and title
      // tags also move boundaries — length-only checks missed them and
      // reused stale progress at wrong offsets.
      if (r != null) {
        bool patternsEqual(List<VmPatternEntry> a, List<VmPatternEntry> b) {
          if (a.length != b.length) return false;
          for (var i = 0; i < a.length; i++) {
            if (a[i].kind != b[i].kind ||
                a[i].text.trim() != b[i].text.trim() ||
                a[i].activated != b[i].activated) {
              return false;
            }
          }
          return true;
        }

        bool tagsEqual(List<VmTitleTag> a, List<VmTitleTag> b) {
          if (a.length != b.length) return false;
          for (var i = 0; i < a.length; i++) {
            if (a[i] != b[i]) return false;
          }
          return true;
        }

        final structural = r.paths.join('|') != rule.paths.join('|') ||
            !patternsEqual(r.patterns, rule.patterns) ||
            r.sortField != rule.sortField ||
            r.sortDir != rule.sortDir ||
            r.boundary != rule.boundary ||
            r.maxDurationMinutes != rule.maxDurationMinutes ||
            r.maxItemCount != rule.maxItemCount ||
            r.useDurationCap != rule.useDurationCap ||
            r.useCountCap != rule.useCountCap ||
            r.useExcludeOverlong != rule.useExcludeOverlong ||
            r.maxSingleDurationMinutes != rule.maxSingleDurationMinutes ||
            r.skipSingleSegment != rule.skipSingleSegment ||
            !tagsEqual(r.titleTags, rule.titleTags) ||
            r.playerTitleSeparator != rule.playerTitleSeparator;
        if (structural) {
          if (!context.mounted) return;
          final t = getLocalizations(context);
          final ok = await showDialog<bool>(
            context: context,
            builder: (_) => AlertDialog(
              title: Text(t.vm_editor_confirm_save_title),
              content: Text(t.vm_editor_confirm_save_body),
              actions: [
                TextButton(
                    onPressed: () => Navigator.pop(context, false),
                    child: Text(t.vm_editor_cancel)),
                TextButton(
                    onPressed: () => Navigator.pop(context, true),
                    child: Text(t.vm_editor_confirm)),
              ],
            ),
          );
          if (ok != true) return;
          // Best-effort clear of v21 progress rows for this rule via the
          // repository seam (never hand-written table names).
          try {
            await DbModule.virtualMediaRepo.clearVmProgressForRule(rule.id);
          } catch (_) {}
        }
      }
      await DbModule.virtualMediaRepo.saveRule(rule);
      if (context.mounted) Navigator.of(context).pop(true);
    }

    // Sticky header/footer with a scrollable middle: the footer never leaves
    // the screen (even with the keyboard up) and every input stays reachable.
    return Column(
      mainAxisSize: fillViewport ? MainAxisSize.max : MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
          child: Row(
            children: [
              Expanded(
                child: Text(initial == null ? t.vm_editor_new : t.vm_editor_edit,
                    style: Theme.of(context).textTheme.titleMedium),
              ),
              IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.of(context).pop(false),
              ),
            ],
          ),
        ),
        const Divider(height: 1),
        Flexible(
          child: SingleChildScrollView(
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: LayoutBuilder(builder: (context, constraints) {
              final isNarrow = constraints.maxWidth < 420;
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  _v2Label(context, t.vm_editor_basic),
                  TextField(
                      controller: name,
                      decoration:
                          InputDecoration(labelText: t.vm_editor_name)),
                  TextField(
                      controller: description,
                      decoration: InputDecoration(
                          labelText: t.vm_editor_description)),
                  VmInfoBanner(
                    id: 'editor.match',
                    text: matchMode.value == VmMatchMode.patternDir ||
                            matchMode.value == VmMatchMode.patternDirRecursive
                        ? t.vm_editor_match_banner_pattern
                        : t.vm_editor_match_banner_dirs,
                  ),
                  _v2Label(context, t.vm_editor_match_mode),
                  DropdownButtonFormField<VmMatchMode>(
                    isExpanded: true,
                    initialValue: matchMode.value,
                    decoration:
                        InputDecoration(labelText: t.vm_editor_match_mode_label),
                    items: [
                      DropdownMenuItem(
                          value: VmMatchMode.specifiedDir,
                          child: Text(t.vm_editor_match_specified)),
                      DropdownMenuItem(
                          value: VmMatchMode.specifiedDirRecursive,
                          child: Text(t.vm_editor_match_specified_recursive)),
                      DropdownMenuItem(
                          value: VmMatchMode.patternDir,
                          child: Text(t.vm_editor_match_pattern)),
                      DropdownMenuItem(
                          value: VmMatchMode.patternDirRecursive,
                          child: Text(t.vm_editor_match_pattern_recursive)),
                    ],
                    onChanged: (v) => matchMode.value = v!,
                  ),
                  const SizedBox(height: 8),
                  if (matchMode.value == VmMatchMode.specifiedDir ||
                      matchMode.value == VmMatchMode.specifiedDirRecursive)
                    _V2SpecifiedPathsSection(paths: paths)
                  else
                    _V2PatternEntriesSection(patterns: patterns),
                  _v2Label(context, t.vm_editor_sort),
                  if (isNarrow)
                    Column(children: [
                      DropdownButtonFormField<VmSortField>(
                        isExpanded: true,
                        initialValue: sortField.value,
                        decoration: InputDecoration(
                            labelText: t.vm_editor_sort_field),
                        items: [
                          DropdownMenuItem(
                              value: VmSortField.fileName,
                              child: Text(t.vm_editor_sort_filename)),
                          DropdownMenuItem(
                              value: VmSortField.duration,
                              child: Text(t.vm_editor_sort_duration)),
                          DropdownMenuItem(
                              value: VmSortField.resolution,
                              child: Text(t.vm_editor_sort_resolution)),
                          DropdownMenuItem(
                              value: VmSortField.aspectRatio,
                              child: Text(t.vm_editor_sort_aspect)),
                          DropdownMenuItem(
                              value: VmSortField.width,
                              child: Text(t.vm_editor_sort_width)),
                          DropdownMenuItem(
                              value: VmSortField.height,
                              child: Text(t.vm_editor_sort_height)),
                        ],
                        onChanged: (v) => sortField.value = v!,
                      ),
                      const SizedBox(height: 8),
                      DropdownButtonFormField<SortDirection>(
                        isExpanded: true,
                        initialValue: sortDir.value,
                        decoration: InputDecoration(
                            labelText: t.vm_editor_sort_direction),
                        items: [
                          DropdownMenuItem(
                              value: SortDirection.asc,
                              child: Text(t.vm_editor_sort_asc)),
                          DropdownMenuItem(
                              value: SortDirection.desc,
                              child: Text(t.vm_editor_sort_desc)),
                        ],
                        onChanged: (v) => sortDir.value = v!,
                      ),
                    ])
                  else
                    Row(children: [
                      Expanded(
                        child: DropdownButtonFormField<VmSortField>(
                          isExpanded: true,
                          initialValue: sortField.value,
                          decoration: InputDecoration(
                              labelText: t.vm_editor_sort_field),
                          items: [
                            DropdownMenuItem(
                                value: VmSortField.fileName,
                                child: Text(t.vm_editor_sort_filename)),
                            DropdownMenuItem(
                                value: VmSortField.duration,
                                child: Text(t.vm_editor_sort_duration)),
                            DropdownMenuItem(
                                value: VmSortField.resolution,
                                child: Text(t.vm_editor_sort_resolution)),
                            DropdownMenuItem(
                                value: VmSortField.aspectRatio,
                                child: Text(t.vm_editor_sort_aspect)),
                            DropdownMenuItem(
                                value: VmSortField.width,
                                child: Text(t.vm_editor_sort_width)),
                            DropdownMenuItem(
                                value: VmSortField.height,
                                child: Text(t.vm_editor_sort_height)),
                          ],
                          onChanged: (v) => sortField.value = v!,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: DropdownButtonFormField<SortDirection>(
                          isExpanded: true,
                          initialValue: sortDir.value,
                          decoration: InputDecoration(
                              labelText: t.vm_editor_sort_direction),
                          items: [
                            DropdownMenuItem(
                                value: SortDirection.asc,
                                child: Text(t.vm_editor_sort_asc)),
                            DropdownMenuItem(
                                value: SortDirection.desc,
                                child: Text(t.vm_editor_sort_desc)),
                          ],
                          onChanged: (v) => sortDir.value = v!,
                        ),
                      ),
                    ]),
                  const SizedBox(height: 4),
                  VmInfoBanner(
                      id: 'editor.sort', text: t.vm_editor_sort_banner),
                  _v2Label(context, t.vm_editor_boundary),
                  DropdownButtonFormField<VmBoundaryMode>(
                    isExpanded: true,
                    initialValue: boundary.value,
                    decoration:
                        InputDecoration(labelText: t.vm_editor_boundary_label),
                    items: [
                      DropdownMenuItem(
                          value: VmBoundaryMode.sameDirOnly,
                          child: Text(t.vm_editor_boundary_same_dir,
                              overflow: TextOverflow.ellipsis)),
                      DropdownMenuItem(
                          value: VmBoundaryMode.crossDirMerge,
                          child: Text(t.vm_editor_boundary_cross_dir,
                              overflow: TextOverflow.ellipsis)),
                      DropdownMenuItem(
                          value: VmBoundaryMode.ignoreDirs,
                          child: Text(t.vm_editor_boundary_ignore,
                              overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => boundary.value = v!,
                  ),
                  const SizedBox(height: 12),
                  _V2DurationAndCountField(
                    maxMinutes: maxMinutes.value,
                    maxCount: maxCount.value,
                    useDuration: useDuration.value,
                    useCount: useCount.value,
                    onMinutesChanged: (v) => maxMinutes.value = v,
                    onCountChanged: (v) => maxCount.value = v,
                    onUseDurationChanged: (v) => useDuration.value = v,
                    onUseCountChanged: (v) => useCount.value = v,
                  ),
                  const SizedBox(height: 12),
                  _V2ExclusionFields(
                    useExcludeOverlong: useExcludeOverlong.value,
                    maxSingleMinutes: maxSingleMinutes.value,
                    skipSingle: skipSingle.value,
                    onUseExcludeOverlongChanged: (v) =>
                        useExcludeOverlong.value = v,
                    onMaxSingleMinutesChanged: (v) =>
                        maxSingleMinutes.value = v,
                    onSkipSingleChanged: (v) => skipSingle.value = v,
                  ),
                  _v2Label(context, t.vm_editor_title_tags),
                  VmInfoBanner(
                      id: 'editor.title',
                      text: t.vm_editor_title_banner),
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(10),
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Text(
                      t.vm_editor_title_preview(composeVmTitle(
                        tags: titleTags.value,
                        ruleName: name.text.isEmpty
                            ? t.vm_editor_title_preview_rule
                            : name.text,
                        dirName: t.vm_editor_title_preview_dir,
                        firstFile: t.vm_editor_title_preview_first,
                        lastFile: t.vm_editor_title_preview_last,
                        seq: 1,
                        totalDurationMs: maxMinutes.value * 60 * 1000,
                        width: 1920,
                        height: 1080,
                      )),
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 0,
                    children: [
                      for (final tag in VmTitleTag.values)
                        FilterChip(
                          label: Text(_v2TagLabel(tag, t)),
                          selected: titleTags.value.contains(tag),
                          onSelected: (on) {
                            final next = [...titleTags.value];
                            if (on) {
                              next.add(tag);
                            } else {
                              next.remove(tag);
                            }
                            titleTags.value = next;
                          },
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    initialValue: separator.value,
                    decoration: InputDecoration(
                      labelText: t.vm_editor_separator_label,
                      hintText: t.vm_editor_separator_hint,
                      helperText: t.vm_editor_separator_helper,
                    ),
                    maxLength: 1,
                    onChanged: (v) =>
                        separator.value = v.isEmpty ? ':' : v[0],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: Text(t.vm_editor_enabled),
                    value: enabled.value,
                    onChanged: (v) => enabled.value = v,
                  ),
                ],
              );
            }),
          ),
        ),
        const Divider(height: 1),
        // Fixed footer padding: keyboard avoidance lives in the shell's
        // [KeyboardInsetPadder]. Reading viewInsets here would rebuild the
        // whole form on every keyboard frame (the V1 stall).
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(t.vm_editor_cancel),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child:
                    FilledButton(onPressed: save, child: Text(t.vm_editor_save)),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _v2Label(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );

String _v2TagLabel(VmTitleTag tag, AppLocalizations t) => switch (tag) {
      VmTitleTag.ruleName => t.vm_editor_tag_rule,
      VmTitleTag.dirName => t.vm_editor_tag_dir,
      VmTitleTag.firstFile => t.vm_editor_tag_first,
      VmTitleTag.lastFile => t.vm_editor_tag_last,
      VmTitleTag.seq => t.vm_editor_tag_seq,
      VmTitleTag.duration => t.vm_editor_tag_duration,
      VmTitleTag.resolution => t.vm_editor_tag_resolution,
    };

class _V2SpecifiedPathsSection extends HookWidget {
  const _V2SpecifiedPathsSection({required this.paths});

  final ValueNotifier<List<String>> paths;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final viaInput = useState(false);
    final inputCtrl = useTextEditingController();

    useEffect(() {
      var cancelled = false;
      VmPrefs.pathViaInput().then((v) {
        if (!cancelled) viaInput.value = v;
      });
      return () => cancelled = true;
    }, const []);

    void toggleInput(bool v) {
      viaInput.value = v;
      VmPrefs.setPathViaInput(v);
    }

    Future<void> pickUp() async {
      String? raw;
      try {
        if (isAndroid) {
          final dir = await SafUtil().pickDirectory();
          raw = dir?.uri;
        } else {
          raw = await FilePicker.platform.getDirectoryPath();
        }
      } catch (e) {
        _log.w('vm path pick failed: $e');
      }
      final rel = raw == null ? null : _v2RelativizeToLibrary(raw);
      // '' is the storage root: meaningful, keep it (deduped). Dropping it
      // silently produced match-nothing rules.
      if (rel != null && !paths.value.contains(rel)) {
        paths.value = [...paths.value, rel];
      }
    }

    void addInput() {
      final rel = _v2RelativizeToLibrary(inputCtrl.text);
      if (inputCtrl.text.trim().isEmpty) return;
      if (paths.value.contains(rel)) return;
      paths.value = [...paths.value, rel];
      inputCtrl.clear();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Wrap (not Row+Spacer): on narrow phones the pick button and the
        // input-mode switch share one row on desktop but stack on mobile.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          spacing: 8,
          runSpacing: 4,
          children: [
            ElevatedButton.icon(
              onPressed: viaInput.value ? null : pickUp,
              icon: const Icon(Icons.folder_open, size: 18),
              label: Text(t.vm_editor_pick_dir),
            ),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(t.vm_editor_input_mode,
                    style: Theme.of(context).textTheme.bodySmall),
                Switch(value: viaInput.value, onChanged: toggleInput),
              ],
            ),
          ],
        ),
        if (viaInput.value)
          Row(children: [
            Expanded(
              child: TextField(
                controller: inputCtrl,
                decoration: InputDecoration(
                    labelText: t.vm_editor_paste_path, isDense: true),
                onSubmitted: (_) => addInput(),
              ),
            ),
            IconButton(
              tooltip: t.vm_editor_tooltip_add,
              icon: const Icon(Icons.add),
              onPressed: addInput,
            ),
          ]),
        for (var i = 0; i < paths.value.length; i++)
          Row(children: [
            Expanded(
              child: Text(
                  paths.value[i].isEmpty
                      ? t.vm_editor_library_root
                      : paths.value[i],
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context).textTheme.bodySmall),
            ),
            IconButton(
              visualDensity: VisualDensity.compact,
              tooltip: t.vm_editor_tooltip_remove,
              icon: const Icon(Icons.close, size: 18),
              onPressed: () => paths.value = [...paths.value]..removeAt(i),
            ),
          ]),
      ],
    );
  }
}

class _V2PatternEntriesSection extends HookWidget {
  const _V2PatternEntriesSection({required this.patterns});

  final ValueNotifier<List<VmPatternEntry>> patterns;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    void add() {
      patterns.value = [
        ...patterns.value,
        const VmPatternEntry(kind: VmPatternKind.suffix, text: ''),
      ];
    }

    void replaceAt(int i, VmPatternEntry e) {
      final next = [...patterns.value];
      next[i] = e;
      patterns.value = next;
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // One condition per card (two stacked rows): the old single-row
        // layout (toggle + pin + 92px dropdown + input + delete) overflowed
        // ~360px phones. Cards share one layout on both ends — desktop cards
        // are simply wider.
        for (var i = 0; i < patterns.value.length; i++)
          Card(
            margin: const EdgeInsets.only(bottom: 8),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 4, 4, 10),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(children: [
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: patterns.value[i].activated
                          ? t.vm_editor_pattern_active
                          : t.vm_editor_pattern_inactive,
                      icon: Icon(
                        patterns.value[i].activated
                            ? Icons.toggle_on_rounded
                            : Icons.toggle_off_rounded,
                        size: 24,
                        color: patterns.value[i].activated
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onPressed: () => replaceAt(
                          i,
                          patterns.value[i].copyWith(
                              activated: !patterns.value[i].activated)),
                    ),
                    Expanded(
                      child: DropdownButtonFormField<VmPatternKind>(
                        isExpanded: true,
                        initialValue: patterns.value[i].kind,
                        decoration:
                            const InputDecoration(isDense: true),
                        items: [
                          DropdownMenuItem(
                              value: VmPatternKind.prefix,
                              child: Text(t.vm_editor_pattern_prefix)),
                          DropdownMenuItem(
                              value: VmPatternKind.suffix,
                              child: Text(t.vm_editor_pattern_suffix)),
                          DropdownMenuItem(
                              value: VmPatternKind.contains,
                              child: Text(t.vm_editor_pattern_contains)),
                          DropdownMenuItem(
                              value: VmPatternKind.regex,
                              child: Text(t.vm_editor_pattern_regex)),
                        ],
                        onChanged: (v) => replaceAt(
                            i, patterns.value[i].copyWith(kind: v!)),
                      ),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: patterns.value[i].pinned
                          ? t.vm_editor_pattern_pinned
                          : t.vm_editor_pattern_pin,
                      icon: Icon(
                        patterns.value[i].pinned
                            ? Icons.push_pin_rounded
                            : Icons.push_pin_outlined,
                        size: 18,
                        color: patterns.value[i].pinned
                            ? Theme.of(context).colorScheme.primary
                            : null,
                      ),
                      onPressed: () => replaceAt(
                          i,
                          patterns.value[i].copyWith(
                              pinned: !patterns.value[i].pinned)),
                    ),
                    IconButton(
                      visualDensity: VisualDensity.compact,
                      tooltip: t.vm_editor_tooltip_remove,
                      icon: const Icon(Icons.close, size: 18),
                      onPressed: () =>
                          patterns.value = [...patterns.value]
                            ..removeAt(i),
                    ),
                  ]),
                  Padding(
                    padding: const EdgeInsets.fromLTRB(12, 2, 12, 0),
                    child: TextFormField(
                      initialValue: patterns.value[i].text,
                      decoration: InputDecoration(
                          hintText: t.vm_editor_pattern_hint, isDense: true),
                      onChanged: (t) {
                        patterns.value[i] =
                            patterns.value[i].copyWith(text: t);
                      },
                    ),
                  ),
                ],
              ),
            ),
          ),
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: add,
            icon: const Icon(Icons.add, size: 18),
            label: Text(t.vm_editor_add_condition),
          ),
        ),
      ],
    );
  }
}

class _V2DurationAndCountField extends HookWidget {
  const _V2DurationAndCountField({
    required this.maxMinutes,
    required this.maxCount,
    required this.useDuration,
    required this.useCount,
    required this.onMinutesChanged,
    required this.onCountChanged,
    required this.onUseDurationChanged,
    required this.onUseCountChanged,
  });

  final int maxMinutes;
  final int maxCount;
  final bool useDuration;
  final bool useCount;
  final ValueChanged<int> onMinutesChanged;
  final ValueChanged<int> onCountChanged;
  final ValueChanged<bool> onUseDurationChanged;
  final ValueChanged<bool> onUseCountChanged;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final hhCtrl = useTextEditingController();
    final mmCtrl = useTextEditingController();
    final cntCtrl = useTextEditingController();
    final hhNode = useFocusNode();
    final mmNode = useFocusNode();

    useEffect(() {
      final hh = (maxMinutes ~/ 60).clamp(0, 5);
      final mm = (maxMinutes % 60).clamp(0, 59);
      final hhText = '$hh';
      final mmText = '$mm';
      if (hhCtrl.text != hhText) hhCtrl.text = hhText;
      if (mmCtrl.text != mmText) mmCtrl.text = mmText;
      final cntText = '${maxCount.clamp(1, kVmHardMaxItemCount)}';
      if (cntCtrl.text != cntText) cntCtrl.text = cntText;
      return null;
    }, [maxMinutes, maxCount]);

    void commitDuration() {
      final hh = int.tryParse(hhCtrl.text) ?? 0;
      final mm = int.tryParse(mmCtrl.text) ?? 0;
      final v = (hh.clamp(0, 5) * 60 + mm.clamp(0, 59))
          .clamp(1, kVmHardMaxDurationMinutes);
      if (v != maxMinutes) onMinutesChanged(v);
    }

    void commitCount() {
      final v = (int.tryParse(cntCtrl.text) ?? kVmDefaultMaxItemCount)
          .clamp(1, kVmHardMaxItemCount);
      if (v != maxCount) onCountChanged(v);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.vm_editor_caps_title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
        const SizedBox(height: 8),
        // Wrap (not Row): fixed-width time cells share one row on desktop
        // but flow onto a second line on narrow phones / large fonts.
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 3,
          runSpacing: 8,
          children: [
            Checkbox(
              value: useDuration,
              onChanged: (v) => onUseDurationChanged(v ?? true),
              visualDensity: VisualDensity.compact,
            ),
            Text(t.vm_editor_caps_longest),
            const SizedBox(width: 6),
            SizedBox(
              width: 56,
              child: TextField(
                controller: hhCtrl,
                focusNode: hhNode,
                enabled: useDuration,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(2),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'hh',
                  counterText: '',
                ),
                onChanged: (t) {
                  if (t.length == 2) mmNode.requestFocus();
                  commitDuration();
                },
                onSubmitted: (_) {
                  mmNode.requestFocus();
                  commitDuration();
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Text(':'),
            ),
            SizedBox(
              width: 64,
              child: TextField(
                controller: mmCtrl,
                focusNode: mmNode,
                enabled: useDuration,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'mm',
                  counterText: '',
                ),
                onChanged: (_) => commitDuration(),
                onSubmitted: (_) => commitDuration(),
              ),
            ),
            const SizedBox(width: 6),
            Text(t.vm_editor_caps_hhmm,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 3,
          runSpacing: 8,
          children: [
            Checkbox(
              value: useCount,
              onChanged: (v) => onUseCountChanged(v ?? true),
              visualDensity: VisualDensity.compact,
            ),
            Text(t.vm_editor_caps_most),
            const SizedBox(width: 6),
            SizedBox(
              width: 64,
              child: TextField(
                controller: cntCtrl,
                enabled: useCount,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: InputDecoration(
                  isDense: true,
                  border: const OutlineInputBorder(),
                  hintText: t.vm_editor_caps_unit,
                  counterText: '',
                ),
                onChanged: (_) => commitCount(),
                onSubmitted: (_) => commitCount(),
              ),
            ),
            const SizedBox(width: 6),
            Text(t.vm_editor_caps_items,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ],
    );
  }
}

/// Per-file exclusion switches: (1) leave single videos longer than a
/// configurable threshold out of the merge, (2) do not virtualize a chunk
/// that collapsed to one file. Same visual language as
/// [_V2DurationAndCountField] (checkbox + compact hh:mm cells inside a Wrap).
class _V2ExclusionFields extends HookWidget {
  const _V2ExclusionFields({
    required this.useExcludeOverlong,
    required this.maxSingleMinutes,
    required this.skipSingle,
    required this.onUseExcludeOverlongChanged,
    required this.onMaxSingleMinutesChanged,
    required this.onSkipSingleChanged,
  });

  final bool useExcludeOverlong;
  final int maxSingleMinutes;
  final bool skipSingle;
  final ValueChanged<bool> onUseExcludeOverlongChanged;
  final ValueChanged<int> onMaxSingleMinutesChanged;
  final ValueChanged<bool> onSkipSingleChanged;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final hhCtrl = useTextEditingController();
    final mmCtrl = useTextEditingController();
    final hhNode = useFocusNode();
    final mmNode = useFocusNode();

    useEffect(() {
      final hh = (maxSingleMinutes ~/ 60).clamp(0, 5);
      final mm = (maxSingleMinutes % 60).clamp(0, 59);
      final hhText = '$hh';
      final mmText = '$mm';
      if (hhCtrl.text != hhText) hhCtrl.text = hhText;
      if (mmCtrl.text != mmText) mmCtrl.text = mmText;
      return null;
    }, [maxSingleMinutes]);

    void commit() {
      final hh = int.tryParse(hhCtrl.text) ?? 0;
      final mm = int.tryParse(mmCtrl.text) ?? 0;
      final v = (hh.clamp(0, 5) * 60 + mm.clamp(0, 59))
          .clamp(1, kVmHardMaxDurationMinutes);
      if (v != maxSingleMinutes) onMaxSingleMinutesChanged(v);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(t.vm_editor_exclusion_title,
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontWeight: FontWeight.w600,
                )),
        const SizedBox(height: 8),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 3,
          runSpacing: 8,
          children: [
            Checkbox(
              value: useExcludeOverlong,
              onChanged: (v) => onUseExcludeOverlongChanged(v ?? true),
              visualDensity: VisualDensity.compact,
            ),
            Text(t.vm_editor_exclude_long_prefix),
            const SizedBox(width: 6),
            SizedBox(
              width: 56,
              child: TextField(
                controller: hhCtrl,
                focusNode: hhNode,
                enabled: useExcludeOverlong,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(2),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'hh',
                  counterText: '',
                ),
                onChanged: (value) {
                  if (value.length == 2) mmNode.requestFocus();
                  commit();
                },
                onSubmitted: (_) {
                  mmNode.requestFocus();
                  commit();
                },
              ),
            ),
            const Padding(
              padding: EdgeInsets.symmetric(horizontal: 2),
              child: Text(':'),
            ),
            SizedBox(
              width: 64,
              child: TextField(
                controller: mmCtrl,
                focusNode: mmNode,
                enabled: useExcludeOverlong,
                textAlign: TextAlign.center,
                keyboardType: TextInputType.number,
                inputFormatters: [
                  FilteringTextInputFormatter.digitsOnly,
                  LengthLimitingTextInputFormatter(3),
                ],
                decoration: const InputDecoration(
                  isDense: true,
                  border: OutlineInputBorder(),
                  hintText: 'mm',
                  counterText: '',
                ),
                onChanged: (_) => commit(),
                onSubmitted: (_) => commit(),
              ),
            ),
            const SizedBox(width: 6),
            Text(t.vm_editor_caps_hhmm,
                style: Theme.of(context).textTheme.bodySmall),
            const SizedBox(width: 4),
            Text(t.vm_editor_exclude_long_suffix),
          ],
        ),
        const SizedBox(height: 6),
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 3,
          runSpacing: 8,
          children: [
            Checkbox(
              value: skipSingle,
              onChanged: (v) => onSkipSingleChanged(v ?? true),
              visualDensity: VisualDensity.compact,
            ),
            Text(t.vm_editor_skip_single),
          ],
        ),
      ],
    );
  }
}

String _v2RelativizeToLibrary(String raw) {
  // Single source of truth: `relativeToStoragePath` owns SAF tail decoding,
  // longest-base matching and the segment-boundary rule. The local copy that
  // lived here drifted — it mapped a SAF descendant to '' (the storage root)
  // and stripped `E:/media2` under a bare `E:/media` prefix.
  return relativeToStoragePath(
    raw,
    useStorageStore().state.storages.map((s) => s.basePath.join('/')),
  );
}
