import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/virtual_media/playback/vm_playback_controller.dart';
import 'package:iris/features/virtual_media/store/vm_playback_store.dart';
import 'package:iris/utils/get_localizations.dart';

/// Renders nothing; watches the Virtual Merge playback store's
/// [VmPlaybackState.lastError] and surfaces a fatal session error as a Dialog
/// (never a SnackBar, per the project feedback policy).
///
/// The error string is already localized when it is written to the store
/// (see `vmLocalizations()`), so this host stays presentation-only. Mounted on
/// the player surface, which is alive for the whole VM session; acknowledging
/// clears the stored error so a later session starts clean.
///
/// Stack contract: EVERY build path returns a [Positioned] (mirroring
/// `FrameToolsFloatPanel` / `BgQuickPanelHost`). The player Stack is otherwise
/// all-positioned and only sizes via `constraints.biggest`; a bare
/// non-positioned box here collapses the whole player subtree to `Size.zero`
/// and renders a black screen while audio/input keep working.
/// The dialog itself is pushed on the root Overlay via `showDialog`, so the
/// shrink placeholder never needs to occupy layout space.
class VmErrorDialogHost extends HookWidget {
  const VmErrorDialogHost({super.key});

  @override
  Widget build(BuildContext context) {
    final error = useVmPlaybackStore().select(context, (s) => s.lastError);
    final shown = useRef<String?>(null);
    useEffect(() {
      if (error == null || shown.value == error) return null;
      shown.value = error;
      // Defer to after the frame so the dialog is pushed from a stable build.
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!context.mounted) {
          shown.value = null;
          return;
        }
        final t = getLocalizations(context);
        showDialog<void>(
          context: context,
          builder: (dialogContext) => AlertDialog(
            icon: const Icon(Icons.error_outline, color: Colors.red),
            title: Text(t.vm_error_title),
            content: Text(error),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(dialogContext).pop(),
                child: Text(t.dlg_storage_info_got_it),
              ),
            ],
          ),
        ).whenComplete(() {
          VirtualMediaController.instance.acknowledgeError();
          shown.value = null;
        });
      });
      return null;
    }, [error]);
    return const Positioned(left: 0, top: 0, child: SizedBox.shrink());
  }
}
