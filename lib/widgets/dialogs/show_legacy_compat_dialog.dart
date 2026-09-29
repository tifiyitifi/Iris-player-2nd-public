import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';

/// One consolidated legacy-compatibility dialog (requirement #5): every toggle that
/// concerns the legacy persistence/runtime path lives here instead of being
/// scattered across General/Advanced. The master gate sits FIRST — it is the
/// on/off switch of the whole legacy compatibility story; `syncLegacyBlob`
/// only means something while the gate is ON and is greyed out otherwise.
///
/// Toggles apply live through the SAME store updaters the old standalone
/// rows used — persistence behavior is byte-identical, only the entries are
/// consolidated.
Future<void> showLegacyCompatDialog(BuildContext context) {
  return showDialog<void>(
    context: context,
    builder: (context) => const LegacyCompatDialog(),
  );
}

class LegacyCompatDialog extends HookWidget {
  const LegacyCompatDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final store = useAppStore();
    final t = getLocalizations(context);
    // The five switches this dialog renders. A whole-state read re-ran it on
    // every AppState mutation (`Store.set` emits unconditionally; Freezed's
    // `==` is a deep compare), including the per-frame gesture writes behind
    // the modal it sits on.
    final ({
      bool gate,
      bool syncLegacyBlob,
      bool classicTitleBar,
      bool legacyControlBar,
      bool legacyStorage,
    }) s = store.select(
      context,
      (AppState state) => (
        gate: state.useMetadataSettings,
        syncLegacyBlob: state.syncLegacyBlob,
        classicTitleBar: state.useClassicTitleBar,
        legacyControlBar: state.useLegacyControlBar,
        legacyStorage: state.useLegacyStoragePersistence,
      ),
    );

    return AlertDialog(
      title: Text(t.legacy_title),
      content: SizedBox(
        width: 360,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
            Container(
              width: double.infinity,
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Theme.of(context)
                    .colorScheme
                    .errorContainer
                    .withValues(alpha: 0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Icon(
                    Icons.warning_rounded,
                    size: 18,
                    color: Theme.of(context).colorScheme.onErrorContainer,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      t.set_legacy_compat_warn,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onErrorContainer,
                          ),
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            SwitchListTile(
              key: const ValueKey<String>('legacy-gate-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.legacy_gate_title),
              subtitle: Text(t.legacy_gate_desc),
              value: s.gate,
              onChanged: (_) => store.toggleUseMetadataSettings(),
            ),
            SwitchListTile(
              key: const ValueKey<String>('legacy-sync-blob-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.legacy_sync_title),
              subtitle: Text(t.legacy_sync_desc),
              value: s.syncLegacyBlob,
              // Without the master gate the blob is authoritative and the
              // dual-write knob is meaningless — never interactable.
              onChanged: s.gate
                  ? (_) => store.toggleSyncLegacyBlob()
                  : null,
            ),
            const Divider(),
            SwitchListTile(
              key: const ValueKey<String>('legacy-title-bar-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.legacy_title_bar),
              value: s.classicTitleBar,
              onChanged: (_) => store.toggleUseClassicTitleBar(),
            ),
            SwitchListTile(
              key: const ValueKey<String>('legacy-control-bar-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.legacy_control_bar),
              value: s.legacyControlBar,
              onChanged: (_) => store.toggleUseLegacyControlBar(),
            ),
            SwitchListTile(
              key: const ValueKey<String>('legacy-storage-switch'),
              contentPadding: EdgeInsets.zero,
              title: Text(t.legacy_storage),
              value: s.legacyStorage,
              onChanged: (_) => store.toggleUseLegacyStoragePersistence(),
            ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          key: const ValueKey<String>('legacy-compat-close'),
          onPressed: () => Navigator.pop(context),
          child: Text(t.legacy_close),
        ),
      ],
    );
  }
}
