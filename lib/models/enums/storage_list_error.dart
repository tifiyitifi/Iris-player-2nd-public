/// Why a storage directory listing failed.
///
/// Introduced because the WebDAV listing used to swallow every exception and
/// return an empty list, which the UI rendered as "no items found" — hiding
/// whether the host was unreachable, the credentials were rejected, or the
/// platform blocked plaintext HTTP.
enum StorageListErrorKind {
  /// The host could not be reached (DNS / socket / no route to host).
  unreachable,

  /// The server answered but rejected the credentials (401/403).
  unauthorized,

  /// The connection was accepted but no response arrived in time.
  timeout,

  /// The platform refused plaintext HTTP (Android/iOS cleartext policy).
  httpBlocked,

  /// The operating system denied access to the directory (EACCES / EPERM), or
  /// a SAF tree grant was revoked. The UI must offer the storage-permission
  /// grant — WITHOUT this classification a denied listing looked exactly like
  /// an empty folder, so the phone neither explained nor asked for permission.
  permissionDenied,

  /// Anything not otherwise classified.
  unknown,
}
