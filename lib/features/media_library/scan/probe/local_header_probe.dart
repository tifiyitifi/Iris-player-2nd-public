import 'package:iris/features/media_library/scan/probe/amr_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/avi_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/flac_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/media_probe.dart';
import 'package:iris/features/media_library/scan/probe/mkv_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/mp3_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/mp4_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/ogg_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/silk_header_probe.dart';
import 'package:iris/features/media_library/scan/probe/wav_header_probe.dart';

/// Container-header dispatch for LOCAL files.
///
/// Every supported container answers duration + frame size from a few hundred
/// bytes of header, which is what makes "play in a couple of seconds with a
/// duration-ordered queue" possible. Formats without a parser here (or files
/// whose header is unreadable) return null, and the caller falls back to the
/// much slower platform probe.
///
/// The audio formats are here for a measured reason: a 2019 phone library was
/// 19,688 mp3 + 496 amr + 551 mp4, and an audio-less dispatcher sent 94% of it
/// to `MediaMetadataRetriever` at 14–28 ms per file — far more than the metadata
/// wait budget, so music never got durations and duration ordering was useless
/// for it.
abstract final class LocalHeaderProbe {
  /// Whether [path] names a container this dispatcher can attempt.
  ///
  /// Cheap and extension-only by design: the parsers themselves validate the
  /// structure, so a mislabelled `.mkv` still falls back on their null return.
  static bool supportsPath(String path) =>
      Mp4HeaderProbe.isMp4Path(path) ||
      MkvHeaderProbe.isMkvPath(path) ||
      AviHeaderProbe.isAviPath(path) ||
      Mp3HeaderProbe.isMp3Path(path) ||
      FlacHeaderProbe.isFlacPath(path) ||
      WavHeaderProbe.isWavPath(path) ||
      OggHeaderProbe.isOggPath(path) ||
      SilkHeaderProbe.isSilkPath(path) ||
      AmrHeaderProbe.isAmrPath(path);

  /// Never throws; null means "not resolvable from the header".
  static ProbeResult? tryReadSync(String path) {
    if (Mp4HeaderProbe.isMp4Path(path)) return Mp4HeaderProbe.tryReadSync(path);
    if (MkvHeaderProbe.isMkvPath(path)) return MkvHeaderProbe.tryReadSync(path);
    if (AviHeaderProbe.isAviPath(path)) return AviHeaderProbe.tryReadSync(path);
    if (Mp3HeaderProbe.isMp3Path(path)) return Mp3HeaderProbe.tryReadSync(path);
    if (FlacHeaderProbe.isFlacPath(path)) {
      return FlacHeaderProbe.tryReadSync(path);
    }
    if (WavHeaderProbe.isWavPath(path)) return WavHeaderProbe.tryReadSync(path);
    if (OggHeaderProbe.isOggPath(path)) return OggHeaderProbe.tryReadSync(path);
    // `.amr` is ambiguous in the wild: WeChat records SILK v3 under that
    // extension, so try the container magic before the AMR frame walk.
    if (SilkHeaderProbe.isSilkPath(path)) {
      final silk = SilkHeaderProbe.tryReadSync(path);
      if (silk != null) return silk;
    }
    if (AmrHeaderProbe.isAmrPath(path)) return AmrHeaderProbe.tryReadSync(path);
    return null;
  }
}
