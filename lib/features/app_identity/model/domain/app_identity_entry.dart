import 'package:freezed_annotation/freezed_annotation.dart';

part 'app_identity_entry.freezed.dart';
part 'app_identity_entry.g.dart';

/// Domain model of a custom desktop entry (shortcut).
///
/// One entry maps to one home-screen icon / Windows .lnk with its own name,
/// image, and a two-way state choice:
///
/// - [sharedWithDefault] TRUE: the entry is a pure icon/name ALIAS of the
///   default entry — it shares the SystemPlaying context and never owns a
///   workspace. The seed fields are hidden and unused.
/// - [sharedWithDefault] FALSE (default): the entry owns its OWN independently
///   saved "system playing" workspace (a [ScenarioKind.entryWorkspace] row),
///   so switching entries never disturbs each other or the default.
///
/// [seedScenarioId]/[seedTagId] are used ONLY to initialize the entry's own
/// workspace on the FIRST launch. They are never re-applied afterwards — by
/// then the underlying scenario/tag data may have changed a lot, so the entry
/// keeps its own evolving state instead.
@freezed
abstract class AppIdentityEntry with _$AppIdentityEntry {
  const factory AppIdentityEntry({
    /// Stable id used as the shortcut id / .lnk discriminator.
    required String id,

    /// User-visible label. Validated by [AppIdentityValidation].
    required String name,

    /// Relative file name of the prepared icon under app documents dir
    /// (e.g. `identity/entry_<id>_v2.png`). Empty = no custom image.
    @Default('') String imageRef,

    /// Version of [imageRef] for Windows .lnk icon cache busting.
    @Default(1) int imageVersion,

    /// Relative file name of the ORIGINAL picked source image under app
    /// documents dir (e.g. `identity/source_<id>.png`). The picker's cache
    /// copy is relocated here so editing can re-open the FULL image and the
    /// crop rect below. Empty = no custom image.
    @Default('') String sourcePath,

    /// Normalized crop rectangle of [sourcePath] (all 0..1) that produced the
    /// prepared icon. Defaults to the full source image.
    @Default(0) double cropLeft,
    @Default(0) double cropTop,
    @Default(1) double cropRight,
    @Default(1) double cropBottom,

    /// TRUE = share the default SystemPlaying context (plain icon alias);
    /// FALSE = own an independent saved system-playing workspace.
    @Default(false) bool sharedWithDefault,

    /// One-time initialization scenario (optional). Applied only while
    /// [initializedAt] is null. Null = start with an empty workspace.
    String? seedScenarioId,

    /// One-time initialization tag (optional): on the first launch the entry
    /// enters the scenario ∩ tag view exactly like a normal scenario tag
    /// activation. Applied only while [initializedAt] is null.
    int? seedTagId,

    /// The entry's dedicated workspace scenario id, lazily created on the
    /// first activation of an independent entry. Null before then.
    String? workspaceScenarioId,

    /// The entry's dedicated 副音 (background) workspace scenario id
    /// ([ScenarioKind.entryBackground]), lazily created together with
    /// [workspaceScenarioId] so each independent entry owns its own fg/bg PAIR.
    /// Null before the entry's first activation. Not used by shared entries
    /// (they share the default background workspace).
    String? backgroundWorkspaceScenarioId,

    /// Timestamp of an independent entry's first activation; the seed runs
    /// only while this is null. Not set for shared entries (they own no
    /// workspace), so switching a shared entry to independent later still gets
    /// its one-time seed on the next launch.
    DateTime? initializedAt,

    DateTime? createdAt,
    DateTime? updatedAt,
  }) = _AppIdentityEntry;

  factory AppIdentityEntry.fromJson(Map<String, dynamic> json) =>
      _$AppIdentityEntryFromJson(json);
}
