import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_hooks/flutter_hooks.dart';
import 'package:flutter_zustand/flutter_zustand.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_color.dart';
import 'package:iris/features/virtual_media/rule/vm_tick_extent.dart';
import 'package:iris/store/use_app_store.dart';
import 'package:iris/utils/get_localizations.dart';
import 'package:iris/widgets/adaptive/keyboard_inset_padder.dart';

/// Color + length editor for the virtual-media segment boundary ticks
/// (`virtualmedia.markTickColor` + schemaless `virtualmedia.markTickExtent`).
///
/// Sections: industry-recommended default (opaque white, pinned first with a
/// rationale) → preset palette → hand-rolled hue ring + SV plane (zero new
/// dependencies; alpha locked at FF, translucent ticks vanish on the axis) →
/// manual RGB (`0-255` triple + `#RRGGBB` text, invalid input degrades to an
/// explanatory dialog, never a SnackBar) → length slider (0-15px) + numeric
/// field. Selection applies live through the AppStore updaters; the sheet
/// stays open for comparison and closes via the Close action.
///
/// Keyboard structure mirrors `vm_rule_editor_v2.dart`: the heavy form is
/// built EXACTLY ONCE and cached in shell state, while keyboard height is
/// consumed by ONE AnimatedPadding in the shell — keyboard frames move
/// pixels without rebuilding a single field. When any text input holds
/// focus, the title header + preview fold away to free vertical space on
/// 360px phones; they restore on blur.
Future<void> showVmMarkColorDialog(BuildContext context) {
  final w = MediaQuery.sizeOf(context).width;
  if (w < 600) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => const _VmTickSheet(),
    );
  }
  return showDialog<void>(
    context: context,
    builder: (_) => const _VmTickDialog(),
  );
}

/// Centered-dialog shell for wide screens (desktop / tablet landscape).
class _VmTickDialog extends StatefulWidget {
  const _VmTickDialog();

  @override
  State<_VmTickDialog> createState() => _VmTickDialogState();
}

class _VmTickDialogState extends State<_VmTickDialog> {
  late final Widget _form = const _VmTickForm();

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      insetPadding:
          const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      child: ConstrainedBox(
        constraints: BoxConstraints(
          maxWidth: 560,
          maxHeight: size.height * 0.92,
        ),
        child: KeyboardInsetPadder(child: _form),
      ),
    );
  }
}

/// Bottom-sheet shell for phones: fixed-height sheet, keyboard avoidance is
/// the single [KeyboardInsetPadder] — no DraggableScrollableSheet (it
/// re-resolves extent + rebuilds content on every keyboard frame).
class _VmTickSheet extends StatefulWidget {
  const _VmTickSheet();

  @override
  State<_VmTickSheet> createState() => _VmTickSheetState();
}

class _VmTickSheetState extends State<_VmTickSheet> {
  late final Widget _form = const _VmTickForm(fillViewport: true);

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height;
    return KeyboardInsetPadder(
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: height * 0.92),
        child: _form,
      ),
    );
  }
}

/// Shared editor form (sticky header / scrollable fields / sticky footer).
/// Built once per shell — reads NO MediaQuery: width branching via
/// LayoutBuilder, theme via Theme (stable across keyboard frames).
class _VmTickForm extends HookWidget {
  const _VmTickForm({this.fillViewport = false});

  /// True inside the bottom-sheet shell (fill the sheet); false inside the
  /// dialog shell (shrink to content).
  final bool fillViewport;

  /// Test seam: counts form rebuilds to prove keyboard frames don't re-run
  /// the form. Null in prod.
  static void Function()? debugOnFormBuild;

  @override
  Widget build(BuildContext context) {
    debugOnFormBuild?.call();
    final t = getLocalizations(context);
    final current = useAppStore().select(context, (s) => s.vmMarkTickColor);
    final extent = useAppStore().select(context, (s) => s.vmMarkTickExtent);

    // Any text input focused → fold the title header + preview away so the
    // focused field keeps maximum vertical space on phones.
    final hideChrome = useState(false);
    final rNode = useFocusNode();
    final gNode = useFocusNode();
    final bNode = useFocusNode();
    final hexNode = useFocusNode();
    final extNode = useFocusNode();
    useEffect(() {
      void onFocus() {
        final any = rNode.hasFocus ||
            gNode.hasFocus ||
            bNode.hasFocus ||
            hexNode.hasFocus ||
            extNode.hasFocus;
        if (hideChrome.value != any) hideChrome.value = any;
        final node = rNode.hasFocus
            ? rNode
            : gNode.hasFocus
                ? gNode
                : bNode.hasFocus
                    ? bNode
                    : hexNode.hasFocus
                        ? hexNode
                        : extNode;
        if (any) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (node.context != null) {
              Scrollable.ensureVisible(node.context!,
                  duration: const Duration(milliseconds: 200));
            }
          });
        }
      }

