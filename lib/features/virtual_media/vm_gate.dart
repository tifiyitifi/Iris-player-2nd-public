import 'package:iris/store/use_app_store.dart';

/// Feature gate for the Virtual Merge feature (tag_play pattern).
///
/// The feature is entirely ABSENT when the metadata-driven stack is off:
/// entries hidden, commands no-op with an explanatory dialog, and any
/// `virtualmedia.`-prefixed settings rows filtered via
/// `DefVisibility.registerPrefix` (registered in app_startup).
abstract final class VirtualMediaGate {
  static bool get enabled =>
      !useAppStore().state.useLegacyStoragePersistence &&
      useAppStore().state.useMetadataSettings;

  /// Seal for the legacy More-menu control center (VirtualMediaSheet with
  /// its session card and rule tiles). Sealed history: rule CRUD lives in
  /// meta-settings (VmManagerPage) and playback stays unaware single-video.
  /// Permanently false so the legacy sheet path — including its preview
  /// resolve, duration scan and session work — never executes. The file
  /// itself is kept untouched as dead code; do NOT flip this back on.
  static const bool legacySheetEnabled = false;
}
