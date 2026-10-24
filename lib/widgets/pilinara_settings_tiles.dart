// Settings widgets adapted from PiliNara (lib/pages/setting/widgets/,
// including ordered_multi_select_dialog.dart,
// lib/pages/setting/slide_color_picker.dart and
// lib/common/widgets/color_palette.dart).
//
// PiliNara: https://github.com/Starfallan/PiliNara
// Copyright (C) PiliNara contributors.
// Adapted for Lumtub under the GNU General Public License, version 3 or
// later. Changes: values are passed in and reported through callbacks
// instead of being read from and written to PiliNara's storage, and the
// GetX and SmartDialog dependencies are removed.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../l10n/l10n.dart';

TextStyle _titleStyle(ThemeData theme) => theme.textTheme.titleMedium!;
TextStyle _subtitleStyle(ThemeData theme) => theme.textTheme.labelMedium!.copyWith(color: theme.colorScheme.outline);

/// A plain settings row; tapping it usually opens a dialog. From PiliNara's
/// `NormalItem`.
class NormalItem extends StatelessWidget {
  const NormalItem({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    this.trailing,
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      enabled: enabled,
      onTap: onTap,
      leading: leading,
      title: Text(title, style: _titleStyle(theme)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: _subtitleStyle(theme)),
      trailing: trailing,
    );
  }
}

/// A row with a switch; the whole row toggles it. From PiliNara's
/// `SetSwitchItem`.
///
/// With [onTap] it is PiliNara's split item: the row opens a sub-page and
/// only the switch, behind a divider, toggles.
class SwitchItem extends StatelessWidget {
  const SwitchItem({
    super.key,
    required this.title,
    this.subtitle,
    this.leading,
    required this.value,
    required this.onChanged,
    this.onTap,
    this.enabled = true,
  });

  final String title;
  final String? subtitle;
  final Widget? leading;
  final bool value;
  final ValueChanged<bool> onChanged;
  final VoidCallback? onTap;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final split = onTap != null;
    final switchButton = Transform.scale(
      scale: 0.8,
      alignment: Alignment.centerRight,
      child: Switch(value: value, onChanged: enabled ? onChanged : null),
    );
    final tile = ListTile(
      enabled: enabled,
      onTap: split ? onTap : () => onChanged(!value),
      leading: leading,
      title: Text(title, style: _titleStyle(theme).copyWith(color: split && !value ? theme.colorScheme.outline : null)),
      subtitle: subtitle == null ? null : Text(subtitle!, style: _subtitleStyle(theme)),
      trailing: split ? null : switchButton,
    );
    if (!split) return tile;
    return Row(children: [
      Expanded(child: tile),
      SizedBox(height: 25, child: VerticalDivider(width: 1, color: theme.colorScheme.outline.withValues(alpha: .3))),
      Padding(padding: const EdgeInsets.only(left: 4, right: 24), child: switchButton),
    ]);
  }
}

/// A row whose current value opens a menu at the pointer. From PiliNara's
/// `PopupListTile`.
class PopupItem<T> extends StatelessWidget {
  const PopupItem({
    super.key,
    required this.title,
    this.leading,
    required this.value,
    required this.values,
    required this.onSelected,
    this.enabled = true,
  });

  final String title;
  final Widget? leading;
  final T value;
  final List<(T, String)> values;
  final ValueChanged<T> onSelected;
  final bool enabled;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final label = values.where((v) => v.$1 == value).map((v) => v.$2).firstOrNull ?? '$value';
    return ListTile(
      enabled: enabled,
      onTap: () async {
        // PiliNara opens the menu where the row was tapped; ListTile has no
        // tap position, so it opens below the title instead.
        final box = context.findRenderObject()! as RenderBox;
        final origin = box.localToGlobal(Offset.zero);
        final dx = origin.dx + (leading == null ? 16 : 72);
        final top = origin.dy + 5;
        final chosen = await showMenu<T>(
          context: context,
          position: RelativeRect.fromLTRB(dx, top, dx, 0),
          initialValue: value,
          requestFocus: false,
          items: [
            for (final (item, text) in values)
              CheckedPopupMenuItem<T>(value: item, checked: item == value, child: Text(text)),
          ],
        );
        if (chosen != null && chosen != value) onSelected(chosen);
      },
      leading: leading,
      title: Text(title, style: theme.textTheme.titleMedium),
      subtitle: Text(label, style: theme.textTheme.labelMedium!.copyWith(color: enabled ? theme.colorScheme.secondary : theme.disabledColor)),
    );
  }
}

