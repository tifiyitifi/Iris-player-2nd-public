import 'dart:io';
import 'package:device_info_plus/device_info_plus.dart';
import 'package:iris/globals.dart' as globals;
import 'package:permission_handler/permission_handler.dart';

/// Whether the Android storage permission is currently known to be granted.
///
/// Non-Android platforms always answer true (the gate only exists on Android),
/// so a caller may use this unconditionally.
bool storagePermissionGranted() {
  if (!Platform.isAndroid) return true;
  return globals.storagePermissionStatus == PermissionStatus.granted;
}

/// Records that the OS refused a local read even though the cached status said
/// "granted" (or was still unknown).
///
/// Trusting the OS over the cache is what makes the file browser switch to the
/// grant surface instead of rendering a blank folder. Android-only: on desktop
/// EACCES means a genuinely unreadable path, which must keep its own error.
void markStoragePermissionDenied() {
  if (!Platform.isAndroid) return;
  globals.storagePermissionStatus = PermissionStatus.denied;
}

Future<void> requestStoragePermission() async {
  if (!Platform.isAndroid) {
    return;
  }

  if (globals.storagePermissionStatus == PermissionStatus.granted) return;

  if (await isAndroid11OrHigher()) {
    final status = await Permission.manageExternalStorage.request();
    globals.storagePermissionStatus = status;
    if (status.isPermanentlyDenied) return;
  } else {
    final status = await Permission.storage.request();
    globals.storagePermissionStatus = status;
    if (status.isPermanentlyDenied) return;
  }
}

Future<bool> isAndroid11OrHigher() async {
  DeviceInfoPlugin deviceInfo = DeviceInfoPlugin();
  AndroidDeviceInfo androidInfo = await deviceInfo.androidInfo;
  return androidInfo.version.sdkInt >= 30;
}
