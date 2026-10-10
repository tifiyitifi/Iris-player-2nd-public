import 'package:flutter/material.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:iris/features/scenario_playback/model/enum/scenario_queue_layout.dart'
    show ScenarioQueueLayout;
import 'package:iris/features/speed/model/enum/speed_gesture_mode.dart'
    show SpeedGestureMode;
import 'package:iris/features/speed/model/enum/speed_rate_picker_mode.dart'
    show SpeedRatePickerMode;
import 'package:iris/features/virtual_media/model/enum/vm_enums.dart'
    show VmCrossSegmentDragStrategy, VmDualTimeSyncMode;
import 'package:iris/features/virtual_media/rule/vm_tick_color.dart'
    show kVmTickColorDefaultArgb;
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart'
    show kVmTickExtentDefaultPx;
import 'package:iris/models/enums/breadcrumb_start_side.dart'
    show BreadcrumbStartSide;
import 'package:iris/models/enums/step_seek_mode.dart' show StepSeekMode;
import 'package:iris/models/enums/video_cache_preset.dart';
import 'package:iris/models/enums/webdav_scan_mode.dart' show WebDavScanMode;
import 'package:iris/models/store/gesture_region.dart';
import 'package:iris/models/store/keyboard_form_geometry.dart';
import 'package:iris/models/store/title_overlay_config.dart';
import 'package:iris/models/store/video_display_mode.dart';
import 'package:iris/models/store/window_fit_mode.dart';
import 'package:iris/widgets/popup.dart' show PopupDirection;

part 'app_state.freezed.dart';
part 'app_state.g.dart';

// NOTE:
// After modifying a Freezed model, you must regenerate the generated files
// so that changes are reflected in *.freezed.dart and *.g.dart.
//
// Run in the project root:
//
// flutter pub run build_runner build --delete-conflicting-outputs

// dart run  build_runner build --delete-conflicting-outputs

// Or use watch mode for continuous generation:
//
// flutter pub run build_runner watch --delete-conflicting-outputs
// dart run build_runner watch --delete-conflicting-outputs

//When not to use dart run
//
// If your project:
// • Uses very old Flutter (<2.12)
// • Has tooling that assumes Flutter context

enum PlayerBackend {
  mediaKit,
  fvp,
}

/// Where a never-dragged V3 floating queue bar starts, as a fraction of the list
/// area's travel: horizontally centred, low down — the same spot the
/// control-group floating switch button defaults to (`floatingX = 0.5`,
/// `floatingY = 0.72`), so the two floaters read as one system. Every profile
/// starts here; they diverge only once the user drags one of them.
const Offset kScenarioQueueBarDefaultOffset = Offset(0.5, 0.72);

/// Which media types global browsing surfaces expose. Metadata-mode-only:
/// persisted exclusively via a dedicated `browse.` Drift row (never the
/// legacy blob), and resolved through [resolveBrowseMediaScope] so a gate-OFF
/// run behaves exactly as if every playable type were listed (`all`).
enum BrowseMediaScope {
  all,
  videoOnly,
  audioOnly,
}

enum Repeat {
  none,
  all,
  one,
}

enum SortBy {
  name,
  size,
  lastModified,
}

enum SortOrder {
  asc,
  desc,
}

enum ScreenOrientation {
  device,
  landscape,
  portrait,
}

/// Defines the horizontal slider style for phone layout.
/// 定义手机布局下的横向滑动条样式。
///
/// - [normal]: Standard horizontal slider.
///   普通横向滑动条。
/// - [circle]: Circular slider designed for easier one-handed use.
///   为单手操作优化的圆形滑动条。
enum PhoneLandscapeSliderType {
  normal, // 保持不变（原成员）
  circleRight, //圆形右侧样式
  circleLeft // 圆形左侧样式
}

/// Selects the shared phone-landscape control layout.
///
/// Side is a layout concern. Individual phone controls receive this
/// value and mirror themselves instead of carrying separate left/right APIs.
enum PhoneLandscapeUseMode {
  normal,
  rightSide,
  leftSide,
  @Deprecated('Use rightSide')
  rightHanded,
  @Deprecated('Use leftSide')
  leftHanded,
}

/// Horizontal anchor of the sideway one-handed panel (meta era).
///
/// Persisted EXCLUSIVELY as the `slider.posH` AUX row; gate-OFF runs derive
/// the anchor from [PhoneLandscapeUseMode] instead (see
/// resolveSidePanelAlignment).
enum PhoneSidePositionH { left, center, right }

/// Vertical anchor of the sideway one-handed panel (meta era).
///
/// Persisted EXCLUSIVELY as the `slider.posV` AUX row; gate-OFF runs derive
/// the anchor from [PhoneLandscapeUseMode] instead.
enum PhoneSidePositionV { top, middle, bottom }

/// Hide direction for corner-anchored side panels (four corners only).
///
/// - [vertical]: slide out along the vertical axis.
/// - [horizontal]: slide out along the horizontal axis.
/// - [diagonal]: slide out diagonally to the corner.
///
/// Stored PER PLATFORM — `slider.cornerHideMode` (desktop) and
/// `slider.phoneCornerHideMode` (phone) — because a phone panel is always
/// corner-anchored and so honours all three, while sharing one row would let a
/// desktop choice drive a phone that has no way to change it back. Default
/// [vertical] on both.
enum SidePanelCornerHideMode { vertical, horizontal, diagonal }

