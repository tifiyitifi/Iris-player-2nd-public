import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/model/enum/bg_quick_panel.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';
import 'package:iris/features/background_playback/view/background_scope_dialog.dart';
import 'package:iris/features/background_playback/view/bg_alignment_panel.dart';
import 'package:iris/features/background_playback/view/media_ratio_dialog.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/floating/draggable_floating_card.dart';

/// Hosts the quick 副音 floating cards inside the player Stack.
///
/// Non-modal by design: no `ModalBarrier`, so the video is never dimmed and
/// playback/gestures stay live while a card is open. Cards are draggable and
/// default to a thumb-reachable bottom position on phones.
///
/// The A-B align editor is NOT one of these cards anymore — it replaces the
/// control bar itself (see `SegmentAlignEditPanel`). The 进度锁定 card is gone
/// too: the lock was split into two quick-bar buttons.
///
/// Contract (mirroring [FrameToolsFloatPanel]): EVERY build path returns a
/// [Positioned] — the player Stack only sizes via `constraints.biggest` while
/// it stays all-positioned.
class BgQuickPanelHost extends HookWidget {
  const BgQuickPanelHost({super.key});

  // Base card sizes; clamped to the host on small screens. The scope card is
  // the tallest of the set — it carries the scope, its persistence switch and
  // the two Virtual Media rules — so it is sized to fit them without scrolling
  // on a desktop window.
  static const Size _scopeSize = Size(320, 470);
  static const Size _ratioSize = Size(320, 460);
  // The shared alignment editor (更新 + 默认 + threshold + exhausted) is tall;
  // the card scrolls, but a taller default keeps most of it on screen.
  static const Size _alignSize = Size(320, 520);

  @override
  Widget build(BuildContext context) {
    final bg = useBackgroundPlaybackStore();
    final panel = bg.select(context, (s) => s.openQuickPanel);
    final enabled = bg.select(context, (s) => s.enabled);
    final mediaSize = MediaQuery.sizeOf(context);
    final frac = useState<Offset?>(null);
    final host = useState<Size?>(null);

    // The feature gate arrives through its OWN subscription, never off
    // `useAppStore().state`: this host is mounted `const` in the player Stack,
    // and `updateChild` short-circuits on an identical const instance, so an
    // ancestor rebuild (e.g. `Player` re-rendering after the legacy-storage
    // switch) never re-runs this build. A bare `BackgroundPlaybackGate.enabled`
    // therefore left a 副音 card on screen — still draggable and interactive —
    // after the subsystem was switched off, and nothing else clears
    // `openQuickPanel`: `EffectsRegistry.legacyStorageBackend` only swaps the
    // storage / play-queue backends. Same shape as the other gate readers
    // (player.dart, more_menu_button.dart, tag_play_controller.dart).
    final bool gateEnabled = useAppStore().select(
      context,
      (AppState s) => !s.useLegacyStoragePersistence && s.useMetadataSettings,
    );

    final bool visible =
        gateEnabled && enabled && panel != BgQuickPanel.none;

    // Measure the hosting Stack (the card must clamp to the VIDEO area, not the
    // raw screen — the playlist dock can shrink it). Re-runs on panel/size
    // changes so an already-placed card stays inside the new bounds.
    useEffect(() {
      if (!visible) return null;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) return;
        final box = context.findRenderObject();
        if (box is! RenderBox || !box.hasSize) return;
        RenderBox? node =
            box.parent is RenderBox ? box.parent as RenderBox : null;
        while (node != null && node is! RenderStack) {
          node = node.parent is RenderBox ? node.parent as RenderBox : null;
        }
        final size = node?.size ?? MediaQuery.sizeOf(context);
        if (host.value != size) host.value = size;
      });
      return null;
    }, [visible, panel, mediaSize]);

    if (!visible) {
      return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
    }

    final t = getLocalizations(context);
    final hostSize = host.value ?? mediaSize;
    final cardSize = _sizeFor(panel, hostSize);
    final availW =
        (hostSize.width - cardSize.width).clamp(0.0, double.infinity);
    final availH =
        (hostSize.height - cardSize.height).clamp(0.0, double.infinity);
    // Default: bottom-center on phones (one-handed reach), center on desktop.
    final f = frac.value ?? Offset(0.5, isMobilePlatform ? 0.72 : 0.5);
    final left = availW * f.dx.clamp(0.0, 1.0);
    final top = availH * f.dy.clamp(0.0, 1.0);

    void onDragDelta(Offset delta) {
      frac.value = Offset(
        (f.dx + (availW <= 0 ? 0 : delta.dx / availW)).clamp(0.0, 1.0),
        (f.dy + (availH <= 0 ? 0 : delta.dy / availH)).clamp(0.0, 1.0),
      );
    }

    return Positioned(
      key: const ValueKey('bg_quick_panel'),
      left: left,
      top: top,
      child: DraggableFloatingCard(
        title: _title(panel, t),
        onClose: bg.closeQuickPanel,
        onDragDelta: onDragDelta,
        width: cardSize.width,
        height: cardSize.height,
        child: _content(panel),
      ),
    );
  }

  static Size _sizeFor(BgQuickPanel panel, Size host) {
    final base = switch (panel) {
      BgQuickPanel.ratio => _ratioSize,
      BgQuickPanel.align => _alignSize,
      _ => _scopeSize,
    };
    return Size(
      base.width.clamp(0.0, (host.width - 16).clamp(0.0, double.infinity)),
      base.height.clamp(0.0, (host.height - 16).clamp(0.0, double.infinity)),
    );
  }

  static String _title(BgQuickPanel panel, AppLocalizations t) =>
      switch (panel) {
        BgQuickPanel.ratio => t.bg_volume_ratio,
        BgQuickPanel.align => t.bg_align_button,
        _ => t.bg_scope_button,
      };

  static Widget _content(BgQuickPanel panel) => switch (panel) {
        BgQuickPanel.ratio => const MediaRatioPanelContent(),
        BgQuickPanel.align => const BgAlignmentPanelContent(),
        _ => const BackgroundScopePanelContent(),
      };
}
