/// Which `parent_path` groups a natural-order keyset page may return.
///
/// Only meaningful for the grouped (同目录连续) walk. `nonNull` / `nullOnly`
/// exist so a DESCENDING walk can split "every parent path at or below the
/// cursor" (a seekable index range) from "the trailing NULL group": keeping
/// both in one query hides the range bound behind an `OR`, which makes SQLite
/// rescan the index from the start for every page.
enum KeysetParentScope {
  /// Both the NULL group and real parent paths (ASC default).
  any,

  /// Only rows with a non-null `parent_path`.
  nonNull,

  /// Only the trailing NULL parent group (storage-root files).
  nullOnly,
}
