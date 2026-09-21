import 'package:flutter/material.dart';

import '../../core/theme/app_colors.dart';
import '../../core/theme/app_theme.dart';
import 'app_assets.dart';
import 'icons.dart';

enum TicketStatus { none, synced, pending, failed }

/// 紀錄頁的票券卡片 (日期 / 直式餐別 / 相機與狀態圖示)。
class MealTicket extends StatelessWidget {
  const MealTicket({
    super.key,
    required this.dateLabel,
    required this.title,
    required this.color,
    required this.status,
    this.onTap,
    this.width = 133,
    this.height = 371,
  });

  final String dateLabel;

  /// 直式顯示的標題,例如「早餐前」。
  final String title;
  final Color color;
  final TicketStatus status;
  final VoidCallback? onTap;
  final double width;
  final double height;

  static const double _notchY = 68;
  static const double _bottomLineY = 296;

  @override
  Widget build(BuildContext context) {
    final textStyle = AppText.size(36, color: AppColors.ticketText);
    return GestureDetector(
      onTap: onTap,
      child: CustomPaint(
        painter: _TicketPainter(color: color),
        child: SizedBox(
          width: width,
          height: height,
          child: Column(
            children: [
              SizedBox(
                height: _notchY,
                child: Center(
                  child: FittedBox(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text(
                        dateLabel,
                        style: textStyle.copyWith(
                          fontSize: 32,
                          letterSpacing: 2,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: Center(
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final ch in title.characters)
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12),
                            child: Text(ch, style: textStyle),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              SizedBox(
                height: height - _bottomLineY,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    ColorFiltered(
                      colorFilter: periwinkleTo(AppColors.blueButtonTop),
                      child: Image.asset(AppAssets.cameraCapture, width: 50),
                    ),
                    _StatusIcon(status),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _StatusIcon extends StatelessWidget {
  const _StatusIcon(this.status);
  final TicketStatus status;

  @override
  Widget build(BuildContext context) {
    final (icon, color, label) = switch (status) {
      TicketStatus.none => (Icons.close_rounded, AppColors.statusRed, '未拍攝'),
      TicketStatus.synced => (Icons.check_rounded, AppColors.success, '已上傳'),
      TicketStatus.pending => (Icons.schedule_rounded, AppColors.orangeText, '待上傳'),
      TicketStatus.failed => (Icons.error_rounded, AppColors.error, '上傳失敗'),
    };
    return Tooltip(
      message: label,
      child: Icon(icon, color: color, size: 46, semanticLabel: label),
    );
  }
}

class _TicketPainter extends CustomPainter {
  _TicketPainter({required this.color});
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    const notch = 10.0;
    final outline = Path()
      ..addRRect(
        RRect.fromRectAndRadius(
          Offset.zero & size,
          const Radius.circular(10),
        ),
      );
    final notches = Path()
      ..addOval(
        Rect.fromCircle(center: const Offset(0, MealTicket._notchY), radius: notch),
      )
      ..addOval(
        Rect.fromCircle(
          center: Offset(size.width, MealTicket._notchY),
          radius: notch,
        ),
      );
    final shape = Path.combine(PathOperation.difference, outline, notches);
    canvas
      ..drawPath(shape, Paint()..color = color)
      ..drawPath(
        shape,
        Paint()
          ..color = AppColors.ticketBorder
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.6,
      );

    final dash = Paint()
      ..color = AppColors.ticketBorder.withValues(alpha: 0.7)
      ..strokeWidth = 1.4;
    void dashed(double y, double from, double to) {
      for (var x = from; x < to; x += 8) {
        canvas.drawLine(Offset(x, y), Offset((x + 4).clamp(from, to), y), dash);
      }
    }

    dashed(MealTicket._notchY, notch + 2, size.width - notch - 2);
    dashed(MealTicket._bottomLineY, 4, size.width - 4);
  }

  @override
  bool shouldRepaint(_TicketPainter old) => old.color != color;
}