/// A single-choice list in a dialog; returns the chosen value. From
/// PiliNara's `SelectDialog`.
class SelectDialog<T> extends StatelessWidget {
  const SelectDialog({super.key, this.value, required this.values, required this.title, this.subtitleBuilder});

  final T? value;
  final String title;
  final List<(T, String)> values;
  final Widget? Function(BuildContext context, int index)? subtitleBuilder;

  @override
  Widget build(BuildContext context) {
    final titleMedium = Theme.of(context).textTheme.titleMedium!;
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(title),
      contentPadding: const EdgeInsets.symmetric(vertical: 12),
      content: Material(
        type: MaterialType.transparency,
        child: SingleChildScrollView(
          child: RadioGroup<T>(
            onChanged: (v) => Navigator.of(context).pop(v ?? value),
            groupValue: value,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: List.generate(values.length, (index) {
                final item = values[index];
                return RadioListTile<T>(
                  dense: true,
                  value: item.$1,
                  title: Text(item.$2, style: titleMedium),
                  subtitle: subtitleBuilder?.call(context, index),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

/// A slider in a dialog; returns the value when confirmed. From PiliNara's
/// `SliderDialog`.
class SliderDialog extends StatefulWidget {
  const SliderDialog({
    super.key,
    required this.value,
    required this.title,
    required this.min,
    required this.max,
    this.divisions,
    this.suffix = '',
    this.precise = 1,
  });

  final double value;
  final String title;
  final double min;
  final double max;
  final int? divisions;
  final String suffix;
  final int precise;

  @override
  State<SliderDialog> createState() => _SliderDialogState();
}

class _SliderDialogState extends State<SliderDialog> {
  late double _tempValue = widget.value.clamp(widget.min, widget.max);

  @override
  Widget build(BuildContext context) => AlertDialog(
        title: Text(widget.title),
        contentPadding: const EdgeInsets.only(top: 20, left: 8, right: 8, bottom: 8),
        content: SizedBox(
          height: 40,
          child: Slider(
            value: _tempValue,
            min: widget.min,
            max: widget.max,
            divisions: widget.divisions,
            label: '${_tempValue.toStringAsFixed(widget.precise)}${widget.suffix}',
            onChanged: (value) => setState(() => _tempValue = double.parse(value.toStringAsFixed(widget.precise))),
          ),
        ),
        actions: [
          TextButton(
            onPressed: Navigator.of(context).pop,
            child: Text(tr('取消'), style: TextStyle(color: Theme.of(context).colorScheme.outline)),
          ),
          TextButton(onPressed: () => Navigator.pop(context, _tempValue), child: Text(tr('确定'))),
        ],
      );
}

/// Opens a [SelectDialog] and reports a changed choice.
Future<void> pickFromDialog<T>(BuildContext context, {required String title, required T value, required List<(T, String)> values, required ValueChanged<T> onSelected}) async {
  final result = await showDialog<T>(context: context, builder: (context) => SelectDialog<T>(title: title, value: value, values: values));
  if (result != null && result != value) onSelected(result);
}

/// Opens a [SliderDialog] and reports a changed value.
Future<void> pickWithSlider(
  BuildContext context, {
  required String title,
  required double value,
  required double min,
  required double max,
  int? divisions,
  String suffix = '',
  int precise = 0,
  required ValueChanged<double> onSelected,
}) async {
  final result = await showDialog<double>(
    context: context,
    builder: (context) => SliderDialog(title: title, value: value, min: min, max: max, divisions: divisions, suffix: suffix, precise: precise),
  );
  if (result != null && result != value) onSelected(result);
}

/// Edits a list of words: add, change in place, remove. From PiliNara's
/// `ListEditorDialog`; returns the new list, or null when cancelled.
class ListEditorDialog extends StatefulWidget {
  const ListEditorDialog({
    super.key,
    required this.title,
    required this.initialItems,
    this.hintText = '点击添加按钮添加项目',
    this.itemLabel = '项目',
  });

  final String title;
  final List<String> initialItems;
  final String hintText;
  final String itemLabel;

  @override
  State<ListEditorDialog> createState() => _ListEditorDialogState();
}

class _ListEditorDialogState extends State<ListEditorDialog> {
  late final List<String> _items = List.of(widget.initialItems);
  late final List<TextEditingController> _controllers = [for (final item in _items) TextEditingController(text: item)];
  final _addController = TextEditingController();

  @override
  void dispose() {
    for (final controller in _controllers) {
      controller.dispose();
    }
    _addController.dispose();
    super.dispose();
  }

  void _toast(String message) => ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text(message), duration: const Duration(seconds: 2)));

  bool _addItem() {
    final value = _addController.text.trim();
    if (value.isEmpty) return true;
    if (_items.contains(value)) {
      _toast(tr('该{0}已存在', [tr(widget.itemLabel)]));
      return false;
    }
    setState(() {
      _items.add(value);
      _controllers.add(TextEditingController(text: value));
      _addController.clear();
    });
    return true;
  }

  bool _commitEdit(int index) {
    final value = _controllers[index].text.trim();
    if (value.isEmpty || value == _items[index]) {
      _controllers[index].text = _items[index];
      return true;
    }
    final duplicate = _items.indexOf(value);
    if (duplicate != -1 && duplicate != index) {
      _toast(tr('该{0}已存在', [tr(widget.itemLabel)]));
      return false;
    }
    setState(() => _items[index] = value);
    return true;
  }

  void _removeItem(int index) {
    _controllers.removeAt(index).dispose();
    setState(() => _items.removeAt(index));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      contentPadding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
      content: SizedBox(
        width: 420,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(
              child: TextField(
                controller: _addController,
                autofocus: true,
                decoration: InputDecoration(hintText: tr(widget.hintText), isDense: true),
                onSubmitted: (_) => _addItem(),
              ),
            ),
            const SizedBox(width: 8),
            IconButton(icon: const Icon(Icons.add_circle_outline), onPressed: _addItem, tooltip: tr('添加')),
          ]),
          const SizedBox(height: 12),
          if (_items.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 16),
              child: Center(child: Text(tr('暂无{0}', [tr(widget.itemLabel)]), style: theme.textTheme.bodyMedium?.copyWith(color: theme.colorScheme.outline))),
            )
          else
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxHeight: 300),
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: _items.length,
                  itemBuilder: (context, index) => Card(
                    margin: const EdgeInsets.only(bottom: 8),
                    child: ListTile(
                      dense: true,
                      contentPadding: const EdgeInsets.only(left: 12, right: 4, top: 4, bottom: 4),
                      title: TextField(
                        controller: _controllers[index],
                        style: theme.textTheme.bodyMedium,
                        decoration: const InputDecoration(isDense: true, filled: false, border: InputBorder.none, enabledBorder: InputBorder.none, contentPadding: EdgeInsets.zero),
                        onSubmitted: (_) => _commitEdit(index),
                        onTapOutside: (_) => _commitEdit(index),
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline, size: 20),
                        onPressed: () => _removeItem(index),
                        tooltip: tr('删除'),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ]),
      ),
      actionsPadding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'), style: TextStyle(color: theme.colorScheme.outline))),
        FilledButton(
          onPressed: () {
            for (var i = 0; i < _items.length; i++) {
              if (!_commitEdit(i)) return;
            }
            // Text typed but not added yet counts too.
            if (!_addItem()) return;
            Navigator.pop(context, List.of(_items));
          },
          child: Text(tr('保存')),
        ),
      ],
    );
  }
}

