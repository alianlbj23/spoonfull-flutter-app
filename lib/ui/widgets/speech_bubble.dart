import 'package:flutter/material.dart';

import '../../core/theme/app_theme.dart';

enum BubbleTail { left, bottomLeft }

/// 吉祥物的對話框。
class SpeechBubble extends StatelessWidget {
  const SpeechBubble({
    super.key,
    required this.text,
    required this.color,
    this.tail = BubbleTail.left,
    this.width,
    this.height = 87,
    this.fontSize = 40,
    this.textAlign = TextAlign.center,
  });

  final String text;
  final Color color;
  final BubbleTail tail;
  final double? width;
  final double height;
  final double fontSize;
  final TextAlign textAlign;

  @override
  Widget build(BuildContext context) {
    final padding = tail == BubbleTail.left
        ? const EdgeInsets.fromLTRB(40, 8, 24, 8)
        : const EdgeInsets.fromLTRB(36, 14, 24, 40);
    return CustomPaint(
      painter: _BubblePainter(color, tail),
      child: SizedBox(
        width: width,
        height: height,
        child: Padding(
          padding: padding,
          child: Align(
            alignment: textAlign == TextAlign.center
                ? Alignment.center
                : Alignment.centerLeft,
            child: FittedBox(
              fit: BoxFit.scaleDown,
              child: Text(
                text,
                textAlign: textAlign,
                style: AppText.size(fontSize, color: color),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BubblePainter extends CustomPainter {
  _BubblePainter(this.color, this.tail);
  final Color color;
  final BubbleTail tail;

  @override
  void paint(Canvas canvas, Size size) {
    const stroke = 4.0;
    const radius = 22.0;
    final tailSize = tail == BubbleTail.left ? 18.0 : 26.0;
    final body = tail == BubbleTail.left
        ? Rect.fromLTRB(tailSize, stroke / 2, size.width - stroke / 2,
            size.height - stroke / 2)
        : Rect.fromLTRB(stroke / 2, stroke / 2, size.width - stroke / 2,
            size.height - tailSize);
    final path = Path()
      ..addRRect(RRect.fromRectAndRadius(body, const Radius.circular(radius)));
    final tailPath = Path();
    if (tail == BubbleTail.left) {
      final cy = size.height / 2;
      tailPath
        ..moveTo(body.left + 2, cy - 12)
        ..lineTo(stroke, cy)
        ..lineTo(body.left + 2, cy + 12)
        ..close();
    } else {
      final x = body.left + 44;
      tailPath
        ..moveTo(x - 4, body.bottom - 2)
        ..lineTo(x - 18, size.height - stroke)
        ..lineTo(x + 24, body.bottom - 2)
        ..close();
    }
    final shape = Path.combine(PathOperation.union, path, tailPath);
    canvas
      ..drawPath(shape, Paint()..color = Colors.white)
      ..drawPath(
        shape,
        Paint()
          ..color = color
          ..style = PaintingStyle.stroke
          ..strokeWidth = stroke
          ..strokeJoin = StrokeJoin.round,
      );
  }

  @override
  bool shouldRepaint(_BubblePainter old) =>
      old.color != color || old.tail != tail;
}