      for (final n in [rNode, gNode, bNode, hexNode, extNode]) {
        n.addListener(onFocus);
      }
      return () {
        for (final n in [rNode, gNode, bNode, hexNode, extNode]) {
          n.removeListener(onFocus);
        }
      };
    }, [rNode, gNode, bNode, hexNode, extNode]);

    Future<void> resetDefaults() async {
      final store = useAppStore();
      await store.updateVmMarkTickColor(kVmTickColorDefaultArgb);
      await store.updateVmMarkTickExtent(kVmTickExtentDefaultPx);
    }

    return Column(
      mainAxisSize: fillViewport ? MainAxisSize.max : MainAxisSize.min,
      children: [
        if (!hideChrome.value) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 8, 0),
            child: Row(
              children: [
                Expanded(child: Text(t.vm_color_title)),
                IconButton(
                  icon: const Icon(Icons.close),
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
        ],
        Flexible(
          child: SingleChildScrollView(
            keyboardDismissBehavior:
                ScrollViewKeyboardDismissBehavior.onDrag,
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
            child: LayoutBuilder(builder: (context, constraints) {
              return Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (!hideChrome.value) ...[
                    _PreviewTrack(
                        key: const ValueKey('vmTickPreview'),
                        color: Color(current),
                        extent: extent),
                    const SizedBox(height: 4),
                    Text(
                      '${vmTickColorLabel(current)} · ${vmTickExtentLabel(extent)}',
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(
                            color: Theme.of(context)
                                .colorScheme
                                .onSurfaceVariant,
                          ),
                    ),
                    const SizedBox(height: 4),
                  ],
                  _tickLabel(context, t.vm_color_section_recommended),
                  _RecommendTile(
                    selected: current == kVmTickColorDefaultArgb,
                    onTap: () => useAppStore()
                        .updateVmMarkTickColor(kVmTickColorDefaultArgb),
                  ),
                  _tickLabel(context, t.vm_color_section_presets),
                  Wrap(
                    spacing: 12,
                    runSpacing: 12,
                    children: [
                      for (final preset in kVmTickColorPresets)
                        if (preset != kVmTickColorDefaultArgb)
                          _Swatch(
                            key: ValueKey('vmTickSwatch_$preset'),
                            color: Color(preset),
                            selected: preset == current,
                            onTap: () => useAppStore()
                                .updateVmMarkTickColor(preset),
                          ),
                    ],
                  ),
                  _tickLabel(context, t.vm_color_section_hue),
                  _HueRing(current: current),
                  _tickLabel(context, t.vm_color_section_rgb),
                  _RgbInputs(
                    current: current,
                    rNode: rNode,
                    gNode: gNode,
                    bNode: bNode,
                    hexNode: hexNode,
                  ),
                  _tickLabel(context, t.vm_color_section_extent),
                  _ExtentInputs(
                    extent: extent,
                    focusNode: extNode,
                  ),
                ],
              );
            }),
          ),
        ),
        const Divider(height: 1),
        // Fixed footer padding: keyboard avoidance lives in the shell's
        // [KeyboardInsetPadder]. Reading viewInsets here would rebuild the
        // whole form on every keyboard frame.
        Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
          child: Row(
            children: [
              Expanded(
                child: OutlinedButton(
                  key: const ValueKey('vmTickReset'),
                  onPressed: resetDefaults,
                  child: Text(t.vm_color_reset),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: FilledButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(t.vm_color_close),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

Widget _tickLabel(BuildContext context, String text) => Padding(
      padding: const EdgeInsets.only(top: 14, bottom: 4),
      child: Text(text, style: Theme.of(context).textTheme.titleSmall),
    );

/// Pinned industry recommendation: opaque white. The rationale line explains
/// WHY so users stop second-guessing it.
class _RecommendTile extends StatelessWidget {
  const _RecommendTile({required this.selected, required this.onTap});

  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      key: const ValueKey('vmTickSwatch_4294967295'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 2 : 1,
          ),
        ),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                color: Colors.white,
              ),
              child: selected
                  ? const Icon(Icons.check_rounded,
                      color: Colors.black, size: 20)
                  : null,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Text(t.vm_color_pure_white),
                      const SizedBox(width: 6),
                      Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: scheme.primaryContainer,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(t.vm_color_recommended_badge,
                            style: Theme.of(context)
                                .textTheme
                                .labelSmall
                                ?.copyWith(
                                    color:
                                        scheme.onPrimaryContainer)),
                      ),
                    ],
                  ),
                  Text(t.vm_color_recommended_desc,
                      style: Theme.of(context)
                          .textTheme
                          .bodySmall
                          ?.copyWith(color: scheme.onSurfaceVariant)),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Mock progress axis with extent-aware vertical ticks — the same geometry
/// the player sliders paint (thin bars sticking out `extent` per side).
class _PreviewTrack extends StatelessWidget {
  const _PreviewTrack(
      {super.key, required this.color, required this.extent});

  final Color color;
  final int extent;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final e = extent.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx).toDouble();
    return SizedBox(
      height: 16 + 2 * e,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Container(
            height: 4,
            decoration: BoxDecoration(
              color: scheme.onSurface.withValues(alpha: 0.25),
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          for (final f in const [0.25, 0.5, 0.75])
            Positioned.fill(
              child: Align(
                alignment: Alignment(f * 2 - 1, 0),
                child: Container(
                    width: 2, height: 4 + 2 * e, color: color),
              ),
            ),
        ],
      ),
    );
  }
}

