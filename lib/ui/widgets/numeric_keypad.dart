import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import 'pill_field.dart';

/// 開啟全螢幕數字鍵盤 (Figma 數字鍵盤頁),按 ✓ 回傳輸入值,返回鍵取消。
Future<String?> showNumericKeypad(
  BuildContext context, {
  String initial = '',
  int? maxLength,
}) {
  return showGeneralDialog<String>(
    context: context,
    barrierDismissible: false,
    barrierColor: Colors.white,
    transitionDuration: const Duration(milliseconds: 150),
    pageBuilder: (_, _, _) =>
        _KeypadPage(initial: initial, maxLength: maxLength),
  );
}

class _KeypadPage extends StatefulWidget {
  const _KeypadPage({required this.initial, this.maxLength});
  final String initial;
  final int? maxLength;

  @override
  State<_KeypadPage> createState() => _KeypadPageState();
}

class _KeypadPageState extends State<_KeypadPage> {
  late String _value = widget.initial;

  void _press(String digit) {
    if (widget.maxLength != null && _value.length >= widget.maxLength!) {
      return;
    }
    setState(() => _value += digit);
  }

  void _backspace() {
    if (_value.isEmpty) return;
    setState(() => _value = _value.substring(0, _value.length - 1));
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      child: Column(
        children: [
          const SizedBox(height: 37),
          PillField(
            value: _value,
            width: 765,
            height: 90,
            fontSize: 52,
            fieldKey: const Key('keypad-display'),
          ),
          const SizedBox(height: 28),
          Expanded(
            child: Container(
              margin: const EdgeInsets.symmetric(horizontal: 12),
              padding: const EdgeInsets.fromLTRB(42, 28, 42, 28),
              decoration: const BoxDecoration(
                color: AppColors.periwinkleLight,
                borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
              ),
              child: NumericKeypad(
                onDigit: _press,
                onBackspace: _backspace,
                onConfirm: () => Navigator.of(context).pop(_value),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 3x4 數字鍵:⌫ 0 ✓ / 1 2 3 / 4 5 6 / 7 8 9。
class NumericKeypad extends StatelessWidget {
  const NumericKeypad({
    super.key,
    required this.onDigit,
    required this.onBackspace,
    required this.onConfirm,
  });

  final ValueChanged<String> onDigit;
  final VoidCallback onBackspace;
  final VoidCallback onConfirm;

  @override
  Widget build(BuildContext context) {
    Widget digit(String d) => _Key(
      key: Key('key-$d'),
      onTap: () => onDigit(d),
      child: Text(d, style: AppText.size(52, color: Colors.white)),
    );
    final rows = [
      [
        _Key(
          key: const Key('key-backspace'),
          onTap: onBackspace,
          child: const Icon(
            Icons.backspace_outlined,
            color: Colors.white,
            size: 58,
          ),
        ),
        digit('0'),
        _Key(
          key: const Key('key-confirm'),
          onTap: onConfirm,
          child: const Icon(Icons.check_rounded, color: Colors.white, size: 72),
        ),
      ],
      [digit('1'), digit('2'), digit('3')],
      [digit('4'), digit('5'), digit('6')],
      [digit('7'), digit('8'), digit('9')],
    ];
    return Column(
      children: [
        for (var r = 0; r < rows.length; r++) ...[
          if (r > 0) const SizedBox(height: 12),
          Expanded(
            child: Row(
              children: [
                for (var c = 0; c < 3; c++) ...[
                  if (c > 0) const SizedBox(width: 8),
                  Expanded(child: rows[r][c]),
                ],
              ],
            ),
          ),
        ],
      ],
    );
  }
}

class _Key extends StatelessWidget {
  const _Key({super.key, required this.onTap, required this.child});
  final VoidCallback onTap;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final radius = BorderRadius.circular(12);
    return DecoratedBox(
      decoration: BoxDecoration(
        borderRadius: radius,
        border: Border(
          top: BorderSide(
            color: Colors.white.withValues(alpha: 0.3),
            width: 3,
          ),
        ),
      ),
      child: Material(
        color: AppColors.keypadKey,
        borderRadius: radius,
        child: InkWell(
          borderRadius: radius,
          onTap: onTap,
          child: Center(child: FittedBox(child: child)),
        ),
      ),
    );
  }
}
