import 'dart:convert';

import 'package:iris/features/meta_settings/engine/effects_registry.dart';
import 'package:iris/features/settings_transfer/audit/transfer_audit_entry.dart';
import 'package:iris/features/settings_transfer/audit/transfer_audit_store.dart';
import 'package:iris/features/settings_transfer/engine/app_settings_coder.dart';
import 'package:iris/features/settings_transfer/engine/platform_key_policy.dart';
import 'package:iris/features/settings_transfer/engine/transfer_catalog.dart';
import 'package:iris/features/settings_transfer/model/export_envelope.dart';
import 'package:iris/features/settings_transfer/model/import_resolution.dart';
import 'package:iris/features/settings_transfer/model/transfer_item_result.dart';
import 'package:iris/features/settings_transfer/model/transfer_report.dart';
import 'package:iris/features/settings_transfer/services/transfer_crypto.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/store/use_storage_store.dart';
import 'package:iris/store/use_play_queue_store.dart';

/// One built export: the file body plus the section keys whose encoder failed.
///
/// A failing coder returns an `error` payload (or throws) instead of taking the
/// whole export down, so the file always exists — but a `payload: []` section
/// reads exactly like an empty one, which is how a failed backup looked like a
/// successful one. [failedSections] is the signal the export dialog must show.
class ExportBuildResult {
  const ExportBuildResult({required this.json, this.failedSections = const []});

  final String json;

  /// Section keys whose encoder reported a swallowed failure.
  final List<String> failedSections;

  bool get isPartial => failedSections.isNotEmpty;
}

/// Section keys whose payload reports a swallowed encoder failure.
///
/// The coders catch their own DB errors and return `payload: []` plus an
/// `error` string (see `ScenarioCoder.encode`); that key is the only signal
/// left, because the payload shape is otherwise identical to an empty section.
List<String> failedExportSections(Map<String, dynamic> sections) => [
      for (final entry in sections.entries)
        if (entry.value is Map && (entry.value as Map)['error'] != null)
          entry.key,
    ];

class TransferService {
  // Build export for selected sections. If passphrase is non-empty and
  // networkStorages is among selected, the file will be encrypted.
  static Future<ExportBuildResult> buildExport({
    required Set<String> selectedSections,
    String? passphrase,
    String? passphraseKind, // numeric | custom
  }) async {
    final sections = <String, dynamic>{};
    for (final key in selectedSections) {
      final coder = TransferCatalog.coderFor(key);
      if (coder == null) continue;
      try {
        final payload = await coder.encode();
        if (payload != null) sections[key] = payload;
      } catch (e) {
        sections[key] = {'subVersion': 1, 'error': e.toString(), 'payload': []};
      }
    }
    // Detected HERE, before encryption: the caller has to know the file only
    // carries part of what was asked for.
    final failedSections = failedExportSections(sections);

    final envelope = await ExportEnvelope.create(sections);

    // Encryption: networkStorages must be encrypted if present (never plaintext).
    final hasNetwork = selectedSections.contains('networkStorages');
    final hasPassphrase = passphrase != null && passphrase.isNotEmpty;
    if (hasNetwork && !hasPassphrase) {
      throw Exception(
          'exporting network storages requires a passphrase (numeric or custom); refusing plaintext passwords');
    }
    if (hasNetwork && hasPassphrase) {
      final kind = passphraseKind ?? 'custom';
      final plainSectionsJson = jsonEncode(sections);
      final enc = await TransferCrypto.encrypt(
        plaintextJson: plainSectionsJson,
        passphrase: passphrase,
        kind: kind,
      );
      final encryptedEnvelope = ExportEnvelope(
        format: envelope.format,
        appVersion: envelope.appVersion,
        exportedAt: envelope.exportedAt,
        sections: {},
        enc: enc,
      );
      final jsonStr = const JsonEncoder.withIndent('  ').convert(encryptedEnvelope.toJson());
      return ExportBuildResult(json: jsonStr, failedSections: failedSections);
    }

    // Reaching here means the payload carries no network-storage passwords
    // (those require a passphrase and return through the encrypted branch above),
    // so a plain envelope is safe to write as-is.
    final jsonStr = envelope.encode(pretty: true);
    return ExportBuildResult(json: jsonStr, failedSections: failedSections);
  }

