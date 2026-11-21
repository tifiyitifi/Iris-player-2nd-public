import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:iris/features/background_playback/services/background_alignment.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/utils/platform.dart';
import 'package:iris/widgets/adaptive/keyboard_form_shell.dart';

/// The manual-switch pick for one tiled VM segment.
class TiledManualPick {
  const TiledManualPick({
    required this.choice,
    required this.percent,
    required this.overshot,
  });

  /// fromHead or percent (no fg restart: the link cannot drive the
  /// foreground runtime from here).
  final BgAlignChoice choice;

  /// The typed share (0..100 after the >100 snap).
  final int percent;

  /// True when the user typed >100 (the field snapped to 100).
  final bool overshot;
}

/// Asks how a MANUAL bg switch should align on the current tiled segment.
///
/// Shown by the VM link when the user swaps the bg track while a
/// wholeVirtual + tiled plan is active. The confirmed pick is recorded as
/// that segment's session-only override ("按弹窗结果记"); a dismissed dialog
/// still keeps the switch itself (aligned from 00:00).
///
/// Deliberately bg-only: unlike the run-first alignment prompt it never
/// pauses the pair and never offers the foreground restart — only the bg
/// offset moves, so playback continues underneath.
///
/// Canonical keyboard shell: the form is built once and cached, keyboard
/// frames only repad via [KeyboardInsetPadder]. Typing never rebuilds the
/// form — the controller owns the text and the radio rows listen to a
/// [ValueNotifier] on the smallest subtree.
Future<TiledManualPick?> showVmTiledManualDialog(
  BuildContext context, {
  void Function()? debugOnFormBuild,
}) {
  return showAdaptiveKeyboardForm<TiledManualPick>(
    context: context,
    form: _TiledManualForm(debugOnFormBuild: debugOnFormBuild),
  );
}

class _TiledManualForm extends StatefulWidget {
  const _TiledManualForm({this.debugOnFormBuild});

  final void Function()? debugOnFormBuild;

  @override
  State<_TiledManualForm> createState() => _TiledManualFormState();
}

class _TiledManualFormState extends State<_TiledManualForm> {
  // Owned by the State (the shell keeps the widget alive through the
  // route's exit transition): never dispose in `whenComplete`.
  late final TextEditingController _pctController = TextEditingController();
  late final ValueNotifier<BgAlignChoice> _selected =
      ValueNotifier(BgAlignChoice.fromHead);
  bool _overshot = false;

  @override
  void dispose() {
    _pctController.dispose();
    _selected.dispose();
    super.dispose();
  }

  void _onPercentChanged(String v) {
    // No setState: the controller owns the text, the radio rows listen to
    // [_selected] only. Per-digit whole-form rebuilds made typing lag.
    final int n = int.tryParse(v) ?? 0;
    if (n > 100) {
      // >100: snap the box back to 100 (the confirm then moves to the NEXT
      // bg file at 00:00).
      _overshot = true;
      _pctController.value = const TextEditingValue(
        text: '100',
        selection: TextSelection.collapsed(offset: 3),
      );
    } else {
      _overshot = false;
    }
    _selected.value = BgAlignChoice.percent;
  }

  void _confirm() {
    Navigator.of(context).pop(
      TiledManualPick(
        choice: _selected.value,
        percent: int.tryParse(_pctController.text) ?? 0,
        overshot: _overshot,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    widget.debugOnFormBuild?.call();
    final t = getLocalizations(context);
    return KeyboardFormScaffold(
      // Built once by [showAdaptiveKeyboardForm]; reads no MediaQuery.
      title: Text(t.bg_tiled_manual_title),
      onClose: () => Navigator.of(context).pop(),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            t.bg_tiled_manual_desc,
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 10),
          ValueListenableBuilder<BgAlignChoice>(
            valueListenable: _selected,
            builder: (context, selected, _) => Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _TiledChoiceRow(
                  selected: selected == BgAlignChoice.fromHead,
                  onTap: () {
                    // A previous >100 entry must not survive a switch back to
                    // "from head", or confirm would jump to the NEXT bg file.
                    _overshot = false;
                    _selected.value = BgAlignChoice.fromHead;
                  },
                  child: Text(t.bg_align_head_option),
                ),
                const SizedBox(height: 6),
                _TiledChoiceRow(
                  selected: selected == BgAlignChoice.percent,
                  onTap: () =>
                      _selected.value = BgAlignChoice.percent,
                  child: _PercentRow(
                    prefix: t.bg_align_percent_prefix,
                    suffix: t.bg_align_percent_suffix,
                    controller: _pctController,
                    onChanged: _onPercentChanged,
                    onFocused: () =>
                        _selected.value = BgAlignChoice.percent,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
      footer: Wrap(
        alignment: WrapAlignment.end,
        spacing: 8,
        runSpacing: 4,
        children: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: Text(t.cancel),
          ),
          FilledButton(
            onPressed: _confirm,
            child: Text(t.ok),
          ),
        ],
      ),
    );
  }
}

/// Percent input row: wide layouts keep prefix + field + suffix on one row;
/// narrow phones (<320 logical px) stack the label above field + suffix so
/// the 56px cell never squeezes under large fonts.
class _PercentRow extends StatelessWidget {
  const _PercentRow({
    required this.prefix,
    required this.suffix,
    required this.controller,
    required this.onChanged,
    required this.onFocused,
  });

  final String prefix;
  final String suffix;
  final TextEditingController controller;
  final ValueChanged<String> onChanged;
  final VoidCallback onFocused;

  Widget _field(bool autofocus) => SizedBox(
        width: 56,
        child: TextField(
          key: const ValueKey('vm_tiled_percent_field'),
          controller: controller,
          autofocus: autofocus,
          keyboardType: TextInputType.number,
          inputFormatters: <TextInputFormatter>[
            FilteringTextInputFormatter.digitsOnly,
          ],
          textAlign: TextAlign.center,
          textInputAction: TextInputAction.done,
          onTap: onFocused,
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onChanged: onChanged,
        ),
      );

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final field = _field(!isMobilePlatform);
        final suffix = Text(this.suffix);
        if (constraints.maxWidth < 320) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(prefix),
              const SizedBox(height: 6),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  field,
                  const SizedBox(width: 4),
                  Flexible(child: suffix),
                ],
              ),
            ],
          );
        }
        return Row(
          children: [
            Flexible(child: Text(prefix)),
            const SizedBox(width: 6),
            field,
            const SizedBox(width: 4),
            Flexible(child: suffix),
          ],
        );
      },
    );
  }
}

/// A radio-style row for the tiled manual dialog (two stacked options).
class _TiledChoiceRow extends StatelessWidget {
  const _TiledChoiceRow({
    required this.selected,
    required this.onTap,
    required this.child,
  });

  final bool selected;
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            Icon(
              selected
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
              size: 20,
              color: Theme.of(context).colorScheme.primary,
            ),
            const SizedBox(width: 8),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
