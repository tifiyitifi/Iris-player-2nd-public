import 'package:flutter/foundation.dart';
import 'package:iris/store/kv/file_json_kv.dart';
import 'package:iris/store/kv/kv_keys.dart';
import 'package:iris/store/kv/kv_store.dart';
import 'package:iris/store/kv/routed_kv.dart';
import 'package:iris/store/kv/secure_kv.dart';
import 'package:iris/store/kv/session_kv.dart';
import 'package:iris/utils/app_instance.dart';
import 'package:iris/utils/app_paths.dart';
import 'package:path/path.dart' as p;

KvStore? _instance;
FileJsonKv? _portableFileKv;
SecureStorageKv? _secureKv;
MemoryKvStore? _ephemeralSessionKv;

/// Process-wide KV backend, selected ONCE from the portable-mode decision.
///
/// Requires `AppPaths.init()` to have completed first (main() guarantees
/// the ordering). Installed mode binds everything to secure storage; portable
/// Windows mode routes secret keys to secure storage and everything else to
/// `<userdata>/settings/kv.json`.
KvStore getKvStore() {
  final KvStore? existing = _instance;
  if (existing != null) return existing;

  final PortableLayout? layout = AppPaths.layout;
  if (!AppPaths.isPortable || layout == null) {
    return _instance = _secureKv ??= SecureStorageKv();
  }

  final FileJsonKv fileKv =
      _portableFileKv ??= FileJsonKv(
    filePath: p.join(layout.settingsDirPath, 'kv.json'),
  );
  return _instance = RoutedKv(
    fileKv: fileKv,
    secureKv: _secureKv ??= SecureStorageKv(),
    secretKeys: KvKeys.secretKeys,
  );
}

/// Session-scoped view of [getKvStore] for THIS window's playback session.
///
/// The first/only window (slot 1) gets the raw backend, so existing users keep
/// their historical keys. A second/third window gets a [SessionKv] wrapper and
/// its own `s2.`-prefixed queue/history/active-scenario entries — two windows
/// no longer overwrite each other's session on every save.
///
/// An ephemeral instance (every numbered slot was busy) gets a process-local
/// [MemoryKvStore] instead: it has no slot identity to scope with, and letting
/// it use the shared keys would overwrite the primary's session.
///
/// Config stores must keep using [getKvStore]: only "what am I currently
/// playing / where was I" state is per-instance.
KvStore getSessionKvStore() {
  if (AppInstance.isEphemeral) {
    return _ephemeralSessionKv ??= MemoryKvStore();
  }
  final KvStore base = getKvStore();
  final String prefix = AppInstance.sessionPrefix;
  if (prefix.isEmpty) return base;
  return SessionKv(inner: base, prefix: prefix);
}

/// The portable file side of [getKvStore]; null in installed mode.
/// Exposed for the first-run import flow (markers + migration target).
FileJsonKv? get portableFileKv => _portableFileKv;

/// The machine-bound encrypted side of [getKvStore].
/// Exposed for the first-run import flow (legacy value source).
SecureStorageKv get secureKv => _secureKv ??= SecureStorageKv();

@visibleForTesting
void resetKvStoreForTest() {
  _instance = null;
  _portableFileKv = null;
  _secureKv = null;
  _ephemeralSessionKv = null;
}

/// Test seam: force [getKvStore] to serve [backend] (e.g. a throwing or
/// spying fake). Pair with [resetKvStoreForTest] in tearDown.
@visibleForTesting
void setKvStoreForTest(KvStore backend) {
  _instance = backend;
}
