import 'dart:io';

import 'package:flutter/material.dart';
import 'package:iris/models/store/app_state.dart';

final bool isWindows = Platform.isWindows;
final bool isLinux = Platform.isLinux;
final bool isMacOS = Platform.isMacOS;
final bool isAndroid = Platform.isAndroid;
final bool isIOS = Platform.isIOS;

/// Test-only seam: widget tests run on a desktop host, so mobile-gated UI
/// would be unreachable without forcing the flag. Production never writes it;
/// a getter (not a final) so tests can flip it per-case at runtime.
bool? debugIsMobilePlatformOverride;

/// The twin seam for [isDesktop]. A getter rather than a `final` for the same
/// reason as [debugIsMobilePlatformOverride] — but this one exists for the
/// opposite failure: tests run on a desktop host, where `isDesktop` is
/// unconditionally TRUE, so any gate of the form `isDesktop && <something>`
/// passes no matter what the phone half says. Forcing both flags reproduces
/// the real Android/iOS combination (desktop=false, mobile=true), which is
/// the only way a phone-side regression can fail a test instead of hiding
/// behind the runner's own platform.
bool? debugIsDesktopOverride;

bool get isDesktop =>
    debugIsDesktopOverride ??
    (Platform.isWindows || Platform.isLinux || Platform.isMacOS);

bool get isMobilePlatform =>
    debugIsMobilePlatformOverride ?? (isAndroid || isIOS);

bool isLandscapeOrientation({
  required ScreenOrientation runtimeOrientation,
  required Orientation realOrientation,
}) {
  switch (runtimeOrientation) {
    case ScreenOrientation.landscape:
      return true;
    case ScreenOrientation.portrait:
      return false;
    case ScreenOrientation.device:
      return realOrientation == Orientation.landscape;
  }
}