  // Import from raw file content. passphrase required if file is encrypted.
  static Future<TransferReport> importFromJson(
    String raw, {
    required Map<String, TransferResolution> resolutions,
    required bool skipErrors,
    String? passphrase,
  }) async {
    final Map<String, dynamic> json = jsonDecode(raw) as Map<String, dynamic>;

    // Legacy v1 compat: {format:1, app:{...}, storage:{...}}
    if (json['format'] == 1 && json.containsKey('app')) {
      return _importLegacyV1(json, resolutions: resolutions, skipErrors: skipErrors);
    }

    // Detect encryption
    Map<String, dynamic> sections;
    bool wasEncrypted = false;
    String? encKind;
    if (TransferCrypto.isEncryptedEnvelope(json)) {
      wasEncrypted = true;
      if (passphrase == null || passphrase.isEmpty) {
        return TransferReport(items: [
          TransferItemResult(section: 'enc', label: 'decrypt', ok: false, error: 'passphrase required'),
        ]);
      }
      final enc = (json['enc'] as Map).cast<String, dynamic>();
      encKind = enc['kind'] as String?;
      try {
        final plainJson = await TransferCrypto.decrypt(enc: enc, passphrase: passphrase);
        final decoded = jsonDecode(plainJson) as Map<String, dynamic>;
        sections = decoded.cast<String, dynamic>();
      } catch (e) {
        return TransferReport(items: [
          TransferItemResult(section: 'enc', label: 'decrypt', ok: false, error: 'wrong passphrase or corrupted file: $e'),
        ]);
      }
    } else {
      // Plain v2
      if (json['format'] != kTransferFormatVersion) {
        // Try to be tolerant: if no format, assume v2 sections
        sections = (json['sections'] as Map?)?.cast<String, dynamic>() ?? {};
        if (sections.isEmpty && json.containsKey('appSettings')) {
          sections = json;
        }
      } else {
        sections = (json['sections'] as Map?)?.cast<String, dynamic>() ?? {};
      }
    }

    // Ensure appSettings goes first (backend sync depends on it).
    // Cross-platform imports (desktop <-> mobile) keep common +
    // target-platform appSettings keys; the coder reports skipped items.
    final targetPlatform = currentTransferPlatformName;
    // appSettings first (backend sync depends on it), then tagPlay before the
    // rest. The old reason for that order is gone: a scenario tag source used to
    // re-resolve against the tags imported in the SAME run, and v49 retired that
    // source kind (scenario rows carry no tag identity any more). The order is
    // kept so an import stays deterministic and matches older builds; the rest
    // keep the file's own order.
    final orderedKeys = <String>[
      if (sections.containsKey('appSettings')) 'appSettings',
      if (sections.containsKey('tagPlay')) 'tagPlay',
      for (final k in sections.keys)
        if (k != 'appSettings' && k != 'tagPlay') k,
    ];
    // Also include requested resolutions that may not be in file (they'll be skipped)
    final allItems = <TransferItemResult>[];

    for (final key in orderedKeys) {
      final coder = TransferCatalog.coderFor(key);
      if (coder == null) {
        // A section this build does not know is reported and SKIPPED — never a
        // reason to abort the rest. A newer export can carry a section an older
        // app cannot read; breaking here silently dropped every later section
        // (and the message even said "ignored" while doing the opposite).
        allItems.add(TransferItemResult(section: key, label: key, ok: false, error: 'unknown section (ignored)'));
        continue;
      }
      final resolution = resolutions[key] ?? defaultResolutionFor(key);
      final payload = sections[key] as Map<String, dynamic>?;
      try {
        final items = coder is AppSettingsCoder
            ? await coder.importSection(payload,
                resolution: resolution, skipErrors: skipErrors, targetPlatform: targetPlatform)
            : await coder.importSection(payload, resolution: resolution, skipErrors: skipErrors);
        allItems.addAll(items);
        if (items.any((e) => !e.ok) && !skipErrors) {
          // stop further sections on first section failure when not skipping
          break;
        }
      } catch (e) {
        allItems.add(TransferItemResult(section: key, label: key, ok: false, error: e.toString()));
        if (!skipErrors) break;
      }
    }

    // Backend sync after appSettings
    try {
      final appState = useAppStore().state;
      EffectsRegistry.ensureRegistered();
      await EffectsRegistry.run(EffectsRegistry.legacyStorageBackend, appState);
      // Switch unified stores
      try {
        await useStorageStore().switchBackend(appState.useLegacyStoragePersistence);
      } catch (_) {}
      try {
        await usePlayQueueStore().switchBackend(appState.useLegacyStoragePersistence);
      } catch (_) {}
    } catch (_) {}

    // Audit import
    final importedSections = orderedKeys;
    final hasNetwork = importedSections.contains('networkStorages');
    if (hasNetwork) {
      await _auditImport(importedSections, encrypted: wasEncrypted, passphraseKind: encKind, results: allItems);
    }

    return TransferReport(items: allItems, skippedErrors: skipErrors);
  }