class _Swatch extends StatelessWidget {
  const _Swatch({
    super.key,
    required this.color,
    required this.selected,
    required this.onTap,
  });

  final Color color;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: color,
          border: Border.all(
            color: selected ? scheme.primary : scheme.outline,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected
            ? Icon(Icons.check_rounded,
                color: color.computeLuminance() > 0.5
                    ? Colors.black
                    : Colors.white)
            : null,
      ),
    );
  }
}

/// Hand-rolled hue slider + saturation/value plane (no new dependencies).
/// Alpha is locked at FF — every emitted color is `| 0xFF000000`.
///
/// Drag economics: slider/plane gestures preview LOCALLY and persist once on
/// release (`onChangeEnd`/`onPanEnd`). The store (Drift on the UI isolate)
/// must not see dozens of writes per second of dragging.
class _HueRing extends HookWidget {
  const _HueRing({required this.current});

  final int current;

  static int _argb(double h, double s, double v) =>
      HSVColor.fromAHSV(1.0, h, s, v).toColor().toARGB32() | 0xFF000000;

  @override
  Widget build(BuildContext context) {
    final preview = useState<HSVColor?>(null);
    final hsv = preview.value ?? HSVColor.fromColor(Color(current));
    // A persisted `current` arriving mid-drag loses to the live preview;
    // clearing on change-end re-syncs to the store value.
    void previewApply(double h, double s, double v) {
      preview.value = HSVColor.fromAHSV(1.0, h, s, v);
    }

    void commitApply(double h, double s, double v) {
      preview.value = null;
      useAppStore().updateVmMarkTickColor(_argb(h, s, v));
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            Expanded(
              child: Slider(
                key: const ValueKey('vmTickHueSlider'),
                value: hsv.hue,
                min: 0,
                max: 360,
                label: '${hsv.hue.round()}°',
                onChanged: (h) =>
                    previewApply(h, hsv.saturation, hsv.value),
                onChangeEnd: (h) =>
                    commitApply(h, hsv.saturation, hsv.value),
              ),
            ),
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Color(preview.value == null
                    ? current
                    : _argb(hsv.hue, hsv.saturation, hsv.value)),
                border: Border.all(
                    color: Theme.of(context).colorScheme.outline),
              ),
            ),
          ],
        ),
        _SvPlane(
          hsv: hsv,
          apply: previewApply,
          commit: commitApply,
        ),
      ],
    );
  }
}

/// Saturation/value plane. Own widget so touch coordinates resolve against
/// the plane's own box (via LayoutBuilder constraints, never a parent
/// Column's size).
class _SvPlane extends StatelessWidget {
  const _SvPlane({required this.hsv, required this.apply, required this.commit});

  final HSVColor hsv;
  final void Function(double h, double s, double v) apply;
  final void Function(double h, double s, double v) commit;

