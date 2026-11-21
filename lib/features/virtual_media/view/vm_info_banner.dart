import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:iris/features/virtual_media/store/vm_prefs.dart';
import 'package:iris/utils/get_localizations.dart';

/// Dismissible explanation banner for the Virtual Merge UI.
///
/// The hidden state persists across sessions via `virtualmedia.banner.<id>`
/// AUX rows ("可隐藏，长久保存显隐设置"). Hidden banners render nothing.
class VmInfoBanner extends HookWidget {
  const VmInfoBanner({super.key, required this.id, required this.text});

  /// Stable banner identity used for the persisted visibility row.
  final String id;
  final String text;

  @override
  Widget build(BuildContext context) {
    final hidden = useState(true);
    useEffect(() {
      var cancelled = false;
      VmPrefs.bannerHidden(id).then((v) {
        if (!cancelled) hidden.value = v;
      });
      return () => cancelled = true;
    }, [id]);

    if (hidden.value) return const SizedBox.shrink();

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 6, 2, 6),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Icon(Icons.info_outline,
                size: 16,
                color: Theme.of(context).colorScheme.primary),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Text(text, style: Theme.of(context).textTheme.bodySmall),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: getLocalizations(context).vm_banner_dismiss,
            icon: const Icon(Icons.close, size: 16),
            onPressed: () async {
              hidden.value = true;
              await VmPrefs.setBannerHidden(id, true);
            },
          ),
        ],
      ),
    );
  }
}