/// A round swatch showing a scheme's primary, tertiary and container colours.
/// From PiliNara's `ColorPalette`.
class ColorPalette extends StatelessWidget {
  const ColorPalette({super.key, required this.colorScheme, required this.selected});
  final ColorScheme colorScheme;
  final bool selected;

  @override
  Widget build(BuildContext context) {
    Widget box(Color color) => Expanded(child: ColoredBox(color: color, child: const SizedBox.expand()));
    Widget child = ClipOval(
      child: Column(children: [
        box(colorScheme.primary),
        Expanded(child: Row(children: [box(colorScheme.tertiary), box(colorScheme.primaryContainer)])),
      ]),
    );
    if (selected) {
      child = Stack(clipBehavior: Clip.none, alignment: Alignment.center, children: [
        child,
        Container(
          width: 23,
          height: 23,
          decoration: BoxDecoration(color: colorScheme.surfaceContainer, shape: BoxShape.circle),
          child: Icon(Icons.check_rounded, color: colorScheme.primary, size: 12),
        ),
      ]);
    }
    return Container(
      width: 50,
      height: 50,
      padding: const EdgeInsets.all(6),
      decoration: BoxDecoration(color: colorScheme.onInverseSurface, borderRadius: const BorderRadius.all(Radius.circular(10))),
      child: child,
    );
  }
}

