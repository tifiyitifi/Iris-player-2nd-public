import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/model/enum/bg_apply_scope.dart';
import 'package:iris/features/background_playback/model/enum/bg_cross_action.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/model/enum/bg_reactivate_mode.dart';
import 'package:iris/features/background_playback/model/enum/bg_vm_scope_mode.dart';
import 'package:iris/features/background_playback/services/current_foreground_media_key.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/utils/get_localizations.dart';

/// 作用范围 picker — which foreground media the 副音 activation applies to,
/// plus whether that choice survives a restart.
///
/// Shared by the quick bar's scope button and the 副音 menu so the preference
/// has exactly one editor. Rendered as a NON-MODAL draggable card by
/// `BgQuickPanelHost`; this entry point just toggles that card.
Future<void> showBackgroundScopeDialog(BuildContext context) async {
  useBackgroundPlaybackStore().toggleQuickPanel(BgQuickPanel.scope);
}

/// Body of the 作用范围 card (no dialog chrome — the host card supplies the
/// draggable header and close button).
class BackgroundScopePanelContent extends HookWidget {
  const BackgroundScopePanelContent({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final bg = useBackgroundPlaybackStore();
    final scope = bg.select(context, (s) => s.applyScope);
    final persist = bg.select(context, (s) => s.scopePersist);
    final vmScopeMode = bg.select(context, (s) => s.bgVmScopeMode);
    final itemSwitch = bg.select(context, (s) => s.bgItemSwitch);
    final segmentSwitch = bg.select(context, (s) => s.bgSegmentSwitch);
    final reactivateMode = bg.select(context, (s) => s.bgReactivateMode);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Narrow hosts (360px phone, large font) scroll the segment row
          // horizontally instead of overflowing.
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<BgApplyScope>(
              showSelectedIcon: false,
              segments: [
                ButtonSegment(
                  value: BgApplyScope.currentOnly,
                  label: Text(t.bg_scope_current_only),
                ),
                ButtonSegment(
                  value: BgApplyScope.smart,
                  label: Text(t.bg_scope_smart),
                ),
                ButtonSegment(
                  value: BgApplyScope.all,
                  label: Text(t.bg_scope_all),
                ),
              ],
              selected: {scope},
              onSelectionChanged: (s) {
                final next = s.first;
                bg.setApplyScope(next);
                // 「仅当前」anchors the run to the media playing NOW, so
                // switching out of 「全部」 (which carries no anchor) must
                // re-anchor a live run — otherwise it reads as out of scope
                // until the gate is opened again.
                if (next == BgApplyScope.currentOnly) {
                  bg.setScopeAnchor(currentScopeKey());
                }
              },
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _desc(scope, t),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 4),
          CheckboxListTile(
            contentPadding: EdgeInsets.zero,
            value: persist,
            onChanged: (v) => bg.setScopePersist(v ?? false),
            title: Text(t.bg_scope_persist),
            subtitle: Text(t.bg_scope_persist_desc),
          ),
          const Divider(height: 20),
          // 虚拟视频匹配 (仅当前 only): whether the whole virtual video counts
          // as one media, or only the block on screen does.
          if (scope == BgApplyScope.currentOnly) ...[
            Text(t.bg_vm_scope_rule,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<BgVmScopeMode>(
                key: const ValueKey('bg_vm_scope_segments'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: BgVmScopeMode.perBlock,
                    label: Text(t.bg_vm_scope_per_block),
                  ),
                  ButtonSegment(
                    value: BgVmScopeMode.wholeVirtual,
                    label: Text(t.bg_vm_scope_whole),
                  ),
                ],
                selected: {vmScopeMode},
                onSelectionChanged: (s) => bg.setBgVmScopeMode(s.first),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              vmScopeMode == BgVmScopeMode.perBlock
                  ? t.bg_vm_scope_per_block_desc
                  : t.bg_vm_scope_whole_desc,
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const Divider(height: 20),
          ],
          // 跨视频切换（两个独立开关）: what 副音 does on a new LIST ITEM, and on
          // a virtual video's SEGMENT switch. The 作用范围 above always wins.
          Text(t.bg_cross_section,
              style: Theme.of(context).textTheme.labelLarge),
          const SizedBox(height: 10),
          _CrossSwitch(
            keyPrefix: 'bg_item_switch',
            title: t.bg_cross_item_title,
            desc: t.bg_cross_item_desc,
            value: itemSwitch,
            keepLabel: t.bg_cross_keep_playing,
            onChanged: (v) => bg.setBgItemSwitch(v),
          ),
          const SizedBox(height: 12),
          _CrossSwitch(
            keyPrefix: 'bg_segment_switch',
            title: t.bg_cross_segment_title,
            desc: t.bg_cross_segment_desc,
            value: segmentSwitch,
            keepLabel: t.bg_cross_keep_playing_tiled,
            onChanged: (v) => bg.setBgSegmentSwitch(v),
          ),
          // 仅当前 re-activation: which 副音 track the gate lands on after an
          // explicit stop (same bg / next bg). Rarely changed, so it sits at
          // the bottom, and only the current-only scope consults it.
          if (scope == BgApplyScope.currentOnly) ...[
            const Divider(height: 20),
            Text(t.bg_reactivate_title,
                style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 8),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SegmentedButton<BgReactivateMode>(
                key: const ValueKey('bg_reactivate_segments'),
                showSelectedIcon: false,
                segments: [
                  ButtonSegment(
                    value: BgReactivateMode.sameBg,
                    label: Text(t.bg_reactivate_same),
                  ),
                  ButtonSegment(
                    value: BgReactivateMode.nextBg,
                    label: Text(t.bg_reactivate_next),
                  ),
                ],
                selected: {reactivateMode},
                onSelectionChanged: (s) => bg.setBgReactivateMode(s.first),
              ),
            ),
            const SizedBox(height: 4),
            Text(t.bg_reactivate_desc,
                style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      ),
    );
  }
}

/// One 跨视频 binary switch: a titled question with 正常连播 / 切新 bg segments,
/// followed by a one-line note on what the transition covers.
class _CrossSwitch extends StatelessWidget {
  const _CrossSwitch({
    required this.keyPrefix,
    required this.title,
    required this.desc,
    required this.value,
    required this.keepLabel,
    required this.onChanged,
  });

  final String keyPrefix;
  final String title;
  final String desc;
  final BgCrossAction value;
  final String keepLabel;
  final ValueChanged<BgCrossAction> onChanged;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(title, style: theme.textTheme.bodyMedium),
        const SizedBox(height: 6),
        SingleChildScrollView(
          scrollDirection: Axis.horizontal,
          child: SegmentedButton<BgCrossAction>(
            key: ValueKey('${keyPrefix}_segments'),
            showSelectedIcon: false,
            segments: [
              ButtonSegment(
                value: BgCrossAction.keepPlaying,
                label: Text(keepLabel),
              ),
              ButtonSegment(
                value: BgCrossAction.newBg,
                label: Text(t.bg_cross_new_bg),
              ),
            ],
            selected: {value},
            onSelectionChanged: (s) => onChanged(s.first),
          ),
        ),
        const SizedBox(height: 4),
        Text(desc, style: theme.textTheme.bodySmall),
      ],
    );
  }
}

String _desc(BgApplyScope scope, AppLocalizations t) => switch (scope) {
      BgApplyScope.currentOnly => t.bg_scope_current_only_desc,
      BgApplyScope.smart => t.bg_scope_smart_desc,
      BgApplyScope.all => t.bg_scope_all_desc,
    };
