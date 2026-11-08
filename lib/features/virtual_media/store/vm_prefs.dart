import 'package:iris/features/meta_settings/meta_settings_module.dart';
import 'package:iris/features/virtual_media/rule/vm_naming.dart'
    show
        VmNamingStrategy,
        normalizeVmNumberFormat,
        normalizeVmPrefix,
        parseVmNamingStrategy;
import 'package:iris/features/virtual_media/vm_gate.dart';

/// AUX-row backed preferences for the Virtual Media feature.
///
/// `virtualmedia.*` rows live OUTSIDE the `app.%` wipe scope (same contract
/// as `tagplay.*`), so they survive settings snapshots. Gate-OFF runs
/// degrade to the code defaults — consistent with the feature being absent —
/// and writes are dropped: [VirtualMediaGate.enabled] guards every read and
/// write below, not just [MetaSettingsModule.ready].
abstract final class VmPrefs {
  static const _prefix = 'virtualmedia.';
  static const _pathInputKey = '${_prefix}pathViaInput';
  static const _masterEnabledKey = '${_prefix}masterEnabled';

  static bool get _available =>
      VirtualMediaGate.enabled && MetaSettingsModule.ready;

  /// Global merge master switch. Missing row = ON (fresh installs and older
  /// builds keep merging until the user explicitly pauses it); `'0'` = OFF.
  ///
  /// Individual rules keep their own `enabled` bits — pausing the master
  /// switch only suspends resolution, never mutates the rules.
  static Future<bool> masterEnabled() async {
    if (!_available) return true;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return rows[_masterEnabledKey] != '0';
    } catch (_) {
      return true;
    }
  }

  static Future<void> setMasterEnabled(bool value) async {
    if (!_available) return;
    try {
      await MetaSettingsModule.persistAuxRow(
          _masterEnabledKey, value ? '1' : '0');
    } catch (_) {}
  }

  /// Editor toggle: add specified-directory paths by pasting text (true)
  /// instead of opening the system picker (false). Persisted across
  /// sessions per product decision.
  static Future<bool> pathViaInput() async {
    if (!_available) return false;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return rows[_pathInputKey] == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> setPathViaInput(bool value) async {
    if (!_available) return;
    try {
      await MetaSettingsModule.persistAuxRow(_pathInputKey, value ? '1' : '0');
    } catch (_) {}
  }

  /// Long-lived hidden state of an info banner ([id] is banner-local).
  static Future<bool> bannerHidden(String id) async {
    if (!_available) return false;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return rows['${_prefix}banner.$id'] == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> setBannerHidden(String id, bool hidden) async {
    if (!_available) return;
    try {
      await MetaSettingsModule.persistAuxRow(
          '${_prefix}banner.$id', hidden ? '1' : '0');
    } catch (_) {}
  }

  /// One-shot "non-playback operations on virtual merged media are not
  /// supported" hint, shown when the user enters multi-select in scenario
  /// search. Persisted (row = '1' means suppressed) so "不再提示" is permanent;
  /// the settings row re-enables it.
  static const _multiSelectHintHiddenKey =
      '${_prefix}multiSelectHintHidden';

  static Future<bool> multiSelectHintHidden() async {
    if (!_available) return false;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return rows[_multiSelectHintHiddenKey] == '1';
    } catch (_) {
      return false;
    }
  }

  static Future<void> setMultiSelectHintHidden(bool hidden) async {
    if (!_available) return;
    try {
      await MetaSettingsModule.persistAuxRow(
          _multiSelectHintHiddenKey, hidden ? '1' : '0');
    } catch (_) {}
  }

  static const _namingStrategyKey = '${_prefix}namingStrategy';
  static const _namePrefixKey = '${_prefix}namePrefix';
  static const _nameNumberFormatKey = '${_prefix}nameNumberFormat';
  static const _nameCounterKey = '${_prefix}nameCounter';

  /// Auto-name numeric strategy; gate-OFF degrades to `maxPlusOne`.
  static Future<VmNamingStrategy> namingStrategy() async {
    if (!_available) return VmNamingStrategy.maxPlusOne;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return parseVmNamingStrategy(rows[_namingStrategyKey]);
    } catch (_) {
      return VmNamingStrategy.maxPlusOne;
    }
  }

  static Future<void> setNamingStrategy(VmNamingStrategy value) async {
    if (!_available) return;
    await MetaSettingsModule.persistAuxRow(_namingStrategyKey, value.name);
  }

  /// Auto-name prefix; blank/empty rows degrade to `rule` (never empty —
  /// the editor dialog also rejects empty input).
  static Future<String> namePrefix() async {
    if (!_available) return 'rule';
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return normalizeVmPrefix(rows[_namePrefixKey]);
    } catch (_) {
      return 'rule';
    }
  }

  static Future<void> setNamePrefix(String value) async {
    if (!_available) return;
    await MetaSettingsModule.persistAuxRow(
        _namePrefixKey, normalizeVmPrefix(value));
  }

  /// Suffix number format (`raw`/`pad2`/`pad3`/`pad4`); unknown degrades
  /// to `raw`.
  static Future<String> nameNumberFormat() async {
    if (!_available) return 'raw';
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      return normalizeVmNumberFormat(rows[_nameNumberFormatKey]);
    } catch (_) {
      return 'raw';
    }
  }

  static Future<void> setNameNumberFormat(String value) async {
    if (!_available) return;
    await MetaSettingsModule.persistAuxRow(
        _nameNumberFormatKey, normalizeVmNumberFormat(value));
  }

  /// One-shot snapshot of all naming inputs: new/duplicate rule flows need
  /// four keys at once — one full-table scan, not four serial ones.
  static Future<
      ({
        VmNamingStrategy strategy,
        String prefix,
        String numberFormat,
        int counter,
      })> namingSnapshot() async {
    const fallback = (
      strategy: VmNamingStrategy.maxPlusOne,
      prefix: 'rule',
      numberFormat: 'raw',
      counter: 0,
    );
    if (!_available) return fallback;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      final counter = int.tryParse(rows[_nameCounterKey] ?? '');
      return (
        strategy: parseVmNamingStrategy(rows[_namingStrategyKey]),
        prefix: normalizeVmPrefix(rows[_namePrefixKey]),
        numberFormat: normalizeVmNumberFormat(rows[_nameNumberFormatKey]),
        counter: counter == null || counter < 0 ? 0 : counter,
      );
    } catch (_) {
      return fallback;
    }
  }

  /// Monotonic watermark for the `globalCounter` strategy: only moves
  /// forward, never reset by deletions.
  static Future<int> loadNameCounter() async {
    if (!_available) return 0;
    try {
      final rows = await MetaSettingsModule.repo.loadRawValues();
      final v = int.tryParse(rows[_nameCounterKey] ?? '');
      if (v == null || v < 0) return 0;
      return v;
    } catch (_) {
      return 0;
    }
  }

  /// Advances the watermark past [usedSuffix]; no-op when it would move
  /// backwards (keeps the counter monotonic under races).
  static Future<void> bumpNameCounter(int usedSuffix) async {
    if (usedSuffix < 1 || !_available) return;
    try {
      final cur = await loadNameCounter();
      if (usedSuffix > cur) {
        await MetaSettingsModule.persistAuxRow(
            _nameCounterKey, '$usedSuffix');
      }
    } catch (_) {}
  }
}
