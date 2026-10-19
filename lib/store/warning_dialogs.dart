/// Warning-dialog registry: suppressible ids + the single decision function.
///
/// Two strict classes (capability_matrix §6):
///  - SUPPRESSIBLE — recoverable/low-stakes confirmations; once an id is in
///    `AppState.suppressedWarnings` the dialog auto-confirms silently.
///  - ALWAYS-ON — destructive/irreversible/error dialogs that never consult
///    this list (permanent-delete, playback errors, the version-changed
///    prompt). They are intentionally absent from the settings panel.
///
/// The one override-related exception is [kWarningScenarioBrowsePlayOverride]:
/// the scenario browse page's Play action is repeatable, so its override
/// confirmation ships suppressible (box ticked by default).
const String kWarningPhysicalDeleteRecycle = 'physicalDeleteRecycle';
const String kWarningForceAppendNoMedia = 'forceAppendNoMedia';
const String kWarningGestureEditCancel = 'gestureEditCancel';
const String kWarningGestureEditReset = 'gestureEditReset';
const String kWarningGestureEditConfirm = 'gestureEditConfirm';

/// Informational notice shown the first time 副音 takes the shared controls:
/// explains that a blue frame means the bar now drives the other runtime.
const String kWarningBgAutoControl = 'bgAutoControl';

/// Confirms exiting the align editor without saving the adjusted A–B window.
const String kWarningBgAlignExitDiscard = 'bgAlignExitDiscard';

/// Explains, the first time, that "save as silent" stores the span with NO
/// Sub Audio file (distinct from setting the Sub Audio share to 0%).
const String kWarningBgAlignSilenceNoFile = 'bgAlignSilenceNoFile';

/// Explains the A<P<B rule behind the align editor's "move A/P/B to the current
/// position" buttons (which two points are movable depends on the playhead's
/// side of the centre).
const String kWarningBgAlignMovePointHint = 'bgAlignMovePointHint';

/// Inline caption under the 对齐 editor's percent slider: tune first, then
/// pick the percent mode. Dismissible/restorable from the settings panel.
const String kWarningBgAlignPercentHint = 'bgAlignPercentHint';

/// Full first-use explanation of the align editor's snap-to-saved-boundary
/// (卡值） mode, shown when the snap toggle is first enabled. Recoverable —
/// the switch and the settings rows stay available, so the notice can be
/// turned off (and restored from the settings panel).
const String kWarningBgAlignSnapGuide = 'bgAlignSnapGuide';

/// Short notice shown when snap is enabled but no usable saved boundaries
/// exist in view. Recoverable like [kWarningBgAlignSnapGuide].
const String kWarningBgAlignSnapNone = 'bgAlignSnapNone';

/// Asks before opening the 对齐 editor when the playhead sits FAR outside the
/// saved segment's APB window: confirming jumps playback back to A. Recoverable
/// — once suppressed the editor always jumps without asking, and the settings
/// panel can restore the prompt.
const String kWarningBgAlignForceSeek = 'bgAlignForceSeek';

/// Explains, when a 副音 file ends before the (single) foreground video, how the
/// 副音 list was walked as a looping timeline and where playback now continues.
/// Recoverable — the 副音 exhausted setting stays available either way.
const String kWarningBgContinuation = 'bgContinuation';

/// Asks before binding a WebDAV entry to a host already used by another
/// same-account entry (a recoverable choice — the user may want the same
/// machine for two independent subtrees).
const String kWarningWebdavSharedHost = 'webdavSharedHost';

/// Explains, the first time, that dropped files/directories outside the
/// current browse media scope were ignored (e.g. audio dropped while the
/// scope is video-only). Recoverable — the scope is a display preference, so
/// the notice can be turned off (and restored from the settings panel).
const String kWarningDragDropScopeRestricted = 'dragDropScopeRestricted';

/// First-use explainer of the scenario "workspace" model: playing a folder /
/// multi-selection / library REPLACES the live Playing workspace, while saved
/// scenarios are plans that must be loaded via Override / Append. Recoverable —
/// the feature stays fully usable either way.
const String kWarningScenarioWorkspace = 'scenarioWorkspace';

/// Confirm shown by the scenario browse page's Play action before it replaces
/// the current playing workspace with the browsed scenario. Repeatable, so the
/// "don't show again" box defaults TICKED; restore the prompt from Settings →
/// Warning dialogs.
const String kWarningScenarioBrowsePlayOverride = 'scenarioBrowsePlayOverride';

/// First-use explainer of the Tag numeric command grammar (`+n` / `-n` / `*n`)
/// shown before the Tag sheet opens. Recoverable — the sheet explains again.
const String kWarningTagCommandGrammar = 'tagCommandGrammar';

/// First-use explainer of Virtual Media: consecutive videos are merged into a
/// single virtual timeline at playback time; disk files are never modified.
/// Recoverable — rule CRUD stays available either way.
const String kWarningVmMergeConcept = 'vmMergeConcept';

/// First-launch overview of what makes IRIS different from a plain player.
/// Restorable from Settings → About → "IRIS feature guide".
const String kWarningAppOverview = 'appOverview';

/// Every id the settings panel offers a toggle for, in display order.
const List<String> kSuppressibleWarningIds = <String>[
  kWarningPhysicalDeleteRecycle,
  kWarningForceAppendNoMedia,
  kWarningGestureEditCancel,
  kWarningGestureEditReset,
  kWarningGestureEditConfirm,
  kWarningBgAutoControl,
  kWarningBgAlignExitDiscard,
  kWarningBgAlignSilenceNoFile,
  kWarningBgAlignMovePointHint,
  kWarningBgAlignPercentHint,
  kWarningBgAlignSnapGuide,
  kWarningBgAlignSnapNone,
  kWarningBgAlignForceSeek,
  kWarningBgContinuation,
  kWarningWebdavSharedHost,
  kWarningDragDropScopeRestricted,
  kWarningScenarioWorkspace,
  kWarningScenarioBrowsePlayOverride,
  kWarningTagCommandGrammar,
  kWarningVmMergeConcept,
  kWarningAppOverview,
];

bool shouldShowWarning(List<String> suppressedWarnings, String id) =>
    !suppressedWarnings.contains(id);
