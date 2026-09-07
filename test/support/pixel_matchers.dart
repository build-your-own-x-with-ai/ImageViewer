/// 像素比对助手。
///
/// 为什么需要容差版本：JPEG 的 IDCT 是浮点运算，不同实现（我们的朴素版、
/// 我们的 AAN 版、libjpeg）结果会差 ±1~2，这是规范允许的。所以有损格式
/// 用容差比对。
///
/// 无损格式（BMP / PNM / PNG / VP8L）必须 `tolerance: 0` —— 无损就是无损，
/// 差一个字节就是 bug。
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 断言某个像素等于给定的 RGBA 值。
void expectPixel(
  RgbaImage img,
  int x,
  int y,
  List<int> expected, {
  int tolerance = 0,
  String? reason,
}) {
  final List<int> actual = img.channelsAt(x, y);
  const List<String> names = <String>['R', 'G', 'B', 'A'];
  for (int c = 0; c < 4; c++) {
    final int diff = (actual[c] - expected[c]).abs();
    if (diff > tolerance) {
      fail(
        '像素 ($x, $y) 的 ${names[c]} 通道不符：'
        '期望 ${expected[c]}，实际 ${actual[c]}'
        '${tolerance > 0 ? "（容差 $tolerance）" : ""}\n'
        '  期望 RGBA: $expected\n'
        '  实际 RGBA: $actual'
        '${reason == null ? "" : "\n  $reason"}',
      );
    }
  }
}

/// 断言整张图逐像素相符。
///
/// 失败时报出第一个不符的像素坐标与两边的值 —— 比"两个 Uint8List 不相等"
/// 有用得多，能直接定位到是哪一行哪一列出的问题。
void expectImageMatches(
  RgbaImage actual,
  RgbaImage expected, {
  int tolerance = 0,
  String? reason,
}) {
  expect(
    actual.width,
    expected.width,
    reason: '宽度不符${reason == null ? "" : "：$reason"}',
  );
  expect(
    actual.height,
    expected.height,
    reason: '高度不符${reason == null ? "" : "：$reason"}',
  );

  int mismatches = 0;
  String? firstFailure;
  int maxDiff = 0;

  for (int y = 0; y < actual.height; y++) {
    for (int x = 0; x < actual.width; x++) {
      final List<int> a = actual.channelsAt(x, y);
      final List<int> e = expected.channelsAt(x, y);
      bool bad = false;
      for (int c = 0; c < 4; c++) {
        final int d = (a[c] - e[c]).abs();
        if (d > maxDiff) {
          maxDiff = d;
        }
        if (d > tolerance) {
          bad = true;
        }
      }
      if (bad) {
        mismatches++;
        firstFailure ??= '首个不符的像素在 ($x, $y)：期望 $e，实际 $a';
      }
    }
  }

  if (mismatches > 0) {
    final int total = actual.width * actual.height;
    fail(
      '$mismatches / $total 个像素不符'
      '${tolerance > 0 ? "（容差 $tolerance）" : ""}，'
      '最大通道偏差 $maxDiff\n'
      '  $firstFailure'
      '${reason == null ? "" : "\n  $reason"}',
    );
  }
}

/// 断言整张图是同一个颜色。
void expectSolidColor(
  RgbaImage img,
  List<int> rgba, {
  int tolerance = 0,
}) {
  for (int y = 0; y < img.height; y++) {
    for (int x = 0; x < img.width; x++) {
      expectPixel(img, x, y, rgba, tolerance: tolerance);
    }
  }
}