  static const double kHeight = 120;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(builder: (context, constraints) {
      final w = constraints.maxWidth;
      void fromLocal(Offset p, {required bool end}) {
        if (w <= 0) return;
        final s = (p.dx / w).clamp(0.0, 1.0).toDouble();
        final v =
            (1 - p.dy / kHeight).clamp(0.0, 1.0).toDouble();
        if (end) {
          commit(hsv.hue, s, v);
        } else {
          apply(hsv.hue, s, v);
        }
      }

      return GestureDetector(
        key: const ValueKey('vmTickSvPlane'),
        // Discrete taps persist immediately (single write); pans preview
        // per move and persist once on lift.
        onTapDown: (d) => fromLocal(d.localPosition, end: true),
        onPanUpdate: (d) => fromLocal(d.localPosition, end: false),
        onPanEnd: (_) => commit(hsv.hue, hsv.saturation, hsv.value),
        child: CustomPaint(
          painter: _SvPainter(hue: hsv.hue),
          foregroundPainter:
              _SvThumbPainter(s: hsv.saturation, v: hsv.value),
          child: const SizedBox(
            height: kHeight,
            width: double.infinity,
          ),
        ),
      );
    });
  }
}

class _SvPainter extends CustomPainter {
  const _SvPainter({required this.hue});

  final double hue;

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.drawRect(
        rect, Paint()..color = HSVColor.fromAHSV(1, hue, 1, 1).toColor());
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          colors: [Colors.white, Colors.transparent],
        ).createShader(rect),
    );
    canvas.drawRect(
      rect,
      Paint()
        ..shader = const LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.transparent, Colors.black],
        ).createShader(rect),
    );
  }

  @override
  bool shouldRepaint(_SvPainter old) => old.hue != hue;
}

class _SvThumbPainter extends CustomPainter {
  const _SvThumbPainter({required this.s, required this.v});

  final double s;
  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    final p = Offset(s * size.width, (1 - v) * size.height);
    canvas.drawCircle(
        p,
        9,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2);
  }

  @override
  bool shouldRepaint(_SvThumbPainter old) =>
      old.s != s || old.v != v;
}

/// Manual RGB entry: three `0-255` cells + one `#RRGGBB` hex field.
/// Controllers re-sync from the store whenever the field is NOT focused
/// (same pattern as the V2 duration cells); commits validate and degrade
/// to an explanatory dialog on bad input.
class _RgbInputs extends HookWidget {
  const _RgbInputs({
    required this.current,
    required this.rNode,
    required this.gNode,
    required this.bNode,
    required this.hexNode,
  });

  final int current;
  final FocusNode rNode;
  final FocusNode gNode;
  final FocusNode bNode;
  final FocusNode hexNode;

  @override
  Widget build(BuildContext context) {
    final t = getLocalizations(context);
    final color = Color(current);
    // ignore: deprecated_member_use
    final r = color.red, g = color.green, b = color.blue;
    final rCtrl = useTextEditingController();
    final gCtrl = useTextEditingController();
    final bCtrl = useTextEditingController();
    final hexCtrl = useTextEditingController();

    String hexOf(int v) =>
        '#${(v & 0x00FFFFFF).toRadixString(16).padLeft(6, '0').toUpperCase()}';

    useEffect(() {
      if (!rNode.hasFocus && rCtrl.text != '$r') rCtrl.text = '$r';
      if (!gNode.hasFocus && gCtrl.text != '$g') gCtrl.text = '$g';
      if (!bNode.hasFocus && bCtrl.text != '$b') bCtrl.text = '$b';
      if (!hexNode.hasFocus && hexCtrl.text != hexOf(current)) {
        hexCtrl.text = hexOf(current);
      }
      return null;
    }, [current]);

    Future<void> error(String msg) async {
      if (!context.mounted) return;
      await showDialog<void>(
        context: context,
        builder: (_) => AlertDialog(
          title: Text(t.vm_color_format_error),
          content: Text(msg),
          actions: [
            TextButton(
                onPressed: () => Navigator.pop(context),
                child: Text(t.vm_color_got_it)),
          ],
        ),
      );
    }

    void commitTriple() {
      final rr = int.tryParse(rCtrl.text.trim());
      final gg = int.tryParse(gCtrl.text.trim());
      final bb = int.tryParse(bCtrl.text.trim());
      if (rr == null || gg == null || bb == null) {
        error(t.vm_color_rgb_bad_number);
        return;
      }
      if (rr < 0 || rr > 255 || gg < 0 || gg > 255 || bb < 0 || bb > 255) {
        error(t.vm_color_rgb_out_of_range);
        return;
      }
      useAppStore()
          .updateVmMarkTickColor(0xFF000000 | (rr << 16) | (gg << 8) | bb);
    }

    void commitHex() {
      var hex = hexCtrl.text.trim().toUpperCase();
      if (hex.startsWith('#')) hex = hex.substring(1);
      if (hex.length == 8) hex = hex.substring(2); // alpha locked at FF
      if (hex.length != 6 || int.tryParse(hex, radix: 16) == null) {
        error(t.vm_color_hex_hint);
        return;
      }
      final v = int.parse(hex, radix: 16);
      useAppStore().updateVmMarkTickColor(0xFF000000 | v);
    }

    Widget cell({
      required String label,
      required TextEditingController controller,
      required FocusNode node,
      required String key,
      required VoidCallback commit,
    }) {
      return SizedBox(
        width: 64,
        child: TextField(
          key: ValueKey(key),
          controller: controller,
          focusNode: node,
          textAlign: TextAlign.center,
          keyboardType: TextInputType.number,
          inputFormatters: [
            FilteringTextInputFormatter.digitsOnly,
            LengthLimitingTextInputFormatter(3),
          ],
          decoration:
              InputDecoration(isDense: true, labelText: label),
          onSubmitted: (_) => commit(),
        ),
      );
    }

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: [
            cell(
                label: 'R',
                controller: rCtrl,
                node: rNode,
                key: 'vmTickR',
                commit: commitTriple),
            cell(
                label: 'G',
                controller: gCtrl,
                node: gNode,
                key: 'vmTickG',
                commit: commitTriple),
            cell(
                label: 'B',
                controller: bCtrl,
                node: bNode,
                key: 'vmTickB',
                commit: commitTriple),
            TextButton(
                onPressed: commitTriple, child: Text(t.vm_color_apply)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: TextField(
                key: const ValueKey('vmTickHex'),
                controller: hexCtrl,
                focusNode: hexNode,
                maxLength: 9,
                decoration: const InputDecoration(
                  isDense: true,
                  labelText: '#RRGGBB',
                  hintText: '#FF9800',
                  counterText: '',
                ),
                onSubmitted: (_) => commitHex(),
              ),
            ),
            TextButton(onPressed: commitHex, child: Text(t.vm_color_apply)),
          ],
        ),
      ],
    );
  }
}

