/// One published file of a GitHub release.
class ReleaseAsset {
  const ReleaseAsset({
    required this.name,
    required this.downloadUrl,
    required this.size,
  });

  /// File name as published, e.g. `IRIS-android-arm64-v8a-v2.0.4.apk`.
  final String name;

  /// Direct download endpoint (GitHub redirects it to a CDN).
  final String downloadUrl;

  /// Size in bytes; the only integrity signal the API offers for free.
  final int size;
}

/// A resolved GitHub release, already narrowed to what the updater needs.
class ReleaseInfo {
  const ReleaseInfo({
    required this.tag,
    required this.version,
    required this.pageUrl,
    required this.notes,
    required this.assets,
    this.publishedAt,
  });

  /// Raw tag, e.g. `v2.0.4` or `2.0.0.local`.
  final String tag;

  /// Tag without the leading `v`.
  final String version;

  /// Human-facing page (`html_url`).
  final String pageUrl;

  /// Release notes, still in the repository's markdown shape.
  final String notes;

  /// Publication timestamp, or null when the payload omitted it.
  final DateTime? publishedAt;

  final List<ReleaseAsset> assets;
}
