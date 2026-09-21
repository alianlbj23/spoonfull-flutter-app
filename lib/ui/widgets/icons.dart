import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';

/// 設計稿的圓角箭頭 (←)。
class ArrowLeftIcon extends StatelessWidget {
  const ArrowLeftIcon({super.key, this.size = 64, this.color});

  final double size;
  final Color? color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _ArrowPainter(color ?? AppColors.arrowTint),
  );
}

class _ArrowPainter extends CustomPainter {
  _ArrowPainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = s.width * 0.13
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round
      ..style = PaintingStyle.stroke;
    final path = Path()
      ..moveTo(s.width * 0.36, s.height * 0.1)
      ..lineTo(s.width * 0.2, s.height * 0.5)
      ..lineTo(s.width * 0.36, s.height * 0.9)
      ..moveTo(s.width * 0.2, s.height * 0.5)
      ..lineTo(s.width * 0.86, s.height * 0.5);
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(_ArrowPainter old) => old.color != color;
}

/// 日期切換用的圓角三角形。
class TriangleIcon extends StatelessWidget {
  const TriangleIcon({
    super.key,
    this.size = 40,
    this.pointLeft = true,
    this.color = AppColors.ticketYellow,
  });

  final double size;
  final bool pointLeft;
  final Color color;

  @override
  Widget build(BuildContext context) => Transform.flip(
    flipX: !pointLeft,
    child: CustomPaint(
      size: Size(size * 0.8, size * 1.2),
      painter: _TrianglePainter(color),
    ),
  );
}

class _TrianglePainter extends CustomPainter {
  _TrianglePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.width * 0.2;
    final path = Path()
      ..moveTo(s.width * 0.9, s.height * 0.08)
      ..lineTo(s.width * 0.1, s.height * 0.5)
      ..lineTo(s.width * 0.9, s.height * 0.92)
      ..close();
    canvas.drawPath(path, paint);
    canvas.drawPath(path, paint..style = PaintingStyle.stroke);
  }

  @override
  bool shouldRepaint(_TrianglePainter old) => old.color != color;
}

/// 側選單「拍攝首頁」圖示 (圓頂)。
class DomeIcon extends StatelessWidget {
  const DomeIcon({super.key, this.size = 40, this.color = Colors.white});
  final double size;
  final Color color;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _DomePainter(color),
  );
}

class _DomePainter extends CustomPainter {
  _DomePainter(this.color);
  final Color color;

  @override
  void paint(Canvas canvas, Size s) {
    final r = RRect.fromLTRBAndCorners(
      s.width * 0.04,
      s.height * 0.16,
      s.width * 0.96,
      s.height * 0.86,
      topLeft: Radius.elliptical(s.width * 0.46, s.height * 0.5),
      topRight: Radius.elliptical(s.width * 0.46, s.height * 0.5),
      bottomLeft: Radius.circular(s.width * 0.12),
      bottomRight: Radius.circular(s.width * 0.12),
    );
    canvas.drawRRect(r, Paint()..color = color);
  }

  @override
  bool shouldRepaint(_DomePainter old) => old.color != color;
}

/// 側選單「膳食攝影紀錄」圖示 (飯糰)。
class OnigiriIcon extends StatelessWidget {
  const OnigiriIcon({
    super.key,
    this.size = 40,
    this.color = Colors.white,
    this.accent = AppColors.periwinkle,
  });
  final double size;
  final Color color;
  final Color accent;

  @override
  Widget build(BuildContext context) => CustomPaint(
    size: Size.square(size),
    painter: _OnigiriPainter(color, accent),
  );
}

class _OnigiriPainter extends CustomPainter {
  _OnigiriPainter(this.color, this.accent);
  final Color color;
  final Color accent;

  @override
  void paint(Canvas canvas, Size s) {
    final paint = Paint()
      ..color = color
      ..strokeJoin = StrokeJoin.round
      ..strokeWidth = s.width * 0.22;
    final tri = Path()
      ..moveTo(s.width * 0.5, s.height * 0.14)
      ..lineTo(s.width * 0.14, s.height * 0.82)
      ..lineTo(s.width * 0.86, s.height * 0.82)
      ..close();
    canvas
      ..drawPath(tri, paint..style = PaintingStyle.fill)
      ..drawPath(tri, paint..style = PaintingStyle.stroke)
      ..drawRRect(
        RRect.fromLTRBR(
          s.width * 0.3,
          s.height * 0.62,
          s.width * 0.7,
          s.height * 0.92,
          Radius.circular(s.width * 0.06),
        ),
        Paint()..color = accent,
      );
  }

  @override
  bool shouldRepaint(_OnigiriPainter old) =>
      old.color != color || old.accent != accent;
}

/// 將淺藍色素材 (periwinkle) 轉成指定色,白色部分保持白色。
ColorFilter periwinkleTo(Color target) {
  const src = AppColors.periwinkle;
  List<double> channel(double from, double to) {
    // 線性映射:from → to,255 → 255
    final a = (255 - to) / (255 - from);
    return [a, 255 - a * 255];
  }

  final r = channel(src.r * 255, target.r * 255);
  final g = channel(src.g * 255, target.g * 255);
  final b = channel(math.min(src.b * 255, 254), target.b * 255);
  return ColorFilter.matrix([
    r[0], 0, 0, 0, r[1],
    0, g[0], 0, 0, g[1],
    0, 0, b[0], 0, b[1],
    0, 0, 0, 1, 0,
  ]);
}
