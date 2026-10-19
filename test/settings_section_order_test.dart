import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/model/enum/settings_section.dart';

/// Semantic grouping invariants for the metadata settings page.
///
/// Every section renders as (section, sortOrder) runs of rows, and a new
/// visual group starts only at a row carrying groupHeaderKey. These tests
/// pin the contract so a new contribution cannot silently reshuffle tiles:
/// sortOrders must be unique per section (Dart's sort is unstable on ties),
/// each group has exactly one leader, and blocks follow semantic order.
void main() {
  group('settings section ordering invariants', () {
    test('sortOrders are unique within each section', () {
      for (final section in SettingsSection.values) {
        final orders = SettingsCatalog.defs
            .where((d) => d.section == section)
            .map((d) => d.sortOrder)
            .toList();
        expect(orders.toSet().length, orders.length,
            reason: '$section has tied sortOrders (unstable render order)');
      }
    });

    test('each group header has exactly one leader row', () {
      final counts = <String, int>{};
      for (final d in SettingsCatalog.defs) {
        final h = d.groupHeaderKey;
        if (h != null) counts[h] = (counts[h] ?? 0) + 1;
      }
      for (final e in counts.entries) {
        expect(e.value, 1, reason: 'group ${e.key} has ${e.value} leaders');
      }
    });

    test('play renders semantic blocks in order', () {
      final headers = SettingsCatalog.defs
          .where((d) => d.section == SettingsSection.play)
          .where((d) => d.groupHeaderKey != null)
          .map((d) => d.groupHeaderKey!)
          .toList();
      expect(headers, [
        'group_playback',
        'group_gestures',
        'group_virtual_media',
        'group_background_playback',
        'group_desktop_tools',
        'group_desktop_hover',
        'group_center_zone',
      ]);
    });

    test('general renders semantic blocks in order', () {
      final headers = SettingsCatalog.defs
          .where((d) => d.section == SettingsSection.general)
          .where((d) => d.groupHeaderKey != null)
          .map((d) => d.groupHeaderKey!)
          .toList();
      expect(headers, [
        'group_appearance',
        'group_data',
        'group_titles',
        'group_warnings',
        'group_osd',
        'group_scan',
        'group_tag_play',
        'group_advanced',
      ]);
    });

    test('background_playback rows follow semantic order', () {
      final keys = SettingsCatalog.defs
          .where((d) => d.key.startsWith('background_playback.'))
          .map((d) => d.key)
          .toList();
      expect(keys, [
        'background_playback.keepWarmPlayer',
        'background_playback.startArmed',
        'background_playback.autoFocusControl',
        'background_playback.followFgSwitch',
        'background_playback.allowSameFile',
        'background_playback.rateLock',
        'background_playback.videoLayout',
        'background_playback.alignDefault',
        'background_playback.ratioExplicitSave',
        'background_playback.seekLink',
        'background_playback.quickBar',
        'background_playback.quickBarAlign',
        'background_playback.minSegmentSpanMs',
        'background_playback.pAlignKeepMaxLength',
        'background_playback.stickyConsume',
        'background_playback.segmentGuide',
        'background_playback.gateStopBehavior',
        'background_playback.fgWindowZoom',
        'background_playback.fgWindowPushBg',
        'background_playback.snapEnabled',
        'background_playback.snapReleaseLimit',
        'background_playback.useSavedMapping',
        'background_playback.lockLevel',
        'background_playback.alignRingAssignment',
        'background_playback.stepMode',
        'background_playback.vmScopeMode',
        'background_playback.itemSwitch',
        'background_playback.segmentSwitch',
        'background_playback.alignAutoPauseRemainSec',
        'background_playback.exhaustedAction',
        'background_playback.queueSyncMode',
      ]);
    });

    test('virtualmedia rows follow semantic order', () {
      final keys = SettingsCatalog.defs
          .where((d) => d.key.startsWith('virtualmedia.'))
          .map((d) => d.key)
          .toList();
      expect(keys, [
        'virtualmedia.managerEntry',
        'virtualmedia.crossDragStrategy',
        'virtualmedia.markTickColor',
        'virtualmedia.namingStrategy',
        'virtualmedia.namePrefix',
        'virtualmedia.nameNumberFormat',
        'virtualmedia.dualTimeSync',
        'virtualmedia.hideChunkWhenSingleSegment',
        'virtualmedia.multiSelectHint',
      ]);
    });

    test('background_playback rows are contiguous (no foreign row splits '
        'the group under a different header)', () {
      final playKeys = SettingsCatalog.defs
          .where((d) => d.section == SettingsSection.play)
          .map((d) => d.key)
          .toList();
      final indices = <int>[
        for (var i = 0; i < playKeys.length; i++)
          if (playKeys[i].startsWith('background_playback.')) i,
      ];
      final first = indices.first;
      final last = indices.last;
      for (var i = first; i <= last; i++) {
        expect(playKeys[i], startsWith('background_playback.'),
            reason: '${playKeys[i]} splits the background_playback group at '
                '$i (rows $first..$last must be contiguous)');
      }
    });
  });
}
