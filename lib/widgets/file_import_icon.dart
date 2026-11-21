import 'package:flutter/material.dart';

/// 复刻爱阅记「文件导入」的图标：底部托盘 + 从托盘穿出的向上箭头。
///
/// 用 CustomPainter 自己画而不是直接套 Material 的 file_upload，
/// 是为了精确控制线宽、圆角和箭头比例，让它在 21px 下也清晰、更像原图。
class FileImportIcon extends StatelessWidget {
  final double size;
  final Color color;
  const FileImportIcon({super.key, this.size = 21, required this.color});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: size,
      height: size,
      child: CustomPaint(painter: _FileImportPainter(color)),
    );
  }
}

class _FileImportPainter extends CustomPainter {
  final Color color;
  _FileImportPainter(this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.width / 24;
    final p = Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.7 * s
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;

    // 托盘：两条竖线向下，底部圆角收口
    final tray = Path()
      ..moveTo(4 * s, 15 * s)
      ..lineTo(4 * s, 18 * s)
      ..cubicTo(4 * s, 19.1 * s, 4.9 * s, 20 * s, 6 * s, 20 * s)
      ..lineTo(18 * s, 20 * s)
      ..cubicTo(19.1 * s, 20 * s, 20 * s, 19.1 * s, 20 * s, 18 * s)
      ..lineTo(20 * s, 15 * s);
    canvas.drawPath(tray, p);

    // 箭头：杆从上往下，尖朝下、指向托盘开口（把文件「放进」书架）
    canvas.drawLine(Offset(12 * s, 4 * s), Offset(12 * s, 13 * s), p);
    final head = Path()
      ..moveTo(7.5 * s, 9 * s)
      ..lineTo(12 * s, 13 * s)
      ..lineTo(16.5 * s, 9 * s);
    canvas.drawPath(head, p);
  }

  @override
  bool shouldRepaint(covariant _FileImportPainter oldDelegate) =>
      oldDelegate.color != color;
}