/// RGB sliders and a hex field; pops with the chosen colour. From PiliNara's
/// `SlideColorPicker`.
class SlideColorPicker extends StatefulWidget {
  const SlideColorPicker({super.key, required this.color});
  final Color color;

  @override
  State<SlideColorPicker> createState() => _SlideColorPickerState();
}

class _SlideColorPickerState extends State<SlideColorPicker> {
  late int _rgb = widget.color.toARGB32() & 0xFFFFFF;
  late final _text = TextEditingController(text: _hex);

  String get _hex => _rgb.toRadixString(16).toUpperCase().padLeft(6, '0');

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _setByte(double value, int shift) => setState(() {
        _rgb = (_rgb & ~(0xFF << shift)) | (value.round() << shift);
        _text.text = _hex;
      });

  Widget _slider(String title, int value, int shift) => Row(children: [
        const SizedBox(width: 16),
        SizedBox(width: 16, child: Text(title)),
        const SizedBox(width: 12),
        Expanded(
          child: SliderTheme(
            data: SliderTheme.of(context).copyWith(trackHeight: 10),
            child: Slider(min: 0, max: 255, divisions: 255, value: value.toDouble(), onChanged: (v) => _setByte(v, shift)),
          ),
        ),
        SizedBox(width: 40, child: Text('$value')),
      ]);

  @override
  Widget build(BuildContext context) => SingleChildScrollView(
        child: Column(mainAxisSize: MainAxisSize.min, children: [
          Container(height: 100, color: Color(0xFF000000 | _rgb)),
          const SizedBox(height: 10),
          SizedBox(
            width: 120,
            child: TextField(
              controller: _text,
              inputFormatters: [LengthLimitingTextInputFormatter(6), FilteringTextInputFormatter.allow(RegExp('[0-9a-fA-F]'))],
              decoration: const InputDecoration(isDense: true, prefixText: '#'),
              onChanged: (value) {
                if (value.length == 6) setState(() => _rgb = int.tryParse(value, radix: 16) ?? 0);
              },
            ),
          ),
          _slider('R', _rgb >> 16, 16),
          _slider('G', (_rgb >> 8) & 0xFF, 8),
          _slider('B', _rgb & 0xFF, 0),
          Row(children: [
            const Spacer(),
            TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'), style: TextStyle(color: Theme.of(context).colorScheme.outline))),
            TextButton(onPressed: () => Navigator.pop(context, Color(0xFF000000 | _rgb)), child: Text(tr('确定'))),
            const SizedBox(width: 16),
          ]),
        ]),
      );
}

/// Asks for confirmation; true when confirmed.
Future<bool> confirmDialog(BuildContext context, {required String title, required String content, String confirm = '确定'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(content),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消'), style: TextStyle(color: Theme.of(context).colorScheme.outline))),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(tr(confirm))),
        ],
      ),
    ) ??
    false;

