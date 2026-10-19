import 'package:flutter/material.dart';
import 'package:iris/features/control_group/domain/center_zone_icons.dart';
import 'package:iris/models/store/app_state.dart';

/// Sector icons for the faint 45° X center of the ring dial / classic circle.
///
/// One small icon per configured sector ([centerZoneActionIcon]); `none`
/// sectors stay empty. Pure hint layer: never intercepts pointers and stays
/// out of semantics.
class CenterZoneSectorIcons extends StatelessWidget {
  const CenterZoneSectorIcons({
    super.key,
    required this.center,
    required this.orbitRadius,
    required this.icons,
    required this.inwardOnLeft,
    this.iconSize = 14.0,
  });

  /// Hit-circle center in the hosting Stack's coordinate space.
  final Offset center;

  /// Distance from [center] to each icon, from [centerZoneIconOrbitRadius].
  final double orbitRadius;

  /// Logical-zone icon per sector; null means "leave empty".
  final Map<CenterZone, IconData?> icons;

  /// Folds logical inward/outward onto screen left/right.
  final bool inwardOnLeft;

  final double iconSize;

  @override
  Widget build(BuildContext context) {
    if (orbitRadius <= 0) return const SizedBox.shrink();
    final List<Widget> placed = <Widget>[];
    for (final CenterZone zone in CenterZone.values) {
      final IconData? icon = icons[zone];
      if (icon == null) continue;
      final Offset off = centerZoneIconOffset(
        zone: zone,
        inwardOnLeft: inwardOnLeft,
        radius: orbitRadius,
      );
      placed.add(
        Positioned(
          key: ValueKey<String>('center-zone-icon-${zone.name}'),
          left: center.dx + off.dx - iconSize / 2,
          top: center.dy + off.dy - iconSize / 2,
          width: iconSize,
          height: iconSize,
          child: Icon(
            icon,
            size: iconSize,
            color: Colors.white.withValues(alpha: 0.55),
            shadows: const <Shadow>[
              Shadow(blurRadius: 3, color: Colors.black54),
            ],
          ),
        ),
      );
    }
    if (placed.isEmpty) return const SizedBox.shrink();
    // Positioned.fill so the pixel offsets above are in the host square's
    // space no matter which Stack this lands in.
    return Positioned.fill(
      child: IgnorePointer(
        child: ExcludeSemantics(
          child: Stack(children: placed),
        ),
      ),
    );
  }
}
