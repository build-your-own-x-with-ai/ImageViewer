import 'package:flutter/material.dart';

/// 半透明区域背后的棋盘格。
///
/// ## 为什么必须有它
///
/// 纯色背景分不清「这块是透明的」和「这块正好是背景色」。32bpp BMP 的
/// 羽化圆边缘、PNG 的 alpha 通道，如果画在纯白上就跟白色像素一模一样 ——
/// alpha 解错了根本看不出来。棋盘格让透明度变成肉眼可辨的东西。
///
/// 格子画在**屏幕空间**而不是图像空间：缩放图像时格子大小不变。这跟
/// Photoshop / Figma 的行为一致，也更有用 —— 格子是「背景」的一部分，
/// 不该跟着图一起放大。
class CheckerboardPainter extends CustomPainter {
  const CheckerboardPainter({
    this.cellSize = 8.0,
    this.light = const Color(0xFFFFFFFF),
    this.dark = const Color(0xFFE0E0E0),
  });

  /// 单个格子的边长（逻辑像素）。
  final double cellSize;
  final Color light;
  final Color dark;

  @override
  void paint(Canvas canvas, Size size) {
    // 底色铺满，然后只画深色格子 —— 比两种颜色各画一半省一半的 drawRect。
    canvas.drawRect(Offset.zero & size, Paint()..color = light);

    final Paint darkPaint = Paint()..color = dark;
    final int cols = (size.width / cellSize).ceil();
    final int rows = (size.height / cellSize).ceil();

    for (int row = 0; row < rows; row++) {
      // 每行错开一格，形成棋盘。行号加列号为奇数时画深色。
      for (int col = row.isEven ? 1 : 0; col < cols; col += 2) {
        canvas.drawRect(
          Rect.fromLTWH(col * cellSize, row * cellSize, cellSize, cellSize),
          darkPaint,
        );
      }
    }
  }

  @override
  bool shouldRepaint(CheckerboardPainter oldDelegate) =>
      oldDelegate.cellSize != cellSize ||
      oldDelegate.light != light ||
      oldDelegate.dark != dark;
}
