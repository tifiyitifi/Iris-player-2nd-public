import 'package:flutter/material.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/background_playback/hooks/use_background_volume_context.dart';
import 'package:iris/features/background_playback/store/use_background_playback_store.dart';

/// The 作用范围 identity of the media playing now.
///
/// Normally the physical foreground file, but while a Virtual Merge session
/// runs under `wholeVirtual` the VM link publishes the whole virtual video's
/// identity instead (see `vmScopeIdentityOverride`). Scope observers — the
/// runtime scope, the apply-to-current toggle — read THIS, so "treat the
/// virtual video as one video" holds everywhere the scope matters.
///
/// Deliberately NOT used for the volume ratio: each physical block keeps its
/// own saved pair.
String? useForegroundScopeKey(BuildContext context) {
  // Unconditional hook order: the physical key is always read (it is the
  // fallback), then the override is layered on top.
  final physical = useForegroundRatioKey(context);
  final override = useBackgroundPlaybackStore()
      .select(context, (s) => s.vmScopeKeyOverride);
  if (override != null && override.isNotEmpty) return override;
  return physical;
}
