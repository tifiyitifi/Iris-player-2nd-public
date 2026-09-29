import 'package:flutter/material.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/models/store/app_state.dart';
import 'package:iris/models/store/phone_landscape_slider_type_helper.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';

Future<void> showPhoneLandscapeUseModeDialog(BuildContext context) => showDialog<void>(
      context: context,
      builder: (BuildContext context) => const PhoneLandscapeUseModeDialog(),
    );

class PhoneLandscapeUseModeDialog extends HookWidget {
  const PhoneLandscapeUseModeDialog({super.key});

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final PhoneLandscapeUseMode selected =
        useAppStore().select(context, (state) => state.phoneLandscapeUseMode);
    String labelOf(PhoneLandscapeUseMode m) => switch (m) {
          PhoneLandscapeUseMode.normal => t.phone_mode_normal,
          PhoneLandscapeUseMode.rightSide => t.phone_mode_right,
          PhoneLandscapeUseMode.leftSide => t.phone_mode_left,
          // Parse-only members: the loader folds them into their `*Side`
          // replacements, so they can never reach the picker — but the switch
          // must stay exhaustive, hence this unreachable arm.
          PhoneLandscapeUseMode.rightHanded => t.phone_mode_right,
          PhoneLandscapeUseMode.leftHanded => t.phone_mode_left,
        };

    void selectMode(PhoneLandscapeUseMode? value) {
      if (value == null) return;
      useAppStore().updatePhoneLandscapeUseMode(value);
      Navigator.pop(context);
    }

    return AlertDialog(
      title: Text(t.set_phone_landscape_controls),
      content: RadioGroup<PhoneLandscapeUseMode>(
        groupValue: selected,
        onChanged: selectMode,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          // Only the live modes: listing `.values` also offered the deprecated
          // rightHanded/leftHanded, which rendered as duplicate label pairs and
          // let the user persist a value the loader has to migrate away.
          children: kLivePhoneLandscapeUseModes
              .map(
                (PhoneLandscapeUseMode value) => ListTile(
                  title: Text(labelOf(value)),
                  leading: Radio<PhoneLandscapeUseMode>(value: value),
                  onTap: () => selectMode(value),
                ),
              )
              .toList(),
        ),
      ),
    );
  }
}
