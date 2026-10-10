/// Extent plumbing for virtual-media segment boundary ticks.
///
/// Extent = pixels the vertical bar sticks out past the progress axis on
/// EACH side (linear track: `top-extent`, height `+2*extent`; radial arcs:
/// `radius±extent`). 0 means flush with the axis (a 2px line inside the
/// track, never hidden). Pure functions only — persistence lives in
/// AppStore (`markTickExtent`) via the `virtualmedia.markTickExtent` row.
library;

/// Default extent: 7px per side. Deliberately larger than the 3px that shipped
/// first: on the phone dial the tick has to clear the chunk band AND the
/// wayfinding notch to read as a boundary at a glance.
const int kVmTickExtentDefaultPx = 7;

/// [kVmTickExtentDefaultPx] as a double, for `double` painter fields and
/// const constructor defaults. A const default cannot call `.toDouble()`
/// ("methods can't be invoked in constant expressions"), so the widening is
/// spelled as a division — keeping ONE literal behind both constants, which is
/// what stops a painter from drifting back to a hardcoded default.
const double kVmTickExtentDefault = kVmTickExtentDefaultPx / 1;

/// Minimum extent: flush with the axis.
const int kVmTickExtentMinPx = 0;

/// Maximum extent. The upper half of the range is only reachable on the roomy
/// surfaces (desktop circle slider, phone ring dial); on the 4px linear track a
/// large value paints well past the bar, which is the user's call to make.
const int kVmTickExtentMaxPx = 15;

/// Validates a stored `virtualmedia.markTickExtent` row (decimal int
/// string). Out-of-range values clamp; garbage degrades to
/// [kVmTickExtentDefaultPx].
int sanitizeVmTickExtentPx(String? raw) {
  if (raw == null) return kVmTickExtentDefaultPx;
  final v = int.tryParse(raw.trim());
  if (v == null) return kVmTickExtentDefaultPx;
  return v.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx);
}

/// `Npx` label for settings subtitles.
String vmTickExtentLabel(int px) => '${px.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx)}px';
