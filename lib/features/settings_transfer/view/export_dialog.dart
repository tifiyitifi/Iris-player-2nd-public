import 'package:flutter/material.dart';
import 'package:iris/features/settings_transfer/engine/platform_key_policy.dart';
import 'package:iris/features/settings_transfer/engine/transfer_catalog.dart';
import 'package:iris/features/settings_transfer/model/transfer_exclusion.dart';
import 'package:iris/features/settings_transfer/model/transfer_section.dart';
import 'package:iris/features/settings_transfer/services/transfer_file_service.dart';
import 'package:iris/features/settings_transfer/services/transfer_service.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/dialogs/show_message_dialog.dart';

/// Asks whether to keep exporting when some selected sections failed.
///
/// Returns true when the user accepts a partial file, false to abort. Takes a
/// [NavigatorState] (captured before the awaits) so it survives the export
/// sheet being popped, matching the flow's other dialogs.
Future<bool> _confirmPartialExport(
  NavigatorState navigator,
  List<String> failedSections,
) async {
  if (!navigator.mounted) return false;
  final ok = await showDialog<bool>(
    context: navigator.context,
    builder: (ctx) {
      final t = getLocalizations(ctx);
      return AlertDialog(
        title: Text(t.transfer_export_partial_title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(t.transfer_export_partial_body),
            const SizedBox(height: 8),
            // One line per section, each already localized: no sentence is
            // assembled from fragments.
            for (final key in failedSections)
              Text('- ${TransferSectionX.fromKey(key)?.label(t) ?? key}'),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(t.transfer_export_partial_continue),
          ),
        ],
      );
    },
  );
  return ok ?? false;
}

Future<void> showTransferExportDialog(BuildContext context) async {
  final selected = <String>{for (final k in TransferCatalog.allKeys) k};
  // Encryption: only when networkStorages selected
  String passphrase = '';
  String passphraseKind = 'custom'; // numeric | custom
  bool obscurePass = true;

  final navigator = Navigator.of(context, rootNavigator: true);

  await showDialog(
    context: context,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (_, setState) {
          final t = getLocalizations(ctx);
          final hasNetwork = selected.contains('networkStorages');
          final needsPassphrase = hasNetwork;

          return AlertDialog(
            title: Text(t.export_options),
            content: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    t.transfer_export_intro(transferPlatformDisplayName(
                        currentTransferPlatformName, t)),
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                  const SizedBox(height: 8),
                  for (final key in TransferCatalog.allKeys)
                    CheckboxListTile(
                      value: selected.contains(key),
                      title: Text(
                          TransferSectionX.fromKey(key)?.label(t) ?? key),
                      subtitle: Text(
                          TransferSectionX.fromKey(key)?.description(t) ??
                              ''),
                      onChanged: (v) => setState(() {
                        if (v == true) {
                          selected.add(key);
                        } else {
                          selected.remove(key);
                        }
                      }),
                    ),
                  const Divider(),
                  for (final ex in kTransferExclusions)
                    ListTile(
                      enabled: false,
                      title: Text(
                          '${ex.label(t)}${t.transfer_sec_unsupported_suffix}'),
                      subtitle: Text(ex.reason(t),
                          style: const TextStyle(fontSize: 12)),
                    ),
                  if (needsPassphrase) ...[
                    const Divider(),
                    Text(t.transfer_export_pass_note,
                        style: const TextStyle(fontWeight: FontWeight.bold)),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        ChoiceChip(
                          label: Text(t.transfer_export_pass_numeric),
                          selected: passphraseKind == 'numeric',
                          onSelected: (_) => setState(() => passphraseKind = 'numeric'),
                        ),
                        const SizedBox(width: 8),
                        ChoiceChip(
                          label: Text(t.transfer_export_pass_custom),
                          selected: passphraseKind == 'custom',
                          onSelected: (_) => setState(() => passphraseKind = 'custom'),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    TextFormField(
                      decoration: InputDecoration(
                        border: const OutlineInputBorder(),
                        labelText: t.transfer_export_pass_label,
                        hintText: passphraseKind == 'numeric'
                            ? t.transfer_export_pass_numeric_hint
                            : t.transfer_export_pass_custom_hint,
                        suffixIcon: IconButton(
                          icon: Icon(obscurePass ? Icons.visibility_off : Icons.visibility),
                          onPressed: () => setState(() => obscurePass = !obscurePass),
                        ),
                      ),
                      obscureText: obscurePass,
                      enableInteractiveSelection: true,
                      autocorrect: false,
                      enableSuggestions: false,
                      onChanged: (v) => passphrase = v.trim(),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      passphraseKind == 'numeric'
                          ? t.transfer_export_pass_numeric_rule
                          : t.transfer_export_pass_short_rule,
                      style: Theme.of(ctx).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
            ),
            actions: [
              TextButton(onPressed: () => Navigator.pop(ctx), child: Text(t.cancel)),
              ElevatedButton(
                child: Text(t.export_label),
                onPressed: () async {
                  if (selected.isEmpty) {
                    await showMessageDialog(navigator, message: t.export_nothing_selected, type: MessageDialogType.error);
                    return;
                  }
                  if (needsPassphrase) {
                    if (passphrase.isEmpty) {
                      await showMessageDialog(navigator, message: t.transfer_export_pass_empty, type: MessageDialogType.error);
                      return;
                    }
                    if (passphraseKind == 'numeric' && !RegExp(r'^\d{4,}$').hasMatch(passphrase)) {
                      await showMessageDialog(navigator, message: t.transfer_export_pass_numeric_bad, type: MessageDialogType.error);
                      return;
                    }
                    if (passphrase.length < 4) {
                      await showMessageDialog(navigator, message: t.transfer_export_pass_too_short, type: MessageDialogType.error);
                      return;
                    }
                  }

                  // capture before pop
                  final sel = Set<String>.from(selected);
                  final pass = passphrase;
                  final kind = passphraseKind;
                  final hasNet = sel.contains('networkStorages');

                  Navigator.pop(ctx);

                  try {
                    final result = await TransferService.buildExport(
                      selectedSections: sel,
                      passphrase: hasNet ? pass : null,
                      passphraseKind: hasNet ? kind : null,
                    );
                    // A section whose encoder failed is written as `payload: []`,
                    // indistinguishable from an empty one: without this the file
                    // reads as a complete backup while restoring nothing for that
                    // section. Let the user choose whether a partial file is
                    // still worth keeping.
                    if (result.isPartial) {
                      final proceed = await _confirmPartialExport(
                          navigator, result.failedSections);
                      if (!proceed) return;
                    }
                    final fileName = await getDefaultTransferFileName(encrypted: hasNet && pass.isNotEmpty);
                    await saveTransferFile(result.json, fileName);
                    // The audit records a SUCCESSFUL export, so it is written
                    // here — after the file landed and after the partial-export
                    // choice above. Recording it in `buildExport` left an "ok"
                    // entry behind when the user declined the partial file.
                    if (hasNet) {
                      await TransferService.auditExport(
                        sections: sel,
                        encrypted: true,
                        passphraseKind: kind,
                      );
                    }
                    await showMessageDialog(navigator, message: t.export_success, type: MessageDialogType.success);
                  } catch (e) {
                    await showMessageDialog(navigator, message: '${t.export_failed}: $e', type: MessageDialogType.error);
                  }
                },
              ),
            ],
          );
        },
      );
    },
  );
}