/// Picks several values in order; tapping numbers them 1, 2, 3… From
/// PiliNara's `OrderedMultiSelectDialog`, used for mpv's hwdec list.
class OrderedMultiSelectDialog<T> extends StatefulWidget {
  const OrderedMultiSelectDialog({super.key, required this.title, required this.initValues, required this.values, this.ordered = true});
  final String title;
  final Iterable<T> initValues;
  /// Each value with its title and description.
  final List<(T, String, String?)> values;
  /// False for a plain multi-select whose order does not matter.
  final bool ordered;

  @override
  State<OrderedMultiSelectDialog<T>> createState() => _OrderedMultiSelectDialogState<T>();
}

class _OrderedMultiSelectDialogState<T> extends State<OrderedMultiSelectDialog<T>> {
  late final List<T> _chosen = widget.initValues.toList();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      clipBehavior: Clip.hardEdge,
      title: Text(widget.title),
      contentPadding: const EdgeInsets.only(top: 12),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(mainAxisSize: MainAxisSize.min, children: [
            for (final (value, title, description) in widget.values)
              ListTile(
                dense: true,
                onTap: () => setState(() => _chosen.contains(value) ? _chosen.remove(value) : _chosen.add(value)),
                leading: _OrderBox(position: _chosen.contains(value) ? _chosen.indexOf(value) + 1 : null, ordered: widget.ordered),
                title: Text(title, style: theme.textTheme.titleSmall),
                subtitle: description == null ? null : Text(description, style: _subtitleStyle(theme)),
              ),
          ]),
        ),
      ),
      actionsPadding: const EdgeInsets.only(left: 16, right: 16, bottom: 12),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'), style: TextStyle(color: theme.colorScheme.outline))),
        TextButton(onPressed: _chosen.isEmpty ? null : () => Navigator.pop(context, List<T>.of(_chosen)), child: Text(tr('确定'))),
      ],
    );
  }
}

/// PiliNara's `OrderedCheckboxListTile` box: the position when chosen.
class _OrderBox extends StatelessWidget {
  const _OrderBox({required this.position, required this.ordered});
  final int? position;
  final bool ordered;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final chosen = position != null;
    return Container(
      width: 22,
      height: 22,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: chosen ? colors.primary : null,
        border: chosen ? null : Border.all(color: colors.onSurfaceVariant, width: 2),
        borderRadius: BorderRadius.circular(4),
      ),
      child: !chosen
          ? null
          : ordered
              ? Text('$position', style: TextStyle(color: colors.onPrimary, fontSize: 12, fontWeight: FontWeight.bold))
              : Icon(Icons.check_rounded, size: 16, color: colors.onPrimary),
    );
  }
}

/// A multi-line text editor in a dialog; pops with the text.
class TextEditDialog extends StatefulWidget {
  const TextEditDialog({super.key, required this.title, required this.initialText, this.hintText, this.helper, this.monospace = false, this.maxLines = 1});
  final String title;
  final String initialText;
  final String? hintText;
  /// Shown under the field; may change as the text changes.
  final Widget Function(String text)? helper;
  final bool monospace;
  final int maxLines;

  @override
  State<TextEditDialog> createState() => _TextEditDialogState();
}

class _TextEditDialogState extends State<TextEditDialog> {
  late final _text = TextEditingController(text: widget.initialText);

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 520,
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          TextField(
            controller: _text,
            autofocus: true,
            minLines: widget.maxLines > 1 ? 6 : 1,
            maxLines: widget.maxLines,
            onChanged: (_) => setState(() {}),
            style: widget.monospace ? const TextStyle(fontFamily: 'Consolas', fontSize: 13) : null,
            decoration: InputDecoration(hintText: widget.hintText, border: const OutlineInputBorder(), isDense: true),
          ),
          if (widget.helper != null) ...[const SizedBox(height: 8), widget.helper!(_text.text)],
        ]),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消'), style: TextStyle(color: theme.colorScheme.outline))),
        TextButton(onPressed: () => Navigator.pop(context, _text.text), child: Text(tr('保存'))),
      ],
    );
  }
}