/// The concrete side scrubber design used when a side mode is
/// active. Both designs share the same grip and release-to-seek lifecycle but
/// map thumb motion to a target time differently:
///
/// - [dial]: dual-ring dial (see PhoneRingDialMath): inner chunked block ring
///   for wayfinding, outer current-block revolution for absolute jumps, a
///   seek-step axis strip, and four corner buttons clipped by the ring band.
/// - [classic]: the ORIGINAL circle slider (circle right / circle left)
///   rendered on the chosen side — the "simple circle arc" option.
///
/// DEPRECATED KINDS (requirement #6, 全面废弃): [arc], [timeLens] and
/// [snake] are dead designs kept ONLY for read-compat with old persisted
/// blobs; load-time normalization folds them into [classic] and
/// resolveScrubberSlot degrades them to the legacy circle slider, so they
/// can never render again. Do not add new UI for them.
enum PhoneSideScrubberKind {
  @Deprecated('Fully retired: load-time normalization folds this into classic')
  arc,
  @Deprecated('Fully retired: load-time normalization folds this into classic')
  timeLens,
  @Deprecated('Fully retired: load-time normalization folds this into classic')
  snake,
  dial,
  classic,
}

@Deprecated('Use PhoneSideScrubberKind')
typedef PhoneOneHandedScrubberKind = PhoneSideScrubberKind;

/// Action performed when one of the four center zones of the circular
/// playback slider / ring dial is tapped.
///
/// The inner hit circle is split by a faint 45° X into four sectors (inward,
/// outward, top, bottom). Phones default the inward sector to
/// [switchControlGroup]; desktop keeps the legacy all-[toggleControls] center
/// until [AppState.desktopCenterZonePhoneMode] opts in.
enum CircleSliderCenterAction {
  none, // ignore tap
  toggleControls, // show / hide control overlay
  togglePlayPause, // play ↔ pause
  switchControlGroup // cycle the bottom control group (playback ↔ background)
}

/// One of the four center-sector directions of the circular playback slider /
/// ring dial. [inward] faces the screen centre, [outward] the screen edge.
enum CenterZone { inward, outward, top, bottom }

/// Horizontal alignment of the two phone-PORTRAIT bottom-bar groups
/// (`MobileControlLayout`): the normal playback rows and the group-2 副音 quick
/// bar. PORTRAIT-only — the one-handed side panel keeps its own anchor-driven
/// block position (`sidewayBarPos`) and the standalone desktop 副音 row keeps
/// `background_playback.quickBarAlign`; neither reads these.
///
/// - [left]/[right] pack the group to that edge.
/// - [center] reproduces the pre-238d47c2 look per group: the playback rows
///   spread with `spaceEvenly`, while the 副音 block is centred as a whole
///   (a shrink-wrapped `BalancedButtonWrap`, which cannot spread).
enum PortraitBarAlign { left, center, right }

enum GestureMode {
  /// Original hard-coded gesture behavior
  classic,

  /// Region-based, layout-driven gesture system
  region,

  /// Reserved: right-side-only horizontal gestures
  rightSideLandscape,

  /// Reserved: left-side-only horizontal gestures
  leftSideLandscape,

  @Deprecated('Use rightSideLandscape')
  rightHandLandscape,
  @Deprecated('Use leftSideLandscape')
  leftHandLandscape,
}

enum LandscapeGestureProfile {
  classic,
  region,
  rightSide,
  leftSide,

  @Deprecated('Use rightSide')
  rightHand,
  @Deprecated('Use leftSide')
  leftHand,

  /// Tag-play region profile (deprecated: meta now unified).
  @Deprecated('Use region/rightSide/leftSide with unified tag strip')
  tagPlay,
}

/// Colour scheme of the ring-dial block wheel.
enum RingDialPalette { rainbow, cold, warm, mono }

/// Shared placement side of the ring dial and its fixed axis strip,
/// relative to the screen centreline (see [AppState.ringDialSide]).
enum DialSide { inner, outer }

/// Which physical ring hosts which function.
///
/// - [innerChunk]: chunk (wayfinding, whole-timeline) on the inner physical
///   ring, progress (current-block) on the outer — the legacy layout.
/// - [outerChunk]: swapped — chunk on the outer physical ring, progress on
///   the inner. Stroke widths follow function (chunk 7px, progress 4px), not
///   radius, and radii remain physical (outerRadius/innerRadius).
enum RingDialAssignment { innerChunk, outerChunk }

enum PortraitGestureProfile {
  classic,
  region,

  /// Tag-play region profile (default layout + top double-tap strip).
  tagPlay,
}

/// Desktop keyboard shortcut layout.
///
/// - [potplayer]: Windows-PotPlayer-aligned default bindings plus the `;`
///   prefix-sequence system (see features/windows/desktop_keyboard).
/// - [legacy]: original IRIS bindings.
///
/// Runtime reads ALWAYS go through `resolveKeyboardScheme`: while the
/// metadata gate is OFF the stored value is ignored and [legacy] applies, so
/// legacy-blob users never observe the potplayer default.
enum KeyboardShortcutScheme {
  legacy,
  potplayer,
}

/// PotPlayer-style keyboard OSD placement / layout (windows/desktop only).
///
/// Persisted EXCLUSIVELY via `osd.` Drift rows (JsonKey-excluded) and
/// resolved through `resolveOsd*` helpers so legacy-mode runs degrade to
/// no-OSD / defaults. See `lib/features/osd/`.
enum OsdHAlign { left, center, right }

enum OsdVAlign { top, middle, bottom }

enum OsdLayout { singleLine, twoLines }

enum OsdVisibilityMode { always, hideWhenControlVisible }

/// Desktop control-bar arrangement (features/windows/desktop_control_bar).
///
/// - [singleLine]: classic one-line bar — transport buttons, inline
///   position/duration + slider, right-side buttons all share one row.
/// - [stacked]: PotPlayer-style three rows — position/duration labels on
///   top, a full-width seek bar beneath them, then the SAME button row
///   (identical left/right grouping) as [singleLine].
///
/// Runtime reads ALWAYS go through `resolveDesktopControlBarLayout`: while
/// the metadata gate is OFF the stored value is ignored and [singleLine]
/// applies, so legacy-blob users never observe the stacked bar.
enum DesktopControlBarLayout {
  singleLine,
  stacked,
}

/// Playlist panel placement on desktop (PotPlayer-style dock vs floating popup).
///
/// - [popup]: legacy floating `PopupRoute` (left/right slide, bottom-aligned).
/// - [dockedRight]: PotPlayer-style right-side dock (`Row[video | panel]`).
enum PlaylistPanelMode {
  popup,
  dockedRight,
}

