import 'package:flutter/material.dart';
import 'package:iris/features/paginated_browser/models/generic_browser_models.dart';

/// Builds the "stay mode" pin [PageAction] used by transient sub-interfaces
/// (scenario preview, media search) to let the user decide whether a
/// tap-play/override-play keeps the current page open (pin) or destroys it.
///
/// The stay flag itself is owned by the caller (persisted for the preview,
/// in-memory for the search page) — this factory only renders the toggle.
PageAction buildStayModePageAction({
  required bool stay,
  required VoidCallback onToggle,
  required String stayLabel,
  required String leaveLabel,
}) {
  return PageAction(
    icon: Icon(stay ? Icons.push_pin : Icons.push_pin_outlined),
    label: stay ? stayLabel : leaveLabel,
    onPressed: onToggle,
  );
}
