import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/scenario_playback/actions/stay_mode_page_action.dart';

/// Pin factory (v11-D3 / v12-D3): icon reflects the stay state, no forced size
/// (default 24, aligned with the legacy files-paged toolbar), and onPressed
/// forwards to the caller's toggle callback.
void main() {
  test('stay=true renders the pinned icon with the stay label', () {
    final action = buildStayModePageAction(
      stay: true,
      onToggle: () {},
      stayLabel: 'Stay in preview',
      leaveLabel: 'Close storagedb',
    );
    expect(action.label, 'Stay in preview');
    final icon = action.icon as Icon;
    expect(icon.icon, Icons.push_pin);
  });

  test('stay=false renders the outlined icon with the leave label', () {
    final action = buildStayModePageAction(
      stay: false,
      onToggle: () {},
      stayLabel: 'Stay in preview',
      leaveLabel: 'Close storagedb',
    );
    expect(action.label, 'Close storagedb');
    final icon = action.icon as Icon;
    expect(icon.icon, Icons.push_pin_outlined);
  });

  test('the icon carries no explicit size (default 24, legacy-aligned)', () {
    final action = buildStayModePageAction(
      stay: true,
      onToggle: () {},
      stayLabel: 'Stay in preview',
      leaveLabel: 'Close storagedb',
    );
    final icon = action.icon as Icon;
    expect(icon.size, isNull);
  });

  test('onPressed invokes the toggle callback', () {
    var toggled = false;
    final action = buildStayModePageAction(
      stay: false,
      onToggle: () {
        toggled = true;
      },
      stayLabel: 'Stay in preview',
      leaveLabel: 'Close storagedb',
    );
    action.onPressed!();
    expect(toggled, isTrue);
  });
}