/// What `Enter` (picture fullscreen) does to the dock while fullscreen.
enum SideFullscreenBehavior {
  keepPanel,
  hidePanel,
}

/// Floating queue theme (popup). Persisted as `window.playlistPopupTheme`.
enum PlaylistPopupTheme {
  system,
  dark,
  light,
}

/// Dock (side) queue theme. Persisted as `window.playlistDockTheme`.
enum PlaylistDockTheme {
  potlikeDark,
  system,
  light,
}

@freezed
abstract class AppState with _$AppState {
  const factory AppState({
    @Default(false) bool autoPlay,
    @Default(false) bool shuffle,
    @Default(Repeat.none) Repeat repeat,
    @Default(BoxFit.contain) BoxFit fit,
    @Default(1) double rate,
    @Default(2.0) double transientRate,
    @Default(5) int seekStepSeconds,

    /// Desktop keyboard layout. The stored default is potplayer, but runtime
    /// reads MUST go through resolveKeyboardScheme: while the metadata gate
    /// is OFF the value degrades to legacy, so legacy-blob users never see
    /// the potplayer bindings (same contract as the ring-dial scrubber kind).
    /// See features/windows/desktop_keyboard.
    @Default(KeyboardShortcutScheme.potplayer)
    KeyboardShortcutScheme keyboardShortcutScheme,

    /// Desktop control-bar arrangement. The stored default is stacked (the
    /// PotPlayer-style three-row bar), but runtime reads MUST go through
    /// resolveDesktopControlBarLayout: while the metadata gate is OFF the
    /// value degrades to singleLine, so legacy-blob users never see the
    /// stacked bar (same contract as the keyboard scheme).
    /// See features/windows/desktop_control_bar.
    @Default(DesktopControlBarLayout.stacked)
    DesktopControlBarLayout desktopControlBarLayout,

    /// Desktop hover policy (what a PASSIVE mouse move reveals; explicit
    /// shows — startup, click, keyboard, wheel — always reveal the full bar).
    /// [desktopHoverShowTitle] reveals the title bar on hover, while
    /// [desktopHoverShowControlBar] additionally reveals the whole control
    /// bar. With both OFF a hover only keeps the cursor visible. Persisted as
    /// the `app.desktopHoverShowTitle` / `app.desktopHoverShowControlBar`
    /// snapshot rows; runtime reads go through `shouldRequireClickToShowPanel` /
    /// `desktopHoverRevealsTitle`, which degrade to today's
    /// hover-reveals-everything behavior while the metadata gate is OFF.
    @Default(true) bool desktopHoverShowTitle,
    @Default(false) bool desktopHoverShowControlBar,
    @Default(1.0) double playbackRateBeforeTransient,

    /// Last non-1.0 playback rate, remembered for the desktop Z-key
    /// speed-reset toggle (see resolveSpeedResetToggle). Maintained by
    /// AppStore.updateRate on every non-1.0 rate change regardless of
    /// source, so Z always restores the most recent custom speed.
    @Default(1.0) double rateBeforeReset,
    @Default(80) int volume,
    @Default(false) bool isMuted,
    @Default(ThemeMode.system) ThemeMode themeMode,
    @Default('none') String preferedSubtitleLanguage,
    @Default('system') String language,
    @Default(false) bool autoCheckUpdate,
    @Default(false) bool autoResize,
    @Default(false) bool alwaysPlayFromBeginning,
    @Default(PlayerBackend.mediaKit) PlayerBackend playerBackend,
    /// Which strategy resolves an IPv4-wildcard WebDAV host. Defaults to the
    /// bounded-concurrency discovery path; the legacy serial isolate scan is
    /// retained behind [WebDavScanMode.legacyScan].
    @Default(WebDavScanMode.discovery) WebDavScanMode webDavScanMode,
    @Default(SortBy.name) SortBy sortBy,
    @Default(SortOrder.asc) SortOrder sortOrder,
    @Default(true) bool folderFirst,
    /// Storage browser pagination page size (persisted like rate).
    /// 存储浏览器分页大小。
    @Default(100) int storageBrowserPageSize,
    //@Default(ScreenOrientation.device) ScreenOrientation orientation,

    /// Legacy horizontal-slider placement for phones.
    ///
    /// DERIVED from [phoneLandscapeUseMode] on every write
    /// (`updatePhoneLandscapeUseMode` → `sliderTypeForUseMode`) and read only
    /// by the frozen legacy path; gate-ON runs place the panel from the use
    /// mode. It stays readable rather than unreadable, so the pair can be
    /// repaired from either side — but nothing may ACT on it under the gate:
    /// [useLegacyCircleSliderPanel] is the only thing that mounts a panel from
    /// this field, and it refuses to while the gate is on, exactly as
    /// `resolveControlPanelAnchorFrom` refuses to place one by it.
    ///
    /// The default is [PhoneLandscapeSliderType.circleRight], paired with the
    /// [PhoneLandscapeUseMode.rightSide] default below: a brand-new install
    /// ships the right-side one-handed panel and every settings surface reads
    /// the same placement. The two encode one decision and are written together
    /// by `sliderTypeForUseMode`, so an unpaired default would be a state no UI
    /// choice could reach.
    @Default(PhoneLandscapeSliderType.circleRight)
    PhoneLandscapeSliderType phoneLandscapeSliderType,
    @Default(PhoneLandscapeUseMode.rightSide)
    PhoneLandscapeUseMode phoneLandscapeUseMode,
    /// Side-panel scrubber design. The install default is the ring dial so a
    /// fresh install ships with it; existing installs keep their persisted
    /// value (no migration folds `classic` into `dial`).
    @Default(PhoneSideScrubberKind.dial)
    PhoneSideScrubberKind phoneOneHandedScrubberKind,

    /// Phone-PORTRAIT bottom-bar alignment of the two groups (see
    /// [PortraitBarAlign] / `MobileControlLayout`). Persisted as the
    /// `app.portraitPlaybackAlign` / `app.portraitSubAudioAlign` snapshot rows.
    /// Defaults reproduce the pre-238d47c2 look; the one-handed side panel and
    /// the standalone desktop 副音 row are NOT governed by these.
    @Default(PortraitBarAlign.center)
    PortraitBarAlign portraitPlaybackAlign,
    @Default(PortraitBarAlign.center)
    PortraitBarAlign portraitSubAudioAlign,

    // --- Sideway panel anchor (metadata era) ---
    //
    // Same AUX contract as the ring-dial block below: JsonKey exclusions keep
    // these out of the legacy blob AND the `app.%` snapshot; their ONLY
    // persistence route is the dedicated `slider.` Drift rows. Gate-OFF runs
    // resolve the anchor from phoneLandscapeUseMode via
    // resolveSidePanelAlignment — a stale stored value can never leak.
    /// Horizontal anchor of the sideway one-handed panel (desktop 9-grid).
    @Default(PhoneSidePositionH.right)
    @JsonKey(includeToJson: false, includeFromJson: false)
    PhoneSidePositionH phoneSidePositionH,
    /// Vertical anchor of the sideway one-handed panel (desktop 9-grid).
    @Default(PhoneSidePositionV.bottom)
    @JsonKey(includeToJson: false, includeFromJson: false)
    PhoneSidePositionV phoneSidePositionV,
    /// Phone-only horizontal anchor (left/right only, posV fixed bottom).
    /// Persisted as `slider.phonePosH` — isolated from desktop `slider.posH`
    /// so phone and desktop never overwrite each other.
    @Default(PhoneSidePositionH.right)
    @JsonKey(includeToJson: false, includeFromJson: false)
    PhoneSidePositionH mobileSidePositionH,
    // Total panel size: phone = screen % (40%W/90%H), desktop = absolute px
    // (1080p notebook default 380×420, min 260×320, max window*0.8).
    // Phone persisted as slider.widthPct/heightPct, desktop as widthPx/heightPx.
    @Default(40)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayPanelWidthPct,
    @Default(90)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayPanelHeightPct,
    // Desktop absolute panel size (px) — see above; phone ignores these.
    @Default(380)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayPanelWidthPx,
    @Default(420)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayPanelHeightPx,
    // Windows-drag rings (slider.* AUX, JsonKey-excluded, meta-only).
    // Inset = fixed px from origin edge along the draggable edge; radius
    // per-axis so H/V rings tune independently. Persisted as slider.handle*.
    @Default(28)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayHandleInsetH,
    @Default(28)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayHandleInsetV,
    @Default(8)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayHandleRadiusH,
    @Default(8)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayHandleRadiusV,
    // When true (meta-only, default OFF), the sideway total panel (slider +
    // button bar) only appears after a tap/click; hover still shows title
    // and cursor normally (see controls_overlay). Persisted as slider.requireClick.
    @Default(false)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool sidewayPanelRequireClick,
    // Corner hide direction for the sideway total panel (four corners only).
    // Persisted as slider.cornerHideMode; middle edges ignore this.
    @Default(SidePanelCornerHideMode.vertical)
    @JsonKey(includeToJson: false, includeFromJson: false)
    SidePanelCornerHideMode sidePanelCornerHideMode,
    // Phone-only twin of [sidePanelCornerHideMode]. Persisted as
    // `slider.phoneCornerHideMode` — isolated from the desktop row so a
    // desktop choice can never silently drive (and then be un-editable on) a
    // phone, the same split `phoneSidePositionH`/`mobileSidePositionH` uses.
    // A phone anchor is always a bottom corner, so all three modes apply there.
    @Default(SidePanelCornerHideMode.vertical)
    @JsonKey(includeToJson: false, includeFromJson: false)
    SidePanelCornerHideMode mobileSidePanelCornerHideMode,
    @Default(30) int snakeFineWindowSeconds,
    @Deprecated('Replaced by sidewayPanelWidthPct/HeightPct (slider.widthPct/heightPct); kept for migration only')
    @Default(40) int circleLandscapePercent,
    // Center-tap zone actions for the circular slider / ring dial. The inner
    // hit circle is split by a faint 45° X into four sectors: inward (toward
    // the screen centre), outward (toward the screen edge), top and bottom.
    // Phones default inward → switch the bottom control group; desktop keeps
    // the legacy behavior (all four → toggleControls) until the user opts
    // into the phone layout via [desktopCenterZonePhoneMode].
    @Default(CircleSliderCenterAction.switchControlGroup)
    CircleSliderCenterAction centerZoneInwardAction,
    @Default(CircleSliderCenterAction.toggleControls)
    CircleSliderCenterAction centerZoneOutwardAction,
    @Default(CircleSliderCenterAction.toggleControls)
    CircleSliderCenterAction centerZoneTopAction,
    @Default(CircleSliderCenterAction.toggleControls)
    CircleSliderCenterAction centerZoneBottomAction,
    // Desktop opt-in: honor the four center-zone actions above (phone layout)
    // instead of the legacy all-toggleControls center. Mobile ignores it.
    @Default(false)
    bool desktopCenterZonePhoneMode,
    @Default(0.9) double circleSliderScale, // 0.0 → 1.0, default 90% per circle style spec
    // Circle position inside sideway panel (relative 0..1, center 0.5), metadata-only
    @Default(0.5)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double circlePosX,
    @Default(0.5)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double circlePosY,
    // Side panel bottom button-block position, side-relative 0..1: 0 = the
    // block hugs the screen-centre-facing edge (right-docked → left, left-docked
    // → right), 1 = the outer window edge. Mirrors ringDialRingSlotT for the
    // button bar; persisted as the `slider.barPos` AUX row (meta-only).
    @Default(0.0)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidewayBarPos,

    // --- Ring dial (one-handed scrubber) styling ---
    //
    // Persisted EXCLUSIVELY through metadata-driven Drift rows (`dialring.`
    // prefix, see MetaSettingsModule.saveDialRingRow). The JsonKey exclusions
    // keep these fields out of the legacy JSON blob AND the `app.%` snapshot
    // rows, so a stale stored value can never resurrect a removed knob and
    // snapshot wipes can never clobber the dedicated rows.
    /// Block-wheel colour scheme (see phone_ring_dial_palette.dart).
    @Default(RingDialPalette.mono)
    @JsonKey(includeToJson: false, includeFromJson: false)
    RingDialPalette ringDialPalette,
    /// Invisible bounding-box height share of the span between the screen
    /// top and the button bar top. The box is bottom-anchored (flush against
    /// the button row); only its TOP edge moves when this changes. 0.30–1.00.
    @Default(0.90)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double ringDialHeightPct,
    /// Outer band radius as a fraction of the usable panel radius.
    @Default(1.0)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double ringDialOuterRadius, // 0.80 – 1.00
    /// Inner band radius as a fraction of the usable panel radius.
    @Default(0.787)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double ringDialInnerRadius,
    /// Placement side for the ring: `inner` hugs the screen-centreline edge,
    /// `outer` the screen-edge side.
    @Default(DialSide.inner)
    @JsonKey(includeToJson: false, includeFromJson: false)
    DialSide ringDialSide,
    /// Which physical ring hosts which function (see [RingDialAssignment]).
    /// Persisted as `dialring.ringDialAssignment` (meta-only).
    @Default(RingDialAssignment.innerChunk)
    @JsonKey(includeToJson: false, includeFromJson: false)
    RingDialAssignment ringDialAssignment,
    /// Requirement #8: when the video is too short for the chunk ring to
    /// chunk (blockCount <= 1), hide the chunk ring entirely (paint + hit
    /// testing) instead of showing a single solid slot. Renamed from the
    /// legacy `ringDialHideInnerWhenUnchunked` — storage migrates on read.
    @Default(true)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool ringDialHideChunkWhenUnchunked,
    /// Ring centre position as a slot ratio (0–1) inside its live corridor.
    /// Stored side-relative, so it survives size/handedness changes. 0 = hugs
    /// the screen-centreline (inner) edge, 1 = the outer window edge.
    @Default(0.30)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double ringDialRingSlotT,
    /// Virtual media only: the progress ring (block-local, non-chunk ring)
    /// clamps its DRAG inside the current file — 0% sticks at the file head,
    /// 100% at the file tail, so a continuous gesture never walks into the
    /// neighbour file. Reversing mid-drag moves back immediately. The chunk
    /// (wayfinding) ring still navigates the whole timeline. Metadata-only
    /// (`dialring.` AUX row; JsonKey-excluded).
    @Default(true)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool ringDialVmProgressLock,
    // Side adjustment dialog remembered offset (fraction of screen, 0.5=center).
    @Default(Offset(0.5, 0.5))
    @JsonKey(includeToJson: false, includeFromJson: false)
    Offset sidePanelDialogOffset,

    // --- Browse media scope ---
    //
    // Same contract as the ring-dial block above: JsonKey exclusions keep
    // the value out of the legacy blob and the app.% snapshot; its ONLY
    // persistence route is the dedicated `browse.` Drift row. Legacy-mode
    // runs resolve to [BrowseMediaScope.all] via resolveBrowseMediaScope.
    /// Which playable types browsing surfaces list (video / audio / both).
    @Default(BrowseMediaScope.all)
    @JsonKey(includeToJson: false, includeFromJson: false)
    BrowseMediaScope browseMediaScope,

    // --- Resume on startup ---
    //
    // Same contract as the browse-scope block above: JsonKey exclusions keep
    // the value out of the legacy blob and the app.% snapshot; its ONLY
    // persistence route is the dedicated `playback.` Drift row. Gate-OFF runs
    // resolve to true via resolveResumeOnStartup.
    //
    // NEVER confuse this policy with [autoPlay]: that field is the runtime
    // "media session has play intent" latch and is force-reset to false on
    // every load — it must never decide startup behavior.
    /// Whether opening the app auto-resumes the last playing media.
    @Default(true)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool resumeOnStartup,

    /// Desktop drag-and-drop split (percent of the player height): the top
    /// share APPENDS dropped items to the queue, the rest OVERRIDES and plays.
    /// Hard-clamped to 10–90; persisted ONLY as a `playback.dropAppendPercent`
    /// Drift row (JsonKey-excluded). The drop path exists only in the metadata
    /// era, so gate-OFF runs never read it.
    @Default(30)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double dropAppendZonePercent,

    /// media_kit (mpv) demuxer cache sizing preset, controlling
    /// `demuxer-max-bytes` / `demuxer-max-back-bytes`. Metadata-only AUX row
    /// (`playback.videoCachePreset`, JsonKey-excluded); legacy mode degrades
    /// to [VideoCachePreset.balanced] via `resolveVideoCachePreset`.
    @Default(VideoCachePreset.balanced)
    @JsonKey(includeToJson: false, includeFromJson: false)
    VideoCachePreset videoCachePreset,

    /// Step-seek (← / →, phone double-tap) scheduling strategy. Metadata-only
    /// AUX row (`playback.stepSeekMode`, JsonKey-excluded); legacy mode
    /// degrades to [StepSeekMode.precise] via `resolveStepSeekMode`. Both modes
    /// keep the precise landing; the difference is burst scheduling only (see
    /// [StepSeekMode]).
    @Default(StepSeekMode.adaptive)
    @JsonKey(includeToJson: false, includeFromJson: false)
    StepSeekMode stepSeekMode,

    // --- Keyboard OSD (PotPlayer-style floating info) ---
    //
    // Same AUX contract: JsonKey-excluded, persisted ONLY as `osd.` Drift
    // rows, and resolved through `resolveOsd*` helpers. Desktop-only
    // (`platforms: windows,linux,macos`); legacy-mode degrades to no OSD.
    @Default(true)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool osdEnabled,
    @Default(OsdVisibilityMode.always)
    @JsonKey(includeToJson: false, includeFromJson: false)
    OsdVisibilityMode osdVisibilityMode,
    @Default(OsdHAlign.right)
    @JsonKey(includeToJson: false, includeFromJson: false)
    OsdHAlign osdHAlign,
    @Default(OsdVAlign.bottom)
    @JsonKey(includeToJson: false, includeFromJson: false)
    OsdVAlign osdVAlign,
    @Default(OsdLayout.singleLine)
    @JsonKey(includeToJson: false, includeFromJson: false)
    OsdLayout osdLayout,
    @Default(2000)
    @JsonKey(includeToJson: false, includeFromJson: false)
    int osdDurationMs,

    // --- Orientation ---
    /// User’s preferred orientation when playback starts.
    /// This value is applied only when no runtime override exists.
    @Default(ScreenOrientation.device) ScreenOrientation preferredOrientation,

    /// Orientation explicitly set by user during playback.
    @Default(ScreenOrientation.device) ScreenOrientation runtimeOrientation,

    /// Whether reuse last play runtime orientation .
    @Default(false) bool reuseLastOrientation,

    /// Which gesture engine to use
    @Default(GestureMode.classic) GestureMode gestureMode,
    /// Landscape profile for a brand-new install: the right-side region layout,
    /// matching the right-side one-handed panel the slider defaults to.
    @Default(LandscapeGestureProfile.rightSide)
    LandscapeGestureProfile landscapeGestureProfile,
    @Default(PortraitGestureProfile.region)
    PortraitGestureProfile portraitGestureProfile,

    /// Persisted gesture → layout mapping
    @Default({})
    Map<String, Map<GestureIntent, GestureLayout>> gestureLayoutProfiles,
    @Default(false) bool showControlsOnPlayToPause,
    //
    @Default(TitleOverlayConfig()) TitleOverlayConfig controlsTitleConfig,
    @Default(TitleOverlayConfig(
      showAppIcon: false,
      fontSize: 16,
    ))
    TitleOverlayConfig minimalTitleConfig,
    @Default(false) bool useClassicTitleBar,
    @Default(false) bool useLegacyControlBar,
    @Default(false) bool useLegacyStoragePersistence,

    /// Warning dialogs the user chose to stop seeing (ids from
    /// lib/store/warning_dialogs.dart). Only suppressible classes live here —
    /// destructive/irreversible warnings never consult this list. Legacy blob
    /// users (metadata gate OFF) never persist entries, so every warning
    /// shows: the degradation is automatic, no resolver needed.
    @Default([]) List<String> suppressedWarnings,

    /// Master gate of the metadata-driven settings subsystem
    /// (features/meta_settings). Default ON since the meta-driven era
    /// became the install default: fresh installs boot straight into the
    /// DB-mirrored settings path. Existing installs keep whatever the
    /// legacy blob says (the blob is consulted at boot before defaults
    /// apply). When ON, AppStore persists a DB mirror (setting_values)
    /// alongside the blob so flipping the gate OFF is always lossless:
    /// gate-OFF clears ONLY the `app.*` snapshot rows (rebuilt from the blob
    /// on gate-ON), while the auxiliary-only domains (JsonKey-excluded here,
    /// e.g. `dialring.*`, `keybind.overrides`, `tagplay.*`) keep their rows
    /// and are re-hydrated onto the live state the moment the gate flips ON.
    @Default(true)
    bool useMetadataSettings,

    /// Sync gate of the metadata-settings subsystem. Only meaningful while
    /// [useMetadataSettings] is ON: when true (default) every metadata-path
    /// mutation ALSO writes the legacy blob (dual-write, rollback-safe);
    /// when false writes land in setting_values only and the blob freezes.
    ///
    /// The gate TRANSITIONS themselves always write the blob regardless of
    /// this flag — otherwise a restart could not even discover the master
    /// gate's new state (the blob is what boot-time gate peeking reads).
    @Default(true)
    bool syncLegacyBlob,

    /// When true (default), playback is routed through the context-driven
    /// playback system (PlaybackProvider). The legacy/paged queue paths keep
    /// working and can be switched back by flipping this flag in code while
    /// the final behavior is being settled.
    ///
    /// This is a pure code-level toggle: it is intentionally not persisted
    /// (see JsonKey) so a stale stored value can never override the code
    /// default during development.
    @JsonKey(includeToJson: false, includeFromJson: false)
    @Default(true)
    bool useScenarioDrivenPlayback,
    @Default(PopupDirection.right) PopupDirection defaultPopupDirection,
    @Default(BreadcrumbStartSide.left)
    BreadcrumbStartSide breadcrumbStartPortrait,
    @Default(BreadcrumbStartSide.right)
    BreadcrumbStartSide breadcrumbStartLandscape,

    // ── Desktop playlist dock (PotPlayer-style) ───────────────────────────
    //
    // Persisted EXCLUSIVELY as `window.` AUX rows (JsonKey-excluded), so the
    // value never lands in the legacy blob nor `app.%` snapshot. Metadata
    // gate OFF degrades to popup + hidden (see resolve helpers).
    @Default(PlaylistPanelMode.dockedRight)
    @JsonKey(includeToJson: false, includeFromJson: false)
    PlaylistPanelMode playlistPanelMode,
    @Default(true)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool playlistPanelVisible,
    @Default(380.0)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double playlistPanelWidth,
    @Default(SideFullscreenBehavior.hidePanel)
    @JsonKey(includeToJson: false, includeFromJson: false)
    SideFullscreenBehavior sideFullscreenBehavior,
    @Default(PlaylistPopupTheme.system)
    @JsonKey(includeToJson: false, includeFromJson: false)
    PlaylistPopupTheme playlistPopupTheme,
    @Default(PlaylistDockTheme.potlikeDark)
    @JsonKey(includeToJson: false, includeFromJson: false)
    PlaylistDockTheme playlistDockTheme,

    /// Toolbar layout of the scenario play queue, remembered PER screen shape
    /// (see `ScenarioQueueProfile`): the original responsive bar
    /// ([ScenarioQueueLayout.v1]), the compact single-row bar
    /// ([ScenarioQueueLayout.v2]) or the floating square-tile grid
    /// ([ScenarioQueueLayout.v3]).
    ///
    /// Persisted as the `window.scenarioQueueLayout{Desktop,Portrait,Landscape}`
    /// AUX rows, never in the legacy blob. A missing per-profile row falls back
    /// to the pre-split `window.scenarioQueueLayout` row, which is what carries
    /// an already-upgraded install's single choice into all three profiles
    /// without a schema migration; that row is read-only afterwards.
    ///
    /// The defaults are chosen PER SHAPE, not one value for all three: a phone
    /// held sideways has the width for the floating grid, a phone held upright
    /// and a desktop dock are better served by the compact row. So landscape
    /// ships [ScenarioQueueLayout.v3] and the other two
    /// [ScenarioQueueLayout.v2] — V2 rather than V1 because the condensed row is
    /// the better default everywhere, and a fresh install has no "toolbar it
    /// already knows" to protect.
    ///
    /// A default only ever applies when NEITHER the per-profile row NOR the
    /// pre-split row exists, so an install that already chose keeps its choice in
    /// every shape and this change cannot move anyone's toolbar. The queue's own
    /// toggle button and the settings row are the only ways to move them.
    @Default(ScenarioQueueLayout.v2)
    @JsonKey(includeToJson: false, includeFromJson: false)
    ScenarioQueueLayout scenarioQueueLayoutDesktop,
    @Default(ScenarioQueueLayout.v2)
    @JsonKey(includeToJson: false, includeFromJson: false)
    ScenarioQueueLayout scenarioQueueLayoutPortrait,
    @Default(ScenarioQueueLayout.v3)
    @JsonKey(includeToJson: false, includeFromJson: false)
    ScenarioQueueLayout scenarioQueueLayoutLandscape,

    /// Remembered spot of the V3 floating bar, per profile, as a FRACTION
    /// (0..1) of the list area's travel — never pixels, which would drift the
    /// moment the dock resizes or the phone rotates.
    ///
    /// Persisted as the `window.scenarioQueueBarOffset{...}` AUX rows
    /// (`"x,y"`, the shape `frameToolsOffset` already round-trips). Only
    /// [ScenarioQueueLayout.v3] reads these; V1 and V2 have no floating bar, so
    /// their stored spots are carried along untouched. All three start at
    /// [kScenarioQueueBarDefaultOffset] and diverge the moment one is dragged.
    @Default(kScenarioQueueBarDefaultOffset)
    @JsonKey(includeToJson: false, includeFromJson: false)
    Offset scenarioQueueBarOffsetDesktop,
    @Default(kScenarioQueueBarDefaultOffset)
    @JsonKey(includeToJson: false, includeFromJson: false)
    Offset scenarioQueueBarOffsetPortrait,
    @Default(kScenarioQueueBarDefaultOffset)
    @JsonKey(includeToJson: false, includeFromJson: false)
    Offset scenarioQueueBarOffsetLandscape,

    /// Whether the scenario play queue renders its breadcrumb row (scenario
    /// name › tag). Shared by BOTH queue layouts — the checkbox that drives it
    /// lives in the V2 overflow menu, so V1 honours the choice without owning a
    /// control. Persisted as the `window.scenarioQueueShowBreadcrumb` AUX row.
    /// Defaults to false: the queue crumbs are informational only
    /// (`navigateToCrumb` is a no-op there), and the saved space goes to rows.
    @Default(false)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool scenarioQueueShowBreadcrumb,

    /// Right-edge activation strip width as a percentage of the playback-area
    /// width, for the picture-fullscreen side-dock hover peek. Persisted as
    /// `window.fullscreenDockEdgeRevealPct`; hard-clamped to 0..50 (see
    /// clampFullscreenDockEdgePct).
    @Default(10.0)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double fullscreenDockEdgeRevealPct,

    /// Isolation zone of the one-handed side-type control panel for the
    /// picture-fullscreen queue summon strip: the panel's height plus this
    /// percentage of the playback-area height, measured up from the bottom.
    /// Persisted as `window.sidePanelIsolationPct`; hard-clamped to 0..50 (see
    /// clampSidePanelIsolationPct). Windows-only settings row.
    @Default(5.0)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double sidePanelIsolationPct,

    /// Isolation zone of the normal long-strip control bar for the
    /// picture-fullscreen queue summon strip: the bar's measured height plus
    /// this percentage of the playback-area height. Persisted as
    /// `window.linearBarIsolationPct`; hard-clamped to 0..100 (see
    /// clampLinearBarIsolationPct). Windows-only settings row.
    @Default(25.0)
    @JsonKey(includeToJson: false, includeFromJson: false)
    double linearBarIsolationPct,

    /// Desktop window-fit mode (WindowsPotPlayer parity, higher priority
    /// than the video display mode): [WindowFitMode.fitVideo] resizes the
    /// window to the video's resolution 1:1 on every video open/switch;
    /// [WindowFitMode.fixedWindow] keeps the current size. Persisted
    /// EXCLUSIVELY as the `window.fitMode` AUX row; gate OFF keeps the
    /// legacy `autoResize` path.
    @Default(WindowFitMode.fitVideo)
    @JsonKey(includeToJson: false, includeFromJson: false)
    WindowFitMode windowFitMode,

    /// Keep window inside screen when switching videos (desktop). When true,
    /// starting the next video pulls the window back fully into the visible
    /// area if it was dragged off-screen. Persisted as `window.keepInBounds`.
    @Default(true)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool keepWindowInBounds,

    // ── Desktop keybind overrides (PotPlayer scheme customization) ───────────
    //
    // Persisted EXCLUSIVELY as `keybind.overrides` AUX row (JsonKey-excluded).
    // JSON string encoding Map<PotPlayerAction.name, List<KeyCombo>> via
    // KeybindCodec. Metadata gate OFF degrades to empty (defaults only).
    @Default('{}')
    @JsonKey(includeToJson: false, includeFromJson: false)
    String keybindOverridesJson,

    // ── Video display mode (metadata-settings era) ─────────────────────────
    //
    // Persisted EXCLUSIVELY as `video.` AUX rows (JsonKey-excluded). Windows
    // and phone deliberately carry SEPARATE enums — their pipelines differ
    // (see video_display_mode.dart). Metadata gate OFF keeps the legacy
    // `fit` BoxFit cycle as the single source of truth; these fields are
    // never consulted and the corresponding settings rows are hidden via
    // DefVisibility.
    @Default(DesktopVideoDisplayMode.contain)
    @JsonKey(includeToJson: false, includeFromJson: false)
    DesktopVideoDisplayMode desktopDisplayMode,
    @Default(MobileVideoDisplayMode.contain)
    @JsonKey(includeToJson: false, includeFromJson: false)
    MobileVideoDisplayMode mobileDisplayMode,

    // ── Speed gesture (metadata era, AUX rows `speed.`) ─────────────────────
    //
    // Persisted EXCLUSIVELY as `speed.` AUX rows (JsonKey-excluded). Gate OFF
    // keeps the legacy single-axis behavior (see resolveSpeedGestureMode).
    @Default(SpeedGestureMode.dualAxis)
    @JsonKey(includeToJson: false, includeFromJson: false)
    SpeedGestureMode speedGestureMode,

    /// Playback-speed picker shape (metadata era, AUX row `speed.rateMode`).
    ///
    /// `dualWheel` = alarm-clock two-wheel picker (default); `list` = the
    /// legacy flat 0.1 list. Gate OFF ignores this field entirely (see
    /// resolveSpeedRatePickerMode) so the frozen legacy UI is untouched.
    @Default(SpeedRatePickerMode.dualWheel)
    @JsonKey(includeToJson: false, includeFromJson: false)
    SpeedRatePickerMode speedRatePickerMode,

    /// Remembered position of the playback-speed picker card, as a fraction
    /// (0..1) of the travel available to it inside the safe area; 0.5 = centred.
    ///
    /// Stored RELATIVE, not in pixels: an absolute offset drifts as soon as the
    /// window is resized or the device rotates. Shared by every
    /// `speed.rateMode` shape, so a spot the user parks applies whichever
    /// picker opens next. Persisted as `speed.dialogOffset` (`"x,y"`).
    @Default(Offset(0.5, 0.5))
    @JsonKey(includeToJson: false, includeFromJson: false)
    Offset speedRateDialogOffset,

    /// Where the shared keyboard form (the browser page jump) sits and how wide
    /// it is, as fractions of the travel and of the available width.
    ///
    /// Persisted RELATIVE, for the same reason as [speedRateDialogOffset]: an
    /// absolute offset drifts as soon as the window resizes or the device
    /// rotates. Persisted as `form.geometry` (`"dx,dy[,widthFraction]"`).
    @Default(KeyboardFormGeometry.kDefault)
    @JsonKey(includeToJson: false, includeFromJson: false)
    KeyboardFormGeometry keyboardFormGeometry,

    // ── Virtual media (metadata era, AUX rows `virtualmedia.`) ──────────────
    //
    // Persisted EXCLUSIVELY as `virtualmedia.` AUX rows (JsonKey-excluded).
    // Gate OFF degrades to defaults (direct switch, no hide, white tick).
    @Default(VmCrossSegmentDragStrategy.directSwitch)
    @JsonKey(includeToJson: false, includeFromJson: false)
    VmCrossSegmentDragStrategy vmCrossSegmentDragStrategy,
    // B-scheme dual-time second-grid alignment (sub-to-total by default).
    // Display only; never affects the axes or seek math.
    @Default(VmDualTimeSyncMode.subToTotal)
    @JsonKey(includeToJson: false, includeFromJson: false)
    VmDualTimeSyncMode vmDualTimeSync,
    @Default(false)
    @JsonKey(includeToJson: false, includeFromJson: false)
    bool vmHideChunkWhenSingleSegment,
    @Default(kVmTickColorDefaultArgb)
    @JsonKey(includeToJson: false, includeFromJson: false)
    int vmMarkTickColor,
    @Default(kVmTickExtentDefaultPx)
    @JsonKey(includeToJson: false, includeFromJson: false)
    int vmMarkTickExtent,
    // ── Screenshot save dirs (metadata era, AUX rows `screenshot.`) ────────
    //
    // Per-platform custom dirs (`''` = platform default). Persisted
    // EXCLUSIVELY as `screenshot.mobileDir` / `screenshot.desktopDir` AUX
    // rows (JsonKey-excluded). Split per platform so a phone↔desktop settings
    // transfer never overwrites the other side's directory with a foreign
    // shape (`content://` on desktop is meaningless and vice versa).
    @Default('')
    @JsonKey(includeToJson: false, includeFromJson: false)
    String screenshotMobileDir,
    @Default('')
    @JsonKey(includeToJson: false, includeFromJson: false)
    String screenshotDesktopDir,
    // ── Frame-tools float panel position ──────────────────────────────────
    //
    // A FRACTION (0..1) of the available travel inside the hosting Stack, not
    // pixels: an absolute offset silently drifts when the window grows — a
    // panel parked in the corner stops being corner-anchored and ends up
    // mid-screen — whereas a fraction re-derives the same spot at any size,
    // rotation or window width. 0.5 keeps it horizontally centred, matching
    // the first-reveal placement. Persisted as `screenshot.frameToolsOffset`
    // (`"x,y"`).
    @Default(Offset(0.5, 0.21))
    @JsonKey(includeToJson: false, includeFromJson: false)
    Offset frameToolsPanelFraction,
  }) = _AppState;

  factory AppState.fromJson(Map<String, dynamic> json) =>
      _$AppStateFromJson(json);
}