/// Length section: slider (0-[kVmTickExtentMaxPx]px) + numeric cell.
///
/// The slider previews locally and persists once on release; the numeric
/// cell commits on submit (invalid input is ignored, keeping the last good
/// value — matching the RGB cells' error-Dialog contract would spam dialogs
/// per keystroke, so the cell degrades silently by design).
class _ExtentInputs extends HookWidget {
  const _ExtentInputs({required this.extent, required this.focusNode});

  final int extent;
  final FocusNode focusNode;

  @override
  Widget build(BuildContext context) {
    final ctrl = useTextEditingController();
    useEffect(() {
      if (!focusNode.hasFocus && ctrl.text != '$extent') {
        ctrl.text = '$extent';
      }
      return null;
    }, [extent]);
    final preview = useState<int?>(null);
    final shown =
        preview.value ?? extent.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx);

    void commit() {
      final v = int.tryParse(ctrl.text.trim());
      if (v == null) return;
      useAppStore().updateVmMarkTickExtent(v);
      if (ctrl.text !=
          '${v.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx)}') {
        ctrl.text =
            '${v.clamp(kVmTickExtentMinPx, kVmTickExtentMaxPx)}';
      }
    }

    return Row(
      children: [
        Expanded(
          child: Slider(
            key: const ValueKey('vmTickExtentSlider'),
            value: shown.toDouble(),
            min: kVmTickExtentMinPx.toDouble(),
            max: kVmTickExtentMaxPx.toDouble(),
            // 1px steps across the whole 0..MAX range.
            divisions: kVmTickExtentMaxPx - kVmTickExtentMinPx,
            label: '${shown}px',
            onChanged: (v) => preview.value = v.round(),
            onChangeEnd: (v) {
              preview.value = null;
              useAppStore().updateVmMarkTickExtent(v.round());
            },
          ),
        ),
        SizedBox(
          width: 64,
          child: TextField(
            key: const ValueKey('vmTickExtentNumber'),
            controller: ctrl,
            focusNode: focusNode,
            textAlign: TextAlign.center,
            keyboardType: TextInputType.number,
            inputFormatters: [
              FilteringTextInputFormatter.digitsOnly,
              LengthLimitingTextInputFormatter(2),
            ],
            decoration: const InputDecoration(
                isDense: true, suffixText: 'px'),
            onSubmitted: (_) => commit(),
          ),
        ),
      ],
    );
  }
}
