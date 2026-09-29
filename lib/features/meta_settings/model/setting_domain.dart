/// Naming registry for every settings domain in the catalog.
///
/// The subsystem accumulated THREE naming dialects:
///  - [defNamespace] — the catalog/engine identity (`<defNamespace>.<field>`).
///  - [storagePrefix] — the Drift AUX row namespace `<storagePrefix><field>`;
///    `app.` marks the full-state snapshot, `null` means the entry is an
///    action row with no persisted value of its own.
///  - [editorKeyForm] — the hand-written binding key form and its ARB title
///    keys, which do NOT always mirror the def namespace.
///
/// STORAGE PREFIXES ARE FROZEN: existing installs already hold those rows, so
/// renaming one without a Drift migration would silently drop user data. This
/// registry is the single place the mapping is documented; the naming test
/// fails when a contribution introduces an unregistered namespace or when two
/// domains claim the same non-snapshot storage prefix.
class SettingDomain {
  const SettingDomain({
    required this.defNamespace,
    required this.storagePrefix,
    required this.editorKeyForm,
    this.note = '',
  });

  /// Namespace before the first `.` in a def key (`virtualmedia`,
  /// `background_playback`, ...). `app` is the generic-renderer domain.
  final String defNamespace;

  /// Row prefix for this domain, `'app.'` for the snapshot domain, or null
  /// for action-only entries.
  final String? storagePrefix;

  /// Human-readable editorKey / titleKey form (documentation only).
  final String editorKeyForm;

  final String note;
}

/// One entry per def namespace. Keep sorted by [SettingDomain.defNamespace].
const List<SettingDomain> kSettingDomains = <SettingDomain>[
  SettingDomain(
    defNamespace: 'app',
    storagePrefix: 'app.',
    editorKeyForm: 'verbatim AppState field name',
    note: 'Full-state snapshot; the only domain the generic toggle/enumPick/'
        'slider renderer can drive.',
  ),
  SettingDomain(
    defNamespace: 'background_playback',
    storagePrefix: 'bg.',
    editorKeyForm: 'bg_*',
    note: 'Def namespace, storage prefix and editor keys deliberately differ: '
        'the `bg.` rows and `set_bg_*` ARB keys predate the feature rename. '
        'Storage stays `bg.` (frozen).',
  ),
  SettingDomain(
    defNamespace: 'breadcrumb',
    storagePrefix: 'app.',
    editorKeyForm: 'breadcrumb_start_side',
    note: 'Value is the AppState breadcrumb field; the entry is a dialog row.',
  ),
  SettingDomain(
    defNamespace: 'browse',
    storagePrefix: 'browse.',
    editorKeyForm: 'browse_media_scope',
  ),
  SettingDomain(
    defNamespace: 'data',
    storagePrefix: null,
    editorKeyForm: 'settings_export / settings_import',
    note: 'Action rows (open a dialog); nothing persisted here.',
  ),
  SettingDomain(
    defNamespace: 'dialring',
    storagePrefix: 'dialring.',
    editorKeyForm: '(AUX only — no catalog defs)',
    note: 'Dial-ring styling rows; edited inside the unified slider-type '
        'dialog, so they have no own def/editor key.',
  ),
  SettingDomain(
    defNamespace: 'form',
    storagePrefix: 'form.',
    editorKeyForm: '(AUX only — no catalog defs)',
    note: 'Remembered geometry of the shared keyboard form (where it sits and '
        'how wide), written by the shell itself; no user-facing editor row.',
  ),
  SettingDomain(
    defNamespace: 'gesture',
    storagePrefix: 'app.',
    editorKeyForm: 'gesture_unified',
    note: 'Value is the AppState gesture-layout/profile field.',
  ),
  SettingDomain(
    defNamespace: 'identity',
    storagePrefix: 'identity.',
    editorKeyForm: 'app_identity_entries',
  ),
  SettingDomain(
    defNamespace: 'keybind',
    storagePrefix: 'keybind.',
    editorKeyForm: 'desktop_keybind_editor',
  ),
  SettingDomain(
    defNamespace: 'legacy',
    storagePrefix: null,
    editorKeyForm: 'legacy_compat',
    note: 'Action row hosting the metadata gate + dual-write switches.',
  ),
  SettingDomain(
    defNamespace: 'osd',
    storagePrefix: 'osd.',
    editorKeyForm: 'osd_*',
  ),
  SettingDomain(
    defNamespace: 'playback',
    storagePrefix: 'playback.',
    editorKeyForm: 'resume_on_startup',
  ),
  SettingDomain(
    defNamespace: 'scan',
    storagePrefix: 'scan.',
    editorKeyForm: 'scan_*',
    note: 'Aux rows written directly via persistAuxRow (no module prefix '
        'constant); `scan.autoCloseDelay` is shared with the scan store.',
  ),
  SettingDomain(
    defNamespace: 'screenshot',
    storagePrefix: 'screenshot.',
    editorKeyForm: 'screenshot_save_path_*',
  ),
  SettingDomain(
    defNamespace: 'security',
    storagePrefix: 'security.',
    editorKeyForm: 'password_transfer_log',
    note: 'Transfer-audit log AUX row (settings_transfer feature).',
  ),
  SettingDomain(
    defNamespace: 'slider',
    storagePrefix: 'slider.',
    editorKeyForm: '(AUX only — no catalog defs)',
    note: 'Sideway-panel anchor/geometry rows; edited live on the panel, so '
        'they have no own def/editor key. Some rows are split per platform '
        '(posH/phonePosH, cornerHideMode/phoneCornerHideMode) so the two '
        'devices never overwrite one another.',
  ),
  SettingDomain(
    defNamespace: 'speed',
    storagePrefix: 'speed.',
    editorKeyForm: 'speed_gesture_mode',
  ),
  SettingDomain(
    defNamespace: 'tagplay',
    storagePrefix: 'tagplay.',
    editorKeyForm: 'tagplay_* / set_tag_play_*',
    note: 'Rows written by TagPlayStore; ARB keys carry the `set_` prefix.',
  ),
  SettingDomain(
    defNamespace: 'video',
    storagePrefix: 'video.',
    editorKeyForm: 'video_*_display_mode',
  ),
  SettingDomain(
    defNamespace: 'virtualmedia',
    storagePrefix: 'virtualmedia.',
    editorKeyForm: 'vm_* / virtual_media_*',
    note: 'Editor keys mix the `vm_` and `virtual_media_` forms.',
  ),
  SettingDomain(
    defNamespace: 'warnings',
    storagePrefix: 'app.',
    editorKeyForm: 'warning_dialog_prefs',
    note: 'Value is the AppState warning-suppression field.',
  ),
  SettingDomain(
    defNamespace: 'window',
    storagePrefix: 'window.',
    editorKeyForm: 'window_* / playlist_* / keep_window_in_bounds',
  ),
];
