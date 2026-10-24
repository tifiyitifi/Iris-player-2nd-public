import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/scenario_playback/model/domain/scenario.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_list_sort_by.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_manage_sort_by.dart';
import 'package:iris/models/store/app_state.dart' show Repeat;
part 'playback_scenario_store_state.freezed.dart';
part 'playback_scenario_store_state.g.dart';

/// In-memory state of the PlaybackScenarioStore.
///
/// Scenario-owned playback state (shuffle, repeat, sort, current item) is
/// persisted per-scenario in the media database; this store only tracks the
/// scenario list, its sort preference and the active scenario selection.
@freezed
abstract class PlaybackScenarioStoreState with _$PlaybackScenarioStoreState {
  const factory PlaybackScenarioStoreState({
    /// DB-backed mirror of the scenario list; always re-populated from the
    /// database by [PlaybackScenarioStore.refreshScenarios] after load, so it
    /// is intentionally excluded from the persisted blob (the DB is the source
    /// of truth, and the old persisted copy was stale/redundant).
    @JsonKey(includeFromJson: false, includeToJson: false)
    @Default([])
    List<Scenario> scenarios,
    String? activeScenarioId,
    @Default(false) bool isLoading,
    @Default(ScenarioListSortBy.name) ScenarioListSortBy scenarioSortBy,
    @Default(SortDirection.asc) SortDirection scenarioSortDirection,

    /// When true the Sources (Manage) list groups entries by their container
    /// (directory / storage) before sorting by name (D7). Global preference,
    /// persisted via the store's secure-storage load/save.
    @Default(true) bool manageContainerFirst,

    /// Sort field of the Sources (Manage) list (D3/D4). Global preference,
    /// persisted via the store's secure-storage load/save.
    @Default(ScenarioManageSortBy.name) ScenarioManageSortBy manageSortBy,

    /// Sort direction of the Sources (Manage) list. Global preference.
    @Default(SortDirection.asc) SortDirection manageSortDirection,

    /// When true (default) the Sources (Manage) list sorts within the Filter
    /// group order (group order is the primary key); when false the selected
    /// field sorts the whole visible list globally, ignoring group order (D7).
    /// Global preference.
    @Default(true) bool manageSortWithinGroup,

    /// Pagination page size of the playing-scenario queue view. Global
    /// preference, persisted via the store's secure-storage load/save.
    @Default(50) int playingScenarioQueuePageSize,

    /// Pagination page size of the Scenario preview view. Global preference,
    /// persisted via the store's secure-storage load/save.
    @Default(50) int scenarioPreviewQueuePageSize,

    /// When true (default) tapping an item in the Scenario preview keeps the
    /// preview open for continuous auditions; when false it exits the
    /// storages browser (queue-style). Global preference, persisted via the
    /// store's secure-storage load/save.
    @Default(true) bool scenarioPreviewStayOnTap,

    /// Pagination page size of the Sources (Manage) / browse lists. Global
    /// preference, persisted via the store's secure-storage load/save.
    @Default(100) int scenarioManagePageSize,

    /// Cached shuffle flag of the active scenario (mirrors the DB-backed
    /// per-scenario playback state so the player shuffle button can render
    /// synchronously).
    @Default(false) bool activeScenarioShuffled,

    /// Cached repeat mode of the active scenario (same mirror pattern).
    @Default(Repeat.none) Repeat activeScenarioRepeat,

    /// In-memory mirror of the currently playing occurrence
    /// (`storageId:path#occurrenceIndex`), set on every play/next/previous so
    /// queue views can highlight the playing item reactively. Derived from
    /// [ScenarioState.currentPlaybackOccurrence]; never persisted.
    @JsonKey(includeFromJson: false, includeToJson: false)
    String? currentOccurrenceKey,

    /// Monotonic revision of the effective (resolved) queue. Bumped whenever
    /// the active scenario or its sources/excludes/state change so widgets
    /// (e.g. prev/next visibility) can re-resolve `totalCount()`.
    @Default(0) int playbackVersion,

    /// Monotonic revision of the media snapshot the scenario resolves against.
    /// Bumped by the scenario-source refresh after its scans finish AND by the
    /// override/append actions that replace or extend the workspace sources,
    /// so an open queue view can re-fetch the page in place without the
    /// double-resolve a `playbackVersion` listener would cause.
    @Default(0) int sourceScanRevision,

    /// Counter driving the default name of the next save-as-new (`Scenario N`,
    /// D1/D2). Incremented ONLY after a successful save-new; override/append/
    /// sync-back never touch it.
    @Default(0) int saveCounter,

    /// The private playing workspace THIS window owns, when it is not the
    /// primary instance (slot > 1). Persisted in the session-scoped blob, so
    /// each window remembers its own row across restarts while the primary
    /// keeps the historical shared SystemPlaying row. Null on the primary and
    /// before an extra window's row is created.
    String? instanceWorkspaceId,
  }) = _PlaybackScenarioStoreState;

  factory PlaybackScenarioStoreState.fromJson(Map<String, dynamic> json) =>
      _$PlaybackScenarioStoreStateFromJson(json);
}
