import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/osd/engine/osd_texts.dart';
import 'package:iris/l10n/app_localizations.dart';

/// fg/bg control-target OSD (Alt+;): one line naming the resulting target, and
/// the "not running" hint when the shortcut is inert.
void main() {
  test('controlTarget names the resulting side', () async {
    final t = await lookupAppLocalizations(const Locale('en'));

    expect(OsdTexts.controlTarget(true, t).line1, t.osd_control_bg);
    expect(OsdTexts.controlTarget(false, t).line1, t.osd_control_fg);
  });

  test('controlTargetUnavailable says 副音 is not running', () async {
    final t = await lookupAppLocalizations(const Locale('en'));

    expect(
      OsdTexts.controlTargetUnavailable(t).line1,
      t.osd_control_unavailable,
    );
  });
}