  static Future<TransferReport> _importLegacyV1(
    Map<String, dynamic> json, {
    required Map<String, TransferResolution> resolutions,
    required bool skipErrors,
  }) async {
    final items = <TransferItemResult>[];
    final appRes = resolutions['appSettings'] ?? TransferResolution.overwrite;
    final storageRes = resolutions['networkStorages'] ?? TransferResolution.append;

    if (json['app'] != null && appRes != TransferResolution.skip) {
      try {
        final appJson = (json['app'] as Map).cast<String, dynamic>();
        // Use appSettings coder path: wrap as v2 payload. Legacy files carry
        // no platform stamp, so opposite-platform keys are filtered against
        // this device just like v2 cross-platform imports.
        final coder = TransferCatalog.coderFor('appSettings')! as AppSettingsCoder;
        final payload = {'subVersion': 1, 'snapshot': appJson, 'rows': []};
        final res = await coder.importSection(payload,
            resolution: appRes, skipErrors: skipErrors, targetPlatform: currentTransferPlatformName);
        items.addAll(res);
      } catch (e) {
        items.add(TransferItemResult(section: 'appSettings', label: 'legacy app', ok: false, error: e.toString()));
        if (!skipErrors) return TransferReport(items: items);
      }
    }

    if (json['storage'] != null && storageRes != TransferResolution.skip) {
      try {
        final storageJson = (json['storage'] as Map).cast<String, dynamic>();
        // Legacy storage contains all storages; we map to networkStorages + favorites.
        // For now, handle network storages:
        final coder = TransferCatalog.coderFor('networkStorages')!;
        // Convert StorageState storages to list
        final storages = (storageJson['storages'] as List?) ?? [];
        final payload = {'subVersion': 1, 'payload': storages};
        final res = await coder.importSection(payload, resolution: storageRes, skipErrors: skipErrors);
        items.addAll(res);
        // Also favorites
        final favCoder = TransferCatalog.coderFor('favorites')!;
        final favs = storageJson['favorites'];
        if (favs != null) {
          final favPayload = {'subVersion': 1, 'payload': favs};
          final favRes = await favCoder.importSection(favPayload, resolution: storageRes, skipErrors: skipErrors);
          items.addAll(favRes);
        }
      } catch (e) {
        items.add(TransferItemResult(section: 'networkStorages', label: 'legacy storage', ok: false, error: e.toString()));
      }
    }

    // backend sync
    try {
      final appState = useAppStore().state;
      EffectsRegistry.ensureRegistered();
      await EffectsRegistry.run(EffectsRegistry.legacyStorageBackend, appState);
      await useStorageStore().switchBackend(appState.useLegacyStoragePersistence);
      await usePlayQueueStore().switchBackend(appState.useLegacyStoragePersistence);
    } catch (_) {}

    return TransferReport(items: items, skippedErrors: skipErrors);
  }

  /// Records one SUCCESSFUL export in the transfer audit log.
  ///
  /// Called by the export surface only AFTER the file has actually been written:
  /// the entry says "ok", so writing it inside [buildExport] (before the
  /// partial-export confirmation, or before the save) left a success record for
  /// an export the user then declined — an audit trail that claimed a backup
  /// that never landed.
  static Future<void> auditExport({
    required Set<String> sections,
    required bool encrypted,
    String? passphraseKind,
  }) async {
    try {
      final store = useTransferAuditStore();
      await store.load();
      final entry = TransferAuditEntry(
        at: DateTime.now(),
        op: TransferAuditOp.export,
        sections: sections.toList(),
        encrypted: encrypted,
        passphraseKind: passphraseKind,
        storageCount: null,
        result: 'ok',
      );
      await store.append(entry);
    } catch (_) {}
  }

  static Future<void> _auditImport(List<String> sections, {required bool encrypted, String? passphraseKind, required List<TransferItemResult> results}) async {
    try {
      final store = useTransferAuditStore();
      await store.load();
      final ok = results.where((e) => e.ok).length;
      final fail = results.where((e) => !e.ok).length;
      final result = fail == 0 ? 'ok' : (ok > 0 ? 'partial' : 'failed');
      final entry = TransferAuditEntry(
        at: DateTime.now(),
        op: TransferAuditOp.import,
        sections: sections,
        encrypted: encrypted,
        passphraseKind: passphraseKind,
        result: result,
        note: 'ok:$ok fail:$fail',
      );
      await store.append(entry);
    } catch (_) {}
  }
}
