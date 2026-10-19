import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Architecture fitness test for the 副音 (background playback) subsystem.
///
/// bg always plays REAL single files from a plain list — it must never take
/// part in virtual-merge grouping. This guard is the STRUCTURAL half: the
/// virtual-merge machinery must not be reachable from the bg feature itself.
///
/// The RUNTIME half is `BackgroundTagPool`: 副音's candidate stream is the
/// reserved tag's own `TagViewResolver` resolve with `withVmOverlay: false`, so
/// the shared resolver never folds the members into a merged row. A merged
/// representative's `media` is still a `MediaFile`, so the token scan below
/// alone cannot catch a merge — both halves are required.
void main() {
  test('background_playback never applies virtual-merge rules', () {
    final dir = Directory('lib/features/background_playback');
    expect(dir.existsSync(), isTrue,
        reason: 'run from the project root (flutter test default)');

    // Tokens that would mean the bg side started consuming virtual grouping.
    // `VirtualMediaItem` is deliberately NOT forbidden — the scrubbers read it
    // only to SUPPRESS fg VM decoration while bg is the control target.
    const forbidden = <String>[
      'resolveGroupsForStream',
      'applyVmOverlay',
      'resolveVirtualMedia',
      'VirtualMediaService',
      'VirtualMediaController',
      'VmStreamGroups',
    ];

    final offenders = <String>[];
    for (final entity in dir.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      final src = entity.readAsStringSync();
      for (final token in forbidden) {
        if (src.contains(token)) {
          offenders.add('${entity.path}: $token');
        }
      }
    }

    expect(offenders, isEmpty,
        reason: 'bg queue must stay a plain real-single-file list');
  });
}
