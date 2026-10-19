import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/background_playback/background_playback_gate.dart';
import 'package:iris/features/background_playback/contributions/background_playback_settings_contribution.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/engine/def_visibility.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/features/meta_settings/model/enum/setting_widget_kind.dart';
import 'package:iris/features/meta_settings/view/widgets/editor_bindings.dart';
import 'package:iris/features/meta_settings/view/widgets/setting_editors.dart';

void main() {
  group('background_playback meta rows', () {
    test('catalog carries the custom rows and merges without conflicts', () {
      // Reading the catalog runs the fail-fast merger — duplicates or invalid
      // defs throw here.
      final keys = SettingsCatalog.defs
          .where((d) => d.key.startsWith('background_playback.'))
          .toList();
      expect(keys, hasLength(31));
      expect(
        keys.map((d) => d.key),
        containsAll([
          'background_playback.followFgSwitch',
          'background_playback.rateLock',
          'background_playback.allowSameFile',
          'background_playback.videoLayout',
          // sub_media §1 / §5.2 / §5.5 additions.
          'background_playback.keepWarmPlayer',
          // 开机状态: arm the run at startup (independent of the preload above).
          'background_playback.startArmed',
          // 副音 button stop behavior: pause (re-align) vs unload (reload).
          'background_playback.gateStopBehavior',
          'background_playback.alignDefault',
          'background_playback.ratioExplicitSave',
          // 第 3 轮 additions (progress lock split into two axes).
          'background_playback.autoFocusControl',
          'background_playback.seekLink',
          'background_playback.lockLevel',
          'background_playback.alignRingAssignment',
          'background_playback.quickBar',
          'background_playback.quickBarAlign',
          // VM × 副音 matching mode + 跨视频 switches.
          'background_playback.vmScopeMode',
          'background_playback.itemSwitch',
          'background_playback.segmentSwitch',
          // 换集行为 + alignment threshold + exhausted behaviour.
          'background_playback.stepMode',
          'background_playback.alignAutoPauseRemainSec',
          'background_playback.exhaustedAction',
          // A newly tagged video reaching a live queue: rebuild vs append.
          'background_playback.queueSyncMode',
          // A/P/B editor: segment minimum length, P boundary behaviour, guide.
          'background_playback.minSegmentSpanMs',
          'background_playback.pAlignKeepMaxLength',
          'background_playback.stickyConsume',
          'background_playback.segmentGuide',
          // APB fg zoom window: multiplier + q push-at-boundary behaviour.
          'background_playback.fgWindowZoom',
          'background_playback.fgWindowPushBg',
          // Snap-to-saved-boundary (卡值） + its release memory bound.
          'background_playback.snapEnabled',
          'background_playback.snapReleaseLimit',
          // 自动使用已保存的映射 (E 节 playback switch).
          'background_playback.useSavedMapping',
        ]),
      );
      for (final d in keys) {
        expect(d.widgetKind, SettingWidgetKind.custom,
            reason: 'non-app.* rows must never use the generic renderers');
        expect(d.editorKey, isNotNull);
      }
      expect(keys.first.groupHeaderKey,
          BackgroundPlaybackSettingsContribution.groupHeaderKey);
    });

    test('the default-anchoring row is informational (no options)', () {
      final def = SettingsCatalog.defs
          .singleWhere((d) => d.key == 'background_playback.alignDefault');
      // Anchoring is decided automatically, so the row must not offer an enum
      // of choices; it only explains the rule.
      expect(def.valueType, SettingValueType.json);
      expect(def.enumValues, isEmpty);
      expect(def.editorKey, 'bg_align_default');
    });

    test('every bg editor key has a registered binding', () {
      EditorBindings.ensureRegistered();
      for (final key in [
        'bg_follow_fg_switch',
        'bg_rate_lock',
        'bg_allow_same_file',
        'bg_video_layout',
        'bg_keep_warm',
        'bg_start_armed',
        'bg_gate_stop_behavior',
        'bg_align_default',
        'bg_ratio_explicit_save',
        'bg_auto_focus_control',
        'bg_seek_link',
        'bg_lock_level',
        'bg_align_ring',
        'bg_quick_bar',
        'bg_quick_bar_align',
        'bg_vm_scope_mode',
        'bg_item_switch',
        'bg_segment_switch',
        'bg_step_mode',
        'bg_align_warn',
        'bg_exhausted_action',
        'bg_min_segment_span',
        'bg_p_align_keep_length',
        'bg_sticky_consume',
        'bg_segment_guide',
        'bg_fg_window_zoom',
        'bg_fg_window_push_bg',
        'bg_align_snap',
        'bg_align_snap_release_limit',
        'bg_use_saved_mapping',
      ]) {
        expect(SettingEditors.lookup(key), isNotNull,
            reason: '$key must have a hand-written editor binding');
      }
    });

    test('DefVisibility prefix gates the rows on the feature gate', () {
      DefVisibility.registerPrefix(
        'background_playback.',
        () => BackgroundPlaybackGate.enabled,
      );
      // A registered prefix never hides other keys…
      expect(DefVisibility.isVisible('gesture.x'), isTrue);
      // …and the predicate is evaluated lazily per render (flip + re-check).
      var on = true;
      DefVisibility.registerPrefix('background_playback.', () => on);
      expect(DefVisibility.isVisible('background_playback.rateLock'), isTrue);
      on = false;
      expect(DefVisibility.isVisible('background_playback.rateLock'), isFalse);
      DefVisibility.registerPrefix('background_playback.', () => true);
    });
  });
}
