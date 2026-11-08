import 'package:flutter_test/flutter_test.dart';
import 'package:iris/features/meta_settings/contributions/settings_catalog.dart';
import 'package:iris/features/meta_settings/model/enum/setting_widget_kind.dart';
import 'package:iris/features/meta_settings/view/widgets/editor_bindings.dart';
import 'package:iris/features/meta_settings/view/widgets/setting_editors.dart';

void main() {
  final defs = SettingsCatalog.defs;

  test('scan auto-close preference is contributed as a real value row', () {
    final scan = defs.singleWhere((d) => d.key == 'scan.autoCloseDelay');
    expect(scan.widgetKind, SettingWidgetKind.custom);
  });

  test('scan completion-prompt switch is contributed as a custom row', () {
    final prompt = defs.singleWhere((d) => d.key == 'scan.autoClosePrompt');
    expect(prompt.widgetKind, SettingWidgetKind.custom,
        reason: 'the value lives in the scan store, not the app.* snapshot');
    expect(prompt.editorKey, 'scan_auto_close_prompt');
  });

  test('every custom/slider def has a registered editor builder', () {
    EditorBindings.ensureRegistered();
    final unbound = defs
        .where((d) =>
            d.widgetKind == SettingWidgetKind.custom ||
            d.widgetKind == SettingWidgetKind.slider)
        .where((d) => SettingEditors.lookup(d.editorKey) == null)
        .map((d) => d.key)
        .toList();
    expect(
      unbound,
      isEmpty,
      reason: 'unbound rows fall back to inert placeholder tiles',
    );
  });
}
