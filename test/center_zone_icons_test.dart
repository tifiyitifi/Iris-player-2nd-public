import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/control_group/domain/center_zone_icons.dart';
import 'package:iris/features/control_group/view/center_zone_sector_icons.dart';
import 'package:iris/models/store/app_state.dart';

void main() {
  group('centerZoneActionIcon', () {
    test('none stays empty', () {
      expect(centerZoneActionIcon(CircleSliderCenterAction.none), isNull);
    });

    test('toggleControls is iconless; the other set actions are not', () {
      // `toggleControls` is the legacy default of ALL four centre sectors, so a
      // glyph there only crowded the readout with four copies of the same hint.
      expect(centerZoneActionIcon(CircleSliderCenterAction.toggleControls),
          isNull);
      expect(centerZoneActionIcon(CircleSliderCenterAction.togglePlayPause),
          isNotNull);
      expect(centerZoneActionIcon(CircleSliderCenterAction.switchControlGroup),
          isNotNull);
    });

    test('switch group reuses the floating switch icon', () {
      expect(centerZoneActionIcon(CircleSliderCenterAction.switchControlGroup),
          Icons.swap_horiz_rounded);
    });
  });

  group('centerZoneIconOffset', () {
    test('top/bottom never mirror', () {
      expect(
        centerZoneIconOffset(
            zone: CenterZone.top, inwardOnLeft: true, radius: 10),
        const Offset(0, -10),
      );
      expect(
        centerZoneIconOffset(
            zone: CenterZone.top, inwardOnLeft: false, radius: 10),
        const Offset(0, -10),
      );
      expect(
        centerZoneIconOffset(
            zone: CenterZone.bottom, inwardOnLeft: true, radius: 10),
        const Offset(0, 10),
      );
    });

    test('inward/outward flip with the panel side', () {
      expect(
        centerZoneIconOffset(
            zone: CenterZone.inward, inwardOnLeft: true, radius: 10),
        const Offset(-10, 0),
      );
      expect(
        centerZoneIconOffset(
            zone: CenterZone.inward, inwardOnLeft: false, radius: 10),
        const Offset(10, 0),
      );
      expect(
        centerZoneIconOffset(
            zone: CenterZone.outward, inwardOnLeft: true, radius: 10),
        const Offset(10, 0),
      );
      expect(
        centerZoneIconOffset(
            zone: CenterZone.outward, inwardOnLeft: false, radius: 10),
        const Offset(-10, 0),
      );
    });
  });

  group('centerZoneIconOrbitRadius', () {
    test('sits midway between hole and edge', () {
      expect(
        centerZoneIconOrbitRadius(hitRadius: 40, gapRadius: 10),
        25,
      );
    });

    test('degenerate hit radius yields no orbit', () {
      expect(
        centerZoneIconOrbitRadius(hitRadius: 0, gapRadius: 0),
        0,
      );
    });
  });

  group('resolveCenterZoneActionMap', () {
    test('desktop legacy keeps all-toggleControls', () {
      final map = resolveCenterZoneActionMap(
        inward: CircleSliderCenterAction.switchControlGroup,
        outward: CircleSliderCenterAction.none,
        top: CircleSliderCenterAction.togglePlayPause,
        bottom: CircleSliderCenterAction.none,
        desktopPhoneMode: false,
        isMobileOverride: false,
      );
      expect(map.values.toSet(),
          {CircleSliderCenterAction.toggleControls});
    });

    test('phone honors the configured actions', () {
      final map = resolveCenterZoneActionMap(
        inward: CircleSliderCenterAction.switchControlGroup,
        outward: CircleSliderCenterAction.none,
        top: CircleSliderCenterAction.togglePlayPause,
        bottom: CircleSliderCenterAction.toggleControls,
        desktopPhoneMode: false,
        isMobileOverride: true,
      );
      expect(map[CenterZone.inward],
          CircleSliderCenterAction.switchControlGroup);
      expect(map[CenterZone.outward], CircleSliderCenterAction.none);
    });

    test('desktop phone mode honors the configured actions', () {
      final map = resolveCenterZoneActionMap(
        inward: CircleSliderCenterAction.switchControlGroup,
        outward: CircleSliderCenterAction.none,
        top: CircleSliderCenterAction.toggleControls,
        bottom: CircleSliderCenterAction.toggleControls,
        desktopPhoneMode: true,
        isMobileOverride: false,
      );
      expect(map[CenterZone.inward],
          CircleSliderCenterAction.switchControlGroup);
      expect(map[CenterZone.outward], CircleSliderCenterAction.none);
    });
  });

  group('CenterZoneSectorIcons widget', () {
    testWidgets('all-none renders no icons', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox.square(
              dimension: 200,
              child: Stack(
                children: [
                  CenterZoneSectorIcons(
                    center: Offset(100, 100),
                    orbitRadius: 30,
                    icons: {
                      CenterZone.inward: null,
                      CenterZone.outward: null,
                      CenterZone.top: null,
                      CenterZone.bottom: null,
                    },
                    inwardOnLeft: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(find.byType(Icon), findsNothing);
    });

    testWidgets('set sectors render with zone keys', (tester) async {
      await tester.pumpWidget(
        const MaterialApp(
          home: Scaffold(
            body: SizedBox.square(
              dimension: 200,
              child: Stack(
                children: [
                  CenterZoneSectorIcons(
                    center: Offset(100, 100),
                    orbitRadius: 30,
                    icons: {
                      CenterZone.inward: Icons.swap_horiz_rounded,
                      CenterZone.outward: null,
                      CenterZone.top: Icons.play_arrow_rounded,
                      CenterZone.bottom: null,
                    },
                    inwardOnLeft: true,
                  ),
                ],
              ),
            ),
          ),
        ),
      );
      expect(
          find.byKey(const ValueKey<String>('center-zone-icon-inward')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('center-zone-icon-top')),
          findsOneWidget);
      expect(find.byKey(const ValueKey<String>('center-zone-icon-outward')),
          findsNothing);
    });
  });
}
