import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';

void main() {
  test('default extent is 7px within 0-15 range', () {
    expect(kVmTickExtentDefaultPx, 7);
    expect(kVmTickExtentMinPx, 0);
    expect(kVmTickExtentMaxPx, 15);
  });

  test('the double twin tracks the int default', () {
    // Guards the const-widening trick (`/ 1`): the painters and the track-shape
    // defaults read this, so the two must never disagree.
    expect(kVmTickExtentDefault, kVmTickExtentDefaultPx.toDouble());
  });

  test('sanitize clamps to 0-15, garbage degrades to default', () {
    expect(sanitizeVmTickExtentPx(null), kVmTickExtentDefaultPx);
    expect(sanitizeVmTickExtentPx(''), kVmTickExtentDefaultPx);
    expect(sanitizeVmTickExtentPx('garbage'), kVmTickExtentDefaultPx);
    expect(sanitizeVmTickExtentPx('3'), 3);
    expect(sanitizeVmTickExtentPx('0'), 0);
    expect(sanitizeVmTickExtentPx('10'), 10);
    expect(sanitizeVmTickExtentPx('15'), 15);
    expect(sanitizeVmTickExtentPx('-1'), 0);
    expect(sanitizeVmTickExtentPx('99'), 15);
  });

  test('label renders Npx', () {
    expect(vmTickExtentLabel(7), '7px');
    expect(vmTickExtentLabel(0), '0px');
    expect(vmTickExtentLabel(15), '15px');
    expect(vmTickExtentLabel(99), '15px');
  });
}
