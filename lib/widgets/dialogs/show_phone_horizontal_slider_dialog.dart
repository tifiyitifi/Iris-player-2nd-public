import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';

Future<void> showPhoneLandScapeSliderDialog(BuildContext context) async => await showDialog<void>(
      context: context,
      builder: (context) => const PhoneLandscapeSliderDialog(),
    );

/// Meta-settings slider-type picker.
///
/// The legacy `circleRight / circleLeft` placement options are folded into the
/// one-handed right/left side choices: picking a side writes BOTH the
/// one-handed mode AND the matching classic circle placement, so the oldest
/// circle slider gets one-handed options on every platform.
class PhoneLandscapeSliderDialog extends HookWidget {
  const PhoneLandscapeSliderDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final mode = useAppStore().select(context, (state) => state.phoneLandscapeUseMode);
    final selected = metaSliderTypeOption(mode);

    void update(MetaSliderTypeOption? option) {
      if (option == null) return;
      final store = useAppStore();
      // One call: the store derives the paired legacy circle placement from the
      // mode, so the two fields cannot drift apart here.
      store.updatePhoneLandscapeUseMode(switch (option) {
        MetaSliderTypeOption.normal => PhoneLandscapeUseMode.normal,
        MetaSliderTypeOption.rightSide => PhoneLandscapeUseMode.rightSide,
        MetaSliderTypeOption.leftSide => PhoneLandscapeUseMode.leftSide,
      });
      Navigator.pop(context);
    }

    return AlertDialog(
      title: Text(t.phone_slider_title),
      content: SingleChildScrollView(
        child: RadioGroup<MetaSliderTypeOption>(
          groupValue: selected,
          onChanged: update,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: MetaSliderTypeOption.values.map((e) {
              return ListTile(
                title: Text(metaSliderTypeLabel(e, t)),
                leading: Radio<MetaSliderTypeOption>(
                  value: e,
                ),
                onTap: () => update(e),
              );
            }).toList(),
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text(t.phone_slider_close),
        ),
      ],
    );
  }
}