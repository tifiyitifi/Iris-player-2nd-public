/// Central registry of every KV key the app persists through [KvStore].
///
/// Single source of truth for:
/// - call-site literals (import these instead of raw strings),
/// - portable-mode routing ([secretKeys]),
/// - first-run import enumeration ([all]),
/// - **persistence scope** ([scopes]): whether one value is shared by every IRIS
///   window or belongs to one window's session.
///
/// Scope rule (multi-window):
/// - [KvScope.shared] — app-wide configuration/library data. Any window may
///   write it, but only by diffing the field it changed (a whole-snapshot write
///   from a second window would revert a sibling's edit).
/// - [KvScope.session] — "where am I / what did I open here": queues, history,
///   active scenario, browse/search/selection state. Reads through
///   `getSessionKvStore()`, which scopes the key per instance (`s<n>.`), so two
///   windows never see each other's value.
abstract final class KvKeys {
  // ── Credential-bearing (machine-bound, NEVER migrate/portable) ──
  /// StorageState JSON — contains WebDAV/FTP credentials.
  static const String storageState = 'storage_state';

  // ── Ordinary application state (portable) ──
  static const String appState = 'app_state';
  static const String historyState = 'history_state';
  static const String playQueueState = 'playQueue_state';
  static const String queryPlayQueueState = 'query_play_queue_state';
  static const String playbackScenarioActiveId = 'playback_scenario_active_id';
  static const String mediaLibContentState = 'media_lib_content_state';
  static const String mediaLibsPageState = 'media_libs_page_state';
  static const String mediaLibSelection = 'media_lib_selection';
  static const String mediaLibSearchState = 'media_lib_search_state';
  static const String recursiveScanState = 'recursive_scan_state';
  static const String playbackScenariosSelection =
      'playback_scenarios_selection';

  /// Per-window browse location (current storage + path). Session-scoped: the
  /// shared navigation row belongs to the primary window; an extra window keeps
  /// "where am I browsing" for itself.
  static const String navigationState = 'storage_nav_state';

  /// Per-window claims of an independent entry's workspaces
  /// (`{"entry:<id>:fg": "<scenarioId>"}`). Session-scoped: the entry row keeps
  /// the CANONICAL (primary) workspace, while every extra window plays in its
  /// own claimed row so two windows never share one queue.
  static const String workspaceClaims = 'workspace_claims';

  /// 副音播放 state (queue + volume ratios + rate/shuffle/repeat prefs).
  /// Session fields (enabled/index/target) never reach the JSON.
  static const String backgroundPlaybackState = 'bg_playback_state';

  /// Per-window 副音 playback cursor (queue snapshot + remembered file + window
  /// offsets + shuffle seed). Session-scoped: the SOURCES and preferences are
  /// shared ([backgroundPlaybackState]), the position is not.
  static const String backgroundPlaybackPosition = 'bg_playback_position';

  /// One-handed bottom control-group switch (selected group + floating
  /// button visibility/position). Survives restarts, travels with portable
  /// mode.
  static const String controlGroupState = 'control_group_state';

  // ── Internal markers (never imported, not part of `all`) ──

  /// One-shot import into this portable folder already completed.
  static const String internalImportDone = 'portable.import.done';

  /// User explicitly declined the one-shot import for this folder.
  static const String internalImportSkipped = 'portable.import.skipped';

  /// Keys holding credentials; they stay in machine-bound encrypted
  /// secure storage even in portable mode (the encryption key lives in the
  /// Windows Credential Manager and cannot travel with the folder).
  ///
  /// NOTE: with the metadata-settings era ON, WebDAV/FTP passwords live in the
  /// Drift DB itself (StoragesTable.password, plaintext since its
  /// introduction) — that DB travels with portable mode by design; this set
  /// only governs legacy-blob keys.
  static const Set<String> secretKeys = {storageState};

  /// Every known migratable application key, in stable enumeration order.
  static const List<String> all = [
    appState,
    historyState,
    playQueueState,
    queryPlayQueueState,
    playbackScenarioActiveId,
    mediaLibContentState,
    mediaLibsPageState,
    mediaLibSelection,
    mediaLibSearchState,
    recursiveScanState,
    playbackScenariosSelection,
    navigationState,
    workspaceClaims,
    backgroundPlaybackState,
    backgroundPlaybackPosition,
    controlGroupState,
  ];

  /// Scope of every migratable key. Enforced for completeness by
  /// `test/kv_keys_scope_test.dart` so a new key can never ship unclassified.
  static const Map<String, KvScope> scopes = {
    storageState: KvScope.shared,
    appState: KvScope.shared,
    historyState: KvScope.session,
    playQueueState: KvScope.session,
    queryPlayQueueState: KvScope.session,
    playbackScenarioActiveId: KvScope.session,
    mediaLibContentState: KvScope.session,
    mediaLibsPageState: KvScope.session,
    mediaLibSelection: KvScope.session,
    mediaLibSearchState: KvScope.session,
    recursiveScanState: KvScope.session,
    playbackScenariosSelection: KvScope.session,
    navigationState: KvScope.session,
    workspaceClaims: KvScope.session,
    // Mixed on purpose: preferences/ratios (shared) + the legacy queue snapshot
    // inside the same JSON. New per-window cursors go to the position key.
    backgroundPlaybackState: KvScope.shared,
    backgroundPlaybackPosition: KvScope.session,
    controlGroupState: KvScope.shared,
  };
}

/// Persistence scope of one KV key (see [KvKeys.scopes]).
enum KvScope {
  /// One app-wide value every window reads and writes (diff-wise).
  shared,

  /// Belongs to one window; read/write through `getSessionKvStore()`.
  session,
}
