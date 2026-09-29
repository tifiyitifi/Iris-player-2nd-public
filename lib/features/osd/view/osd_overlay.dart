import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/meta_settings/engine/osd_resolver.dart';
import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/osd/model/osd_entry.dart';
import 'package:iris/features/osd/store/osd_store.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_player_ui_store.dart';
import 'package:iris/utils/platform.dart' show isDesktop;

/// PotPlayer-style keyboard OSD — right/bottom-traditional pill but now
/// default left/top (9-grid) + single/two-line + icon+progress, strictly
/// desktop-only and metadata-gated (legacy mode = no OSD).
///
/// Mount point: [Player] Stack as `Positioned.fill` alongside the existing
/// `KeySequenceOverlay`/`AbLoopOverlay`. Uses the same `ExcludeSemantics` +
/// `IgnorePointer` contract as those chips (Windows AXTree mitigation).
class OsdOverlay extends HookWidget {
  const OsdOverlay({super.key});

  @override
  Widget build(BuildContext context) {
    if (!isDesktop) return const SizedBox.shrink();

    final OsdEntry? entry = useOsdStore().select(context, (s) => s);
    if (entry == null) return const SizedBox.shrink();

    // FIELD-scoped, like the player overlays: a whole-state read re-ran this
    // pill on every AppState mutation — `Store.set` emits unconditionally and
    // Freezed's `==` is a deep compare — for six fields it renders.
    final ({
      bool gate,
      bool enabled,
      OsdVisibilityMode visibilityMode,
      OsdHAlign hAlign,
      OsdVAlign vAlign,
      OsdLayout layout,
    }) osd = useAppStore().select(
      context,
      (AppState s) => (
        gate: s.useMetadataSettings,
        enabled: s.osdEnabled,
        visibilityMode: s.osdVisibilityMode,
        hAlign: s.osdHAlign,
        vAlign: s.osdVAlign,
        layout: s.osdLayout,
      ),
    );
    final bool isShowControl =
        usePlayerUiStore().select(context, (s) => s.isShowControl);

    // Gate + visibility mode — mirrors `DefVisibility('osd.')` contract but
    // per-toast so toggling the setting mid-toast hides immediately.
    final bool osdGate = osd.gate && MetaSettingsModule.ready;
    if (!resolveOsdShouldShowFrom(
      osdEnabled: osd.enabled,
      visibilityMode: osd.visibilityMode,
      metadataEnabled: osdGate,
      isShowControl: isShowControl,
    )) {
      return const SizedBox.shrink();
    }

    final alignment = resolveOsdAlignment(osd.hAlign, osd.vAlign);
    final isTwoLines = osd.layout == OsdLayout.twoLines;

    // 9-grid inset: left/top mirror PotPlayer default (24/48), right/bottom
    // clear the sequence chip (48) and the bottom control bar.
    final EdgeInsets padding = EdgeInsets.only(
      left: osd.hAlign == OsdHAlign.left ? 24 : 0,
      right: osd.hAlign == OsdHAlign.right ? 24 : 0,
      top: osd.vAlign == OsdVAlign.top ? 48 : 0,
      bottom: osd.vAlign == OsdVAlign.bottom ? 140 : 0,
    );

    // No Positioned here — the mount point in Player already wraps this
    // widget in Positioned.fill (same contract as KeySequenceOverlay /
    // AbLoopOverlay). A second Positioned would double-write StackParentData
    // and assert "Incorrect use of ParentDataWidget" (see windows_play log).
    return IgnorePointer(
      child: ExcludeSemantics(
        child: Align(
          alignment: alignment,
          child: Padding(
            padding: padding,
            child: _OsdPill(entry: entry, twoLines: isTwoLines),
          ),
        ),
      ),
    );
  }
}

class _OsdPill extends StatelessWidget {
  const _OsdPill({required this.entry, required this.twoLines});

  final OsdEntry entry;
  final bool twoLines;

  /// Transparent, text-only OSD: the label never blocks the picture. A soft
  /// drop shadow keeps the white text legible over any video content.
  static const _shadow = Shadow(
    color: Colors.black,
    offset: Offset(0, 1),
    blurRadius: 3,
  );

  @override
  Widget build(BuildContext context) {
    final String line1 = entry.line1;
    final String? line2 = entry.line2;
    final bool hasLine2 = line2 != null && line2.isNotEmpty;

    final TextStyle small = TextStyle(
      color: Colors.white.withValues(alpha: 0.9),
      fontSize: 12,
      fontWeight: FontWeight.w500,
      shadows: const [_shadow],
    );
    final TextStyle large = const TextStyle(
      color: Colors.white,
      fontSize: 16,
      fontWeight: FontWeight.w600,
      fontFeatures: [FontFeature.tabularFigures()],
      shadows: [_shadow],
    );

    if (!twoLines) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(line1, style: large),
          if (hasLine2) ...[
            const SizedBox(width: 8),
            Text(line2!, style: large),
          ],
        ],
      );
    }
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(line1, style: small),
        if (hasLine2) ...[
          const SizedBox(height: 2),
          Text(line2!, style: large),
        ],
      ],
    );
  }
}
