import 'package:iris/features/meta_settings/model/enum/settings_section.dart';
import 'package:iris/features/meta_settings/model/enum/setting_value_type.dart';
import 'package:iris/features/meta_settings/model/enum/setting_widget_kind.dart';
import 'package:iris/features/meta_settings/model/setting_def.dart';

abstract final class VirtualMediaSettingsContribution {
  static const String groupHeaderKey = 'group_virtual_media';

  static const List<SettingDef> defs = <SettingDef>[
    SettingDef(
      key: 'virtualmedia.managerEntry',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'virtual_media_manager',
      titleKey: 'virtual_media',
      subtitleKey: 'virtual_media_desc',
      iconKey: 'virtual_media',
      groupHeaderKey: groupHeaderKey,
      sortOrder: 54,
    ),
    // Values live in `virtualmedia.*` AUX rows via AppStore (cross-drag /
    // dual-time / ticks) and VmPrefs (naming), NOT the `app.`
    // snapshot — the generic enumPick renderer only reads `app.` and would
    // silently no-op. Custom + editorKey routes through the typed store.
    SettingDef(
      key: 'virtualmedia.crossDragStrategy',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      defaultValue: 'directSwitch',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_cross_drag_strategy',
      titleKey: 'virtual_media_cross_drag',
      subtitleKey: 'virtual_media_cross_drag_desc',
      iconKey: 'virtual_media',
      sortOrder: 55,
    ),
    SettingDef(
      key: 'virtualmedia.markTickColor',
      section: SettingsSection.play,
      valueType: SettingValueType.int,
      defaultValue: '4294967295',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_mark_tick_color',
      titleKey: 'vm_mark_tick_color',
      subtitleKey: 'vm_mark_tick_color_desc',
      iconKey: 'virtual_media',
      sortOrder: 56,
    ),
    // NOTE: markTickExtent (0-15px, default 7) persists as a
    // `virtualmedia.markTickExtent` AUX row via AppStore.updateVmMarkTickExtent
    // and is edited inside the shared `vm_mark_tick_color` dialog — no second
    // def (mirrors hideChunkWhenSingleSegment; keeps parity-test key lists).
    // NOTE: hideChunkWhenSingleSegment persists as
    // `virtualmedia.hideChunkWhenSingleSegment` via
    // AppStore.updateVmHideChunkWhenSingleSegment; its switch tile lives in
    // editor_bindings (`vm_hide_chunk_when_single_segment`).
    SettingDef(
      key: 'virtualmedia.namingStrategy',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      defaultValue: 'maxPlusOne',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_naming_strategy',
      titleKey: 'vm_naming_strategy',
      subtitleKey: 'vm_naming_strategy_desc',
      iconKey: 'virtual_media',
      sortOrder: 57,
    ),
    SettingDef(
      key: 'virtualmedia.namePrefix',
      section: SettingsSection.play,
      valueType: SettingValueType.string,
      defaultValue: 'rule',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'virtual_media_name_prefix',
      titleKey: 'vm_name_prefix',
      subtitleKey: 'vm_name_prefix_desc',
      iconKey: 'virtual_media',
      sortOrder: 58,
    ),
    SettingDef(
      key: 'virtualmedia.nameNumberFormat',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      defaultValue: 'raw',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_name_number_format',
      titleKey: 'vm_name_number_format',
      subtitleKey: 'vm_name_number_format_desc',
      iconKey: 'virtual_media',
      sortOrder: 59,
    ),
    // Dual-time second-grid alignment (display-only; `virtualmedia.dualTimeSync`
    // AUX row via AppStore.updateVmDualTimeSync). Custom + async loader like
    // the other AUX-only enum rows.
    SettingDef(
      key: 'virtualmedia.dualTimeSync',
      section: SettingsSection.play,
      valueType: SettingValueType.json,
      defaultValue: 'subToTotal',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_dual_time_sync',
      titleKey: 'vm_dual_time_sync',
      subtitleKey: 'vm_dual_time_sync_desc',
      iconKey: 'virtual_media',
      sortOrder: 60,
    ),
    // Dial-ring chunk indicator for single-segment virtual items (spec §8):
    // `virtualmedia.hideChunkWhenSingleSegment` AUX row via
    // AppStore.updateVmHideChunkWhenSingleSegment.
    SettingDef(
      key: 'virtualmedia.hideChunkWhenSingleSegment',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'false',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_hide_chunk_when_single_segment',
      titleKey: 'vm_hide_chunk_when_single_segment',
      subtitleKey: 'vm_hide_chunk_when_single_segment_desc',
      iconKey: 'virtual_media',
      sortOrder: 61,
    ),
    // Scenario-search multi-select hint for virtual merged media.
    // `virtualmedia.multiSelectHintHidden` AUX row via VmPrefs; the switch
    // re-enables a previously dismissed hint ("取消永关").
    SettingDef(
      key: 'virtualmedia.multiSelectHint',
      section: SettingsSection.play,
      valueType: SettingValueType.bool,
      defaultValue: 'true',
      widgetKind: SettingWidgetKind.custom,
      editorKey: 'vm_multi_select_hint',
      titleKey: 'vm_multi_select_hint',
      subtitleKey: 'vm_multi_select_hint_desc',
      iconKey: 'virtual_media',
      sortOrder: 62,
    ),
  ];
}
