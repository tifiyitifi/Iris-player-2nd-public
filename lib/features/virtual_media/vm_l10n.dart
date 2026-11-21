import 'package:flutter/widgets.dart';
import 'package:iris/l10n/app_localizations.dart';
import 'package:iris/l10n/app_localizations_en.dart';
import 'package:iris/l10n/app_localizations_zh.dart';
import 'package:iris/store/use_app_store.dart';

/// Context-free localization for Virtual Merge code that runs OUTSIDE a widget
/// build: the merge resolvers (display titles) and the playback controller's
/// fatal-error path. Prefers the app's selected language, then the platform
/// locale, then English. Only `en`/`zh` are shipped (matching
/// `AppLocalizations.supportedLocales`), so constructing the generated
/// instance directly is exact — and safe when no binding is initialized.
AppLocalizations vmLocalizations() {
  try {
    var code = useAppStore().state.language;
    if (code.isEmpty || code == 'system' || code == 'auto') {
      code = WidgetsBinding.instance.platformDispatcher.locale.languageCode;
    }
    return code.toLowerCase().startsWith('zh')
        ? AppLocalizationsZh()
        : AppLocalizationsEn();
  } catch (_) {
    return AppLocalizationsEn();
  }
}
