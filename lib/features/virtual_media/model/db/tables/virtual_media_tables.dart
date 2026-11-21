import 'package:drift/drift.dart';
import 'package:iris/features/media_library/model/enum/basic_enum.dart';
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart';

/// One Virtual Merge rule — simplified v2 schema.
///
/// Rules are DATA: the resolver interprets them, nothing about grouping or
/// matching is hard-coded into playback code. Identity is the text [id].
///
/// JSON-in-text columns: [paths], [patterns] and [titleTags] are decoded
/// defensively by [VirtualMediaRepository] (malformed → default).
class VmRulesTable extends Table {
  @override
  String get tableName => 'vm_rules';

  /// Stable rule identity (generated `vm_<ms>`).
  TextColumn get id => text()();

  /// Display name shown in the rules sheet; also a title tag.
  TextColumn get name => text()();

  /// Optional description shown in the virtual item's subtitle.
  TextColumn get description => text().withDefault(const Constant(''))();

  /// 指定/匹配 × 递归/非递归.
  TextColumn get matchMode =>
      textEnum<VmMatchMode>().withDefault(const Constant('patternDir'))();

  /// JSON array of picked directory paths (指定模式).
  TextColumn get paths => text().withDefault(const Constant('[]'))();

  /// JSON array of `{kind,text,activated,pinned}` entries (匹配模式).
  TextColumn get patterns => text().withDefault(const Constant('[]'))();

  // ── Sort / group ──
  TextColumn get sortField =>
      textEnum<VmSortField>().withDefault(const Constant('fileName'))();

  TextColumn get sortDir =>
      textEnum<SortDirection>().withDefault(const Constant('asc'))();

  TextColumn get boundary =>
      textEnum<VmBoundaryMode>().withDefault(const Constant('sameDirOnly'))();

  /// Chunk duration cap in minutes.
  ///
  /// NOTE: the SQL default (90) predates the domain default (120); fresh
  /// rules always write explicit values via [VirtualMediaRepository], and
  /// reads clamp into range — see rowToRule. Changing the SQL default would
  /// require a v32 rebuild migration for zero behavioral gain.
  IntColumn get maxDurationMinutes =>
      integer().withDefault(const Constant(90))();

  /// Chunk item-count cap (see note above: SQL default 100 vs domain 30).
  IntColumn get maxItemCount => integer().withDefault(const Constant(100))();

  /// At least one cap must be active — enforced at save time.
  BoolColumn get useDurationCap =>
      boolean().withDefault(const Constant(true))();
  BoolColumn get useCountCap => boolean().withDefault(const Constant(true))();

  /// Exclude single videos longer than [maxSingleDurationMinutes] from the
  /// merge; unknown durations are never excluded.
  BoolColumn get useExcludeOverlong =>
      boolean().withDefault(const Constant(true))();

  /// Per-file exclusion threshold in minutes (default 35; 1–300).
  IntColumn get maxSingleDurationMinutes =>
      integer().withDefault(const Constant(35))();

  /// A chunk that ends up with exactly one segment is not virtualized.
  BoolColumn get skipSingleSegment =>
      boolean().withDefault(const Constant(true))();

  /// JSON array of lit [VmTitleTag] names in lighting order.
  TextColumn get titleTags => text().withDefault(const Constant('[]'))();

  /// Player title separator for virtual merge (spec §9.2 configurable).
  /// Default ':' so the player title becomes “目录:序号/总数:原名”.
  TextColumn get playerTitleSeparator =>
      text().withDefault(const Constant(':'))();

  // ── State ──
  /// Use/exclude polarity ([VmRuleUseMode]); independent of [enabled].
  TextColumn get useMode =>
      textEnum<VmRuleUseMode>().withDefault(const Constant('use'))();

  /// Disabled rules are ignored by the resolver entirely.
  BoolColumn get enabled => boolean().withDefault(const Constant(true))();

  /// Pinned rules display first — presentation only ("无视优先级").
  BoolColumn get pinned => boolean().withDefault(const Constant(false))();

  DateTimeColumn get createdAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {id};
}

/// Resume anchor per active virtual item.
///
/// Keyed by scopeKey (`rule|dir|#chunk`); stores WHICH segment was last
/// played and its local position so a re-resolve (files added/removed,
/// rule edited) can relocate the anchor precisely. Deliberately NOT the
/// display index — chunk boundaries may drift.
class VirtualMediaStatesTable extends Table {
  @override
  String get tableName => 'virtual_media_states';

  TextColumn get scopeKey => text()();

  /// Canonical media key (`storageId:path`) of the last-played segment.
  TextColumn get segmentKey => text().withDefault(const Constant(''))();

  /// Local position inside that segment, milliseconds.
  IntColumn get segmentLocalPositionMs =>
      integer().withDefault(const Constant(0))();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {scopeKey};
}

/// Virtual playback progress per scenario/tag/rule scope (spec §2).
///
/// New in v21: `scenarioId` + nullable `tagId` + `ruleId` + `scopeKey`
/// uniquely identify a virtual item's resume point.  Deleting/updating a
/// rule warns and clears rows for that rule (cancel/confirm dialog in the
/// rule editor).
class VmProgressTable extends Table {
  @override
  String get tableName => 'vm_progress';

  /// Scenario owning the effective stream (systemPlaying or user scenario).
  TextColumn get scenarioId => text()();

  /// Tag view id when the progress was saved, '' for no-tag.
  TextColumn get tagId => text().withDefault(const Constant(''))();

  /// Rule that produced the virtual item.
  TextColumn get ruleId => text()();

  /// Scope key `rule|dir|#chunk` of the virtual item.
  TextColumn get scopeKey => text()();

  /// Canonical media key `storageId:path` of the last-played segment.
  TextColumn get segmentKey => text().withDefault(const Constant(''))();

  /// Local position inside that segment, ms.
  IntColumn get localPositionMs => integer().withDefault(const Constant(0))();

  DateTimeColumn get updatedAt => dateTime().withDefault(currentDateAndTime)();

  @override
  Set<Column> get primaryKey => {scenarioId, tagId, scopeKey};
}
