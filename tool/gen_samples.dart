/// 生成 `assets/samples/` 下的内置样图。
///
/// 运行方式：
/// ```sh
/// dart run tool/gen_samples.dart
/// ```
///
/// ## 为什么逐字节手写，而不是用 sips / ImageMagick
///
/// 这个脚本**不 import 项目里的任何解码代码**，完全按格式规范手写字节。
/// 于是它和解码器是两套独立实现 —— 生成器写出来的文件能被解码器正确解开，
/// 才算两边都对。
///
/// 如果反过来用解码器的知识去生成（比如复用 `BmpHeader`），两边就会共享
/// 同一份误解：行对齐算错了，生成和解码一起错，测试照样绿。那种测试没有
/// 任何证明力。
///
/// ## 只覆盖阶段 1 的三种格式
///
/// BMP / PNM / YUV 都是「直排像素 + 简单头部」，手写完全可行。
/// PNG / JPEG / WebP 需要 deflate / DCT 编码器 —— 写一个编码器只为了测
/// 解码器，投入产出不合适。那三种到阶段 2-4 用参考实现生成后提交进仓库，
/// 详见 `docs/testing.md`。
///
/// ## 这个脚本不参与 CI
///
/// 产物一次性生成后提交进仓库，`flutter test` 只读文件、不调外部命令，
/// 也不跑这个脚本。它只在需要新增或调整样图时手动运行。
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

// ———————————————————————————————————————————————————————————————
// 小端写入助手
//
// BMP 的多字节字段一律小端（它源自 Intel 平台）。PNM 是文本或大端，
// 所以下面这几个只给 BMP 用。
// ———————————————————————————————————————————————————————————————

void u16(List<int> out, int v) {
  out.add(v & 0xFF);
  out.add((v >> 8) & 0xFF);
}

void u32(List<int> out, int v) {
  out.add(v & 0xFF);
  out.add((v >> 8) & 0xFF);
  out.add((v >> 16) & 0xFF);
  out.add((v >> 24) & 0xFF);
}

/// 有符号 32 位。BMP 的 biHeight 用负数表示自顶向下。
void i32(List<int> out, int v) => u32(out, v & 0xFFFFFFFF);

/// 把字符串按 **UTF-8** 编码成字节。PNM 的文本头部都走这里。
///
/// 为什么不用 `String.codeUnits`：那给的是 **UTF-16** 码元，一个中文字符
/// 会得到一个大于 255 的数（'由' 是 U+7531 = 30001）。塞进 `Uint8List`
/// 时只保留低 8 位，于是 30001 变成 0x31，头部注释里的中文就成了乱码。
///
/// 纯 ASCII 时两者结果相同，所以这个 bug 很容易漏 —— 直到你用文本编辑器
/// 打开一个 P3 文件，发现注释是一串方块。而「能用文本编辑器读」正是
/// ASCII 版 PNM 作为教学起点的全部意义。
List<int> text(String s) => utf8.encode(s);

/// BMP 每行按 4 字节对齐后的字节数。
///
/// 这是 BMP 最容易写错的地方，所以这里独立算一遍 —— 生成器和解码器
/// 各自实现，两边对得上才说明公式没错。
int rowStride(int width, int bpp) => ((width * bpp + 31) ~/ 32) * 4;

/// 组装一个 BITMAPINFOHEADER（40 字节头）的 BMP 文件。
Uint8List buildBmp({
  required int width,
  required int height,
  required int bpp,
  required List<int> pixelData,
  int compression = 0,
  List<List<int>> palette = const <List<int>>[],
  bool topDown = false,
}) {
  final List<int> out = <int>[];
  final int offBits = 14 + 40 + palette.length * 4;

  // —— BITMAPFILEHEADER，14 字节 ——
  out.add(0x42); // 'B'
  out.add(0x4D); // 'M'
  u32(out, offBits + pixelData.length); // bfSize
  u16(out, 0); // bfReserved1
  u16(out, 0); // bfReserved2
  u32(out, offBits); // bfOffBits：像素数据从哪开始

  // —— BITMAPINFOHEADER，40 字节 ——
  u32(out, 40); // biSize，头部版本就靠这个字段区分
  i32(out, width);
  i32(out, topDown ? -height : height); // 负高度 = 自顶向下
  u16(out, 1); // biPlanes，规范规定恒为 1
  u16(out, bpp);
  u32(out, compression);
  u32(out, pixelData.length); // biSizeImage
  i32(out, 3780); // biXPelsPerMeter，3780 ≈ 96 DPI
  i32(out, 3780);
  u32(out, palette.length); // biClrUsed
  u32(out, 0); // biClrImportant

  // —— 调色板：BGRA 顺序（注意不是 RGBA），第四字节保留为 0 ——
  for (final List<int> c in palette) {
    out.add(c[2]);
    out.add(c[1]);
    out.add(c[0]);
    out.add(0);
  }

  out.addAll(pixelData);
  return Uint8List.fromList(out);
}

// ———————————————————————————————————————————————————————————————
// BMP 样图
// ———————————————————————————————————————————————————————————————

/// 24bpp 真彩渐变。
///
/// 宽度故意取 61（不是 4 的倍数）：61×3 = 183 字节，要补到 184。
/// 如果解码器把行宽当成 `width*3`，第二行就会整体偏 1 字节，
/// 显示出来是一道明显的斜纹 —— 一眼就能看出来。
Uint8List bmp24Gradient() {
  const int w = 61;
  const int h = 40;
  final int stride = rowStride(w, 24);
  final List<int> px = <int>[];

  // BMP 默认自底向上：先写的是最后一行。
  for (int y = h - 1; y >= 0; y--) {
    final List<int> row = <int>[];
    for (int x = 0; x < w; x++) {
      // BGR 顺序，不是 RGB。
      row.add((255 * y / (h - 1)).round()); // B 随纵向增长
      row.add((255 * x / (w - 1)).round()); // G 随横向增长
      row.add(128); // R 固定，方便看出另两个通道的变化
    }
    while (row.length < stride) {
      row.add(0); // 行尾填充，值无意义但字节必须在
    }
    px.addAll(row);
  }
  return buildBmp(width: w, height: h, bpp: 24, pixelData: px);
}

/// 8bpp 调色板图：256 色彩虹竖条。
///
/// 用满 256 个调色板项，且每一列取不同的索引 —— 调色板查错一个位置，
/// 颜色顺序就乱了，肉眼可见。
Uint8List bmp8Palette() {
  const int w = 128;
  const int h = 40;
  final int stride = rowStride(w, 8);

  final List<List<int>> palette = <List<int>>[
    for (int i = 0; i < 256; i++) hsvToRgb(i * 360 / 256, 1.0, 1.0),
  ];

  final List<int> px = <int>[];
  for (int y = h - 1; y >= 0; y--) {
    final List<int> row = <int>[];
    for (int x = 0; x < w; x++) {
      row.add((x * 256 ~/ w) & 0xFF); // 索引，不是颜色值
    }
    while (row.length < stride) {
      row.add(0);
    }
    px.addAll(row);
  }
  return buildBmp(
    width: w,
    height: h,
    bpp: 8,
    pixelData: px,
    palette: palette,
  );
}

/// 32bpp 带 alpha：一个边缘柔化的圆。
///
/// 用来验证棋盘格背景 —— 半透明区域应该能透出格子。
/// 注意 alpha 不全为 0 也不全为 255，两种极端都测不出混合是否正确。
Uint8List bmp32Alpha() {
  const int w = 64;
  const int h = 64;
  final List<int> px = <int>[];

  for (int y = h - 1; y >= 0; y--) {
    for (int x = 0; x < w; x++) {
      final double dx = x - w / 2 + 0.5;
      final double dy = y - h / 2 + 0.5;
      final double dist = _hypot(dx, dy);
      const double radius = 26;
      const double feather = 6;

      // 圆内不透明，边缘 6 像素线性过渡到全透明。
      double alpha;
      if (dist <= radius - feather) {
        alpha = 1.0;
      } else if (dist >= radius) {
        alpha = 0.0;
      } else {
        alpha = (radius - dist) / feather;
      }

      // BGRA 顺序。颜色按角度取色相，让圆看起来是个色轮。
      final List<int> rgb = hsvToRgb(
        (_atan2Degrees(dy, dx) + 360) % 360,
        (dist / radius).clamp(0.0, 1.0),
        1.0,
      );
      px.add(rgb[2]);
      px.add(rgb[1]);
      px.add(rgb[0]);
      px.add((alpha * 255).round());
    }
    // 32bpp 每行必然是 4 的倍数，不需要填充。
  }
  return buildBmp(width: w, height: h, bpp: 32, pixelData: px);
}

/// RLE8 压缩的 BMP：水平色带。
///
/// 水平色带是游程编码最理想的输入 —— 每行就是一条游程，
/// 压缩后的数据比原始像素小一个数量级。
Uint8List bmp8Rle() {
  const int w = 80;
  const int h = 32;
  const int bandCount = 16;

  final List<List<int>> palette = <List<int>>[
    for (int i = 0; i < bandCount; i++)
      hsvToRgb(i * 360 / bandCount, 0.85, 0.95),
  ];

  final List<int> px = <int>[];
  // 自底向上写。
  for (int y = h - 1; y >= 0; y--) {
    final int index = (y * bandCount ~/ h) & 0xFF;
    // 编码游程：[个数, 索引]。个数上限 255，这里 80 一次就够。
    px.add(w);
    px.add(index);
    px.add(0x00); // EOL：本行结束
    px.add(0x00);
  }
  px.add(0x00); // EOF：整幅图结束
  px.add(0x01);

  return buildBmp(
    width: w,
    height: h,
    bpp: 8,
    pixelData: px,
    compression: 1, // BI_RLE8
    palette: palette,
  );
}

/// 自顶向下的 24bpp 图（负高度）。
///
/// 跟 [bmp24Gradient] 内容上下颠倒地写，但因为标了负高度，
/// 解出来应该跟它**看起来一样**。方向处理错了就是上下翻转。
Uint8List bmp24TopDown() {
  const int w = 61;
  const int h = 40;
  final int stride = rowStride(w, 24);
  final List<int> px = <int>[];

  // 自顶向下：从第 0 行开始写。
  for (int y = 0; y < h; y++) {
    final List<int> row = <int>[];
    for (int x = 0; x < w; x++) {
      row.add((255 * y / (h - 1)).round());
      row.add((255 * x / (w - 1)).round());
      row.add(128);
    }
    while (row.length < stride) {
      row.add(0);
    }
    px.addAll(row);
  }
  return buildBmp(
    width: w,
    height: h,
    bpp: 24,
    pixelData: px,
    topDown: true,
  );
}

// ———————————————————————————————————————————————————————————————
// PNM 样图
//
// 六种变体各出一张。PNM 是自顶向下的（跟 BMP 相反），
// 头部是文本、像素可以是文本或二进制。
// ———————————————————————————————————————————————————————————————

/// P6：二进制 PPM 彩色渐变。
Uint8List pnmP6() {
  const int w = 64;
  const int h = 48;
  final List<int> out = <int>[];
  // 头部里塞一条注释，顺便验证解码器的词法处理。
  out.addAll(text('P6\n# 由 tool/gen_samples.dart 生成\n$w $h\n255\n'));
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out.add((255 * x / (w - 1)).round()); // R
      out.add((255 * y / (h - 1)).round()); // G
      out.add(96); // B
    }
  }
  return Uint8List.fromList(out);
}

/// P3：ASCII PPM。
///
/// 故意做得很小（8×8），这样能直接用文本编辑器打开看每个像素的数值 ——
/// 这是 PNM 作为教学起点最大的好处。
Uint8List pnmP3() {
  const int w = 8;
  const int h = 8;
  final StringBuffer sb = StringBuffer()
    ..writeln('P3')
    ..writeln('# ASCII PPM：可以直接用文本编辑器打开')
    ..writeln('$w $h')
    ..writeln('255');
  for (int y = 0; y < h; y++) {
    final List<String> row = <String>[];
    for (int x = 0; x < w; x++) {
      final List<int> rgb = hsvToRgb((x + y * w) * 360 / (w * h), 0.9, 1.0);
      row.add('${rgb[0]} ${rgb[1]} ${rgb[2]}');
    }
    sb.writeln(row.join('  '));
  }
  return Uint8List.fromList(text(sb.toString()));
}

/// P5：二进制 PGM 灰度渐变，maxval 255。
Uint8List pnmP5() {
  const int w = 64;
  const int h = 32;
  final List<int> out = <int>[];
  out.addAll(text('P5\n$w $h\n255\n'));
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      out.add((255 * x / (w - 1)).round());
    }
  }
  return Uint8List.fromList(out);
}

/// P2：ASCII PGM，maxval 15。
///
/// maxval 不是 255，用来验证解码器真的做了缩放而不是直接当 8 位用。
Uint8List pnmP2() {
  const int w = 16;
  const int h = 8;
  const int maxval = 15;
  final StringBuffer sb = StringBuffer()
    ..writeln('P2')
    ..writeln('# maxval=15，解码时要缩放到 0-255')
    ..writeln('$w $h')
    ..writeln('$maxval');
  for (int y = 0; y < h; y++) {
    final List<String> row = <String>[];
    for (int x = 0; x < w; x++) {
      row.add('${x * maxval ~/ (w - 1)}');
    }
    sb.writeln(row.join(' '));
  }
  return Uint8List.fromList(text(sb.toString()));
}

/// P4：二进制 PBM 位图，棋盘格。
///
/// 两个坑都在这里：**1 表示黑**（跟直觉相反），且每行按字节对齐、
/// 高位在前。宽度取 20 不是 8 的倍数，最后一个字节只有 4 位有效。
Uint8List pnmP4() {
  const int w = 20;
  const int h = 16;
  final List<int> out = <int>[];
  out.addAll(text('P4\n$w $h\n')); // 注意：位图没有 maxval 行

  final int bytesPerRow = (w + 7) ~/ 8;
  for (int y = 0; y < h; y++) {
    final List<int> row = List<int>.filled(bytesPerRow, 0);
    for (int x = 0; x < w; x++) {
      // 4×4 的格子，黑白相间。
      final bool black = ((x ~/ 4) + (y ~/ 4)).isEven;
      if (black) {
        row[x ~/ 8] |= 0x80 >> (x % 8); // 高位在前
      }
    }
    out.addAll(row);
  }
  return Uint8List.fromList(out);
}

/// P1：ASCII PBM 位图。
Uint8List pnmP1() {
  const int w = 16;
  const int h = 16;
  final StringBuffer sb = StringBuffer()
    ..writeln('P1')
    ..writeln('# 1 是黑，0 是白 —— 跟直觉相反')
    ..writeln('$w $h');
  for (int y = 0; y < h; y++) {
    final StringBuffer row = StringBuffer();
    for (int x = 0; x < w; x++) {
      // 画一个圆环。
      final double dx = x - w / 2 + 0.5;
      final double dy = y - h / 2 + 0.5;
      final double d = _hypot(dx, dy);
      row.write(d > 4 && d < 7 ? '1' : '0');
    }
    sb.writeln(row);
  }
  return Uint8List.fromList(text(sb.toString()));
}

// ———————————————————————————————————————————————————————————————
// YUV 样图
// ———————————————————————————————————————————————————————————————

/// I420 彩条，三帧。
///
/// ## 为什么用彩条
///
/// SMPTE 彩条是广播行业的标准测试图，每条都是饱和的纯色 —— 色度抽样和
/// 矩阵系数只要错一点，颜色就明显不对。渐变图反而看不出来。
///
/// ## 为什么做三帧
///
/// 裸 YUV 文件里可以首尾相接放很多帧，没有任何分隔符。做三帧（彩条逐帧
/// 右移）是为了让 UI 上的帧号选择器有东西可选，也让「一个文件里有多张图」
/// 这件事变得可见。
///
/// ## 编码用的是正向变换
///
/// 这里按 limited range 的标准定义正向编码（`Y ∈ 16..235`，
/// `Cb/Cr ∈ 16..240`），跟解码器的反向变换是两套独立推导。
/// 解出来颜色对，才说明两边的系数都没抄错。
Uint8List yuvColorBars() {
  const int w = 96;
  const int h = 64;
  const int frames = 3;

  // 100% SMPTE 彩条的七个颜色。
  const List<List<int>> bars = <List<int>>[
    <int>[255, 255, 255], // 白
    <int>[255, 255, 0], // 黄
    <int>[0, 255, 255], // 青
    <int>[0, 255, 0], // 绿
    <int>[255, 0, 255], // 洋红
    <int>[255, 0, 0], // 红
    <int>[0, 0, 255], // 蓝
  ];

  final List<int> out = <int>[];

  for (int f = 0; f < frames; f++) {
    // 逐像素算出 YUV，色度先满分辨率存着，最后再抽样。
    final List<int> yPlane = List<int>.filled(w * h, 0);
    final List<int> uFull = List<int>.filled(w * h, 0);
    final List<int> vFull = List<int>.filled(w * h, 0);

    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        // 每帧把彩条右移一格，形成动画。
        final int bar = ((x * bars.length ~/ w) + f) % bars.length;
        final List<int> rgb = bars[bar];
        final List<int> yuv = rgbToYuvLimited(rgb[0], rgb[1], rgb[2]);
        final int i = y * w + x;
        yPlane[i] = yuv[0];
        uFull[i] = yuv[1];
        vFull[i] = yuv[2];
      }
    }

    // —— 亮度平面，逐像素 ——
    out.addAll(yPlane);

    // —— 色度平面：2×2 取平均后各占 (w/2)×(h/2) ——
    // 真实编码器就是这么做的（不是丢掉三个只留一个）。
    // 解码时我们用最近邻放大回去，所以在纯色区域内往返是准确的，
    // 只有色条边界会被抹一格 —— 这正是 4:2:0 的代价，肉眼可查。
    for (final List<int> plane in <List<int>>[uFull, vFull]) {
      for (int cy = 0; cy < h ~/ 2; cy++) {
        for (int cx = 0; cx < w ~/ 2; cx++) {
          final int x = cx * 2;
          final int y = cy * 2;
          final int sum = plane[y * w + x] +
              plane[y * w + x + 1] +
              plane[(y + 1) * w + x] +
              plane[(y + 1) * w + x + 1];
          out.add((sum / 4).round());
        }
      }
    }
  }
  return Uint8List.fromList(out);
}

/// RGB → YUV，BT.601 limited range 正向变换。
///
/// 按标准定义直接写，不复用解码器的任何常量：
/// ```
/// Y' = kr·R' + kg·G' + kb·B'          （R' 等为 0..1 归一值）
/// Y  = 16  + 219·Y'
/// Cb = 128 + 224·(B' - Y') / (2(1-kb))
/// Cr = 128 + 224·(R' - Y') / (2(1-kr))
/// ```
/// 219 和 224 就是 limited range 那两个量程（16–235 与 16–240）。
List<int> rgbToYuvLimited(int r, int g, int b) {
  const double kr = 0.299;
  const double kb = 0.114;
  const double kg = 1 - kr - kb;

  final double rn = r / 255.0;
  final double gn = g / 255.0;
  final double bn = b / 255.0;

  final double yn = kr * rn + kg * gn + kb * bn;
  final double y = 16 + 219 * yn;
  final double cb = 128 + 224 * (bn - yn) / (2 * (1 - kb));
  final double cr = 128 + 224 * (rn - yn) / (2 * (1 - kr));

  return <int>[
    y.round().clamp(0, 255),
    cb.round().clamp(0, 255),
    cr.round().clamp(0, 255),
  ];
}

// ———————————————————————————————————————————————————————————————
// 数学助手
// ———————————————————————————————————————————————————————————————

/// HSV → RGB。用来生成好看的测试色，跟格式本身无关。
///
/// `h` 是 0–360 的角度，`s`、`v` 是 0–1。
List<int> hsvToRgb(double h, double s, double v) {
  final double c = v * s;
  final double hp = (h % 360) / 60.0;
  final double x = c * (1 - ((hp % 2) - 1).abs());
  final double m = v - c;

  final double r1;
  final double g1;
  final double b1;
  switch (hp.floor()) {
    case 0:
      r1 = c;
      g1 = x;
      b1 = 0;
    case 1:
      r1 = x;
      g1 = c;
      b1 = 0;
    case 2:
      r1 = 0;
      g1 = c;
      b1 = x;
    case 3:
      r1 = 0;
      g1 = x;
      b1 = c;
    case 4:
      r1 = x;
      g1 = 0;
      b1 = c;
    default:
      r1 = c;
      g1 = 0;
      b1 = x;
  }
  return <int>[
    ((r1 + m) * 255).round().clamp(0, 255),
    ((g1 + m) * 255).round().clamp(0, 255),
    ((b1 + m) * 255).round().clamp(0, 255),
  ];
}

double _hypot(double a, double b) => math.sqrt(a * a + b * b);

double _atan2Degrees(double y, double x) =>
    math.atan2(y, x) * 180 / math.pi;

// ———————————————————————————————————————————————————————————————
// PNG
//
// 这一节和前面三种格式有个本质区别：PNG 的像素必须经 deflate 压缩，而手写
// 一个 deflate **编码器**（LZ77 匹配 + Huffman 构树 + 码长传输）的工作量
// 远超它能证明的东西。所以这里用 `dart:io` 的 `ZLibCodec` 当参考实现。
//
// 这不是对「生成器不依赖被测代码」原则的妥协，反而是它最强的一次应用：
// 压缩流出自 zlib 官方实现，我们手写的 inflate 能解开它，才说明 inflate
// 真的实现了 RFC 1951 —— 而不只是能解开自家写出来的东西。
//
// 单元测试里的 PNG 一律用**存储块**（BTYPE=00），压根不碰 Huffman 路径。
// 样图补上的正是这一块：zlib 以 level 9 输出的动态 Huffman 块。两者合起来
// 才算把 inflate 的三种块类型都跑到了真实数据上。
// ———————————————————————————————————————————————————————————————

/// 大端 32 位。PNG 通篇网络字节序，和 BMP 的小端正好相反。
void u32be(List<int> out, int v) {
  out.add((v >> 24) & 0xFF);
  out.add((v >> 16) & 0xFF);
  out.add((v >> 8) & 0xFF);
  out.add(v & 0xFF);
}

/// PNG chunk 的 CRC-32（多项式 0xEDB88320，反射形式）。
///
/// 逐位算，不建表 —— 生成样图不是热路径，而逐位的版本一眼能对上定义。
int pngCrc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final int b in data) {
    crc ^= b;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >> 1) ^ 0xEDB88320 : crc >> 1;
    }
  }
  return crc ^ 0xFFFFFFFF;
}

/// 拼一个 chunk：`长度(4) + 类型(4) + 数据 + CRC(4)`。
///
/// CRC 覆盖**类型 + 数据**，不含长度字段。范围记错的话所有 chunk 都对不上。
List<int> pngChunk(String type, List<int> data) {
  final List<int> out = <int>[];
  u32be(out, data.length);
  final List<int> typeAndData = <int>[...text(type), ...data];
  out.addAll(typeAndData);
  u32be(out, pngCrc32(typeAndData));
  return out;
}

/// Paeth 预测器。独立写一遍，和解码器的实现互不参考。
///
/// 平局时的取舍顺序是 a > b > c —— 这个顺序不是随意的，编码和解码必须
/// 完全一致，否则解出来的图会在特定像素上偏一两个数值。
int paeth(int a, int b, int c) {
  final int p = a + b - c;
  final int pa = (p - a).abs();
  final int pb = (p - b).abs();
  final int pc = (p - c).abs();
  if (pa <= pb && pa <= pc) {
    return a;
  }
  return pb <= pc ? b : c;
}

/// 用第 [type] 号滤波器处理一行，返回滤波后的字节。
///
/// [prev] 是**已还原**的上一行（不是滤波后的）。第一行传全零 —— 规范
/// 规定虚拟的第 0 行全是 0，这样 Up / Paeth 在首行也有定义。
List<int> filterRow(List<int> row, List<int> prev, int bpp, int type) {
  final int n = row.length;
  final List<int> out = List<int>.filled(n, 0);
  for (int i = 0; i < n; i++) {
    final int a = i >= bpp ? row[i - bpp] : 0;
    final int b = prev[i];
    final int c = i >= bpp ? prev[i - bpp] : 0;
    final int pred = switch (type) {
      0 => 0,
      1 => a,
      2 => b,
      3 => (a + b) >> 1, // 注意是 a + b 的和先算全精度再折半
      4 => paeth(a, b, c),
      _ => throw StateError('滤波器 $type 不存在'),
    };
    out[i] = (row[i] - pred) & 0xFF;
  }
  return out;
}

/// 逐行挑滤波器：五种都试，取「绝对值之和」最小的那个。
///
/// 这就是 libpng 的默认启发式。它的依据是：把字节当有符号数看，越接近 0
/// 的值越集中，deflate 的 Huffman 就能给它们更短的码字。不是最优解（真正
/// 的最优要试遍组合再压缩比大小），但便宜且效果好。
///
/// 逐行独立选择是关键 —— 一张图里不同区域的最佳滤波器往往不同，样图因此
/// 天然会用上多种滤波器，正好把解码端五条分支都跑到。
int pickFilter(List<int> row, List<int> prev, int bpp) {
  int best = 0;
  int bestScore = -1;
  for (int type = 0; type < 5; type++) {
    int score = 0;
    for (final int v in filterRow(row, prev, bpp, type)) {
      score += v < 128 ? v : 256 - v; // 当有符号数看的绝对值
    }
    if (bestScore < 0 || score < bestScore) {
      bestScore = score;
      best = type;
    }
  }
  return best;
}

/// Adam7 的七遍参数：起始偏移与步长。手抄自规范，与解码端各存一份。
const List<List<int>> adam7 = <List<int>>[
  // xOffset, yOffset, xStep, yStep
  <int>[0, 0, 8, 8],
  <int>[4, 0, 8, 8],
  <int>[0, 4, 4, 8],
  <int>[2, 0, 4, 4],
  <int>[0, 2, 2, 4],
  <int>[1, 0, 2, 2],
  <int>[0, 1, 1, 2],
];

/// 把「滤波类型字节 + 滤波后行数据」按行拼成 inflate 应输出的原始流。
///
/// [rows] 的每一项是一行**未滤波**的字节。滤波器逐行自动挑选。
List<int> pngRaw(List<List<int>> rows, int bpp) {
  final List<int> raw = <int>[];
  List<int> prev = List<int>.filled(rows.isEmpty ? 0 : rows.first.length, 0);
  for (final List<int> row in rows) {
    final int type = pickFilter(row, prev, bpp);
    raw.add(type);
    raw.addAll(filterRow(row, prev, bpp, type));
    prev = row;
  }
  return raw;
}

/// 组装一个完整 PNG。
///
/// [rows] 是逐行的**未滤波**字节。压缩交给 `ZLibCodec(level: 9)` —— 见本节
/// 开头的说明。
Uint8List buildPng({
  required int width,
  required int height,
  required int bitDepth,
  required int colorType,
  required List<List<int>> rows,
  List<int>? palette,
  List<int>? transparency,
  bool interlace = false,
  List<List<int>>? extraChunks,
}) {
  final int channels = switch (colorType) {
    0 => 1,
    2 => 3,
    3 => 1,
    4 => 2,
    6 => 4,
    _ => throw StateError('色彩类型 $colorType 不存在'),
  };
  final int bitsPerPixel = channels * bitDepth;
  final int bpp = bitsPerPixel < 8 ? 1 : bitsPerPixel ~/ 8;

  final List<int> raw;
  if (!interlace) {
    raw = pngRaw(rows, bpp);
  } else {
    // 隔行时每一遍是一张独立的小图：行字节数按**本遍宽度**重算，
    // 上一行缓冲在遍与遍之间重置。这两点是 Adam7 最容易写错的地方。
    if (bitsPerPixel % 8 != 0) {
      throw StateError('这个生成器只给字节对齐的位深做隔行');
    }
    raw = <int>[];
    for (final List<int> p in adam7) {
      final int px = p[0], py = p[1], sx = p[2], sy = p[3];
      final List<List<int>> passRows = <List<int>>[];
      for (int y = py; y < height; y += sy) {
        final List<int> row = <int>[];
        for (int x = px; x < width; x += sx) {
          row.addAll(rows[y].sublist(x * bpp, (x + 1) * bpp));
        }
        passRows.add(row);
      }
      // 空遍连滤波字节都不写。小图上大多数遍是空的。
      if (passRows.isEmpty || passRows.first.isEmpty) {
        continue;
      }
      raw.addAll(pngRaw(passRows, bpp));
    }
  }

  final List<int> out = <int>[
    0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
  ];
  final List<int> ihdr = <int>[];
  u32be(ihdr, width);
  u32be(ihdr, height);
  ihdr.addAll(<int>[bitDepth, colorType, 0, 0, interlace ? 1 : 0]);
  out.addAll(pngChunk('IHDR', ihdr));

  if (palette != null) {
    out.addAll(pngChunk('PLTE', palette));
  }
  if (transparency != null) {
    out.addAll(pngChunk('tRNS', transparency));
  }
  for (final List<int> c in extraChunks ?? const <List<int>>[]) {
    out.addAll(c);
  }
  out.addAll(pngChunk(
    'IDAT',
    ZLibCodec(level: 9).encode(raw),
  ));
  out.addAll(pngChunk('IEND', const <int>[]));
  return Uint8List.fromList(out);
}

/// 大端 32 位，返回新列表。给 gAMA / pHYs 这类小字段用。
List<int> be32(int v) {
  final List<int> out = <int>[];
  u32be(out, v);
  return out;
}

/// RGB8 渐变，96×64，带 gAMA 与 tEXt。
///
/// 三个通道各按不同方向渐变。滤波器逐行自选，于是这张图里会同时出现
/// 好几种 —— 正是单元测试里那些「一行一种滤波器」的手写用例覆盖不到的
/// 真实混合情形。
Uint8List pngRgb8Gradient() {
  const int w = 96, h = 64;
  final List<List<int>> rows = <List<int>>[];
  for (int y = 0; y < h; y++) {
    final List<int> row = <int>[];
    for (int x = 0; x < w; x++) {
      row.addAll(<int>[
        x * 255 ~/ (w - 1),
        y * 255 ~/ (h - 1),
        (x + y) * 255 ~/ (w + h - 2),
      ]);
    }
    rows.add(row);
  }
  return buildPng(
    width: w,
    height: h,
    bitDepth: 8,
    colorType: 2,
    rows: rows,
    extraChunks: <List<int>>[
      // 0.45455 ≈ 1/2.2，老资料里最常见的值。
      pngChunk('gAMA', be32(45455)),
      // 3780 像素/米 ≈ 96 DPI。
      pngChunk('pHYs', <int>[...be32(3780), ...be32(3780), 1]),
      pngChunk('tEXt', <int>[
        ...text('Software'),
        0,
        ...text('ImageViewer gen_samples.dart'),
      ]),
    ],
  );
}

/// RGBA8 圆盘，64×64，alpha 从圆心向外渐隐。
///
/// 和 BMP 的 32bpp 样图刻意画同一个形状：两种格式表达同一张图，解出来的
/// 像素应该几乎一样。这类跨格式对照比单格式自证更有说服力。
Uint8List pngRgba8Disc() {
  const int n = 64;
  const double r = 30;
  final List<List<int>> rows = <List<int>>[];
  for (int y = 0; y < n; y++) {
    final List<int> row = <int>[];
    for (int x = 0; x < n; x++) {
      final double dx = x - (n - 1) / 2;
      final double dy = y - (n - 1) / 2;
      final double d = math.sqrt(dx * dx + dy * dy);
      // 圆内不透明，边缘一圈线性渐隐，圆外全透明。
      final int a = d >= r ? 0 : (d <= r - 8 ? 255 : ((r - d) / 8 * 255).round());
      row.addAll(<int>[
        x * 255 ~/ (n - 1),
        y * 255 ~/ (n - 1),
        200,
        a,
      ]);
    }
    rows.add(row);
  }
  return buildPng(
    width: n,
    height: n,
    bitDepth: 8,
    colorType: 6,
    rows: rows,
  );
}

/// 8 位调色板 + tRNS，64×48。
///
/// tRNS 故意只给前 8 项，剩下的项按规范默认为 255（不透明）。「缺的项
/// 补 0」是常见的写反 —— 那会让大半张图凭空变透明。
Uint8List pngPalette8() {
  const int w = 64, h = 48;
  const int entries = 32;
  final List<int> plte = <int>[];
  for (int i = 0; i < entries; i++) {
    // 一圈色相环，用整数算，不引入浮点色彩空间转换。
    final int seg = i * 6 ~/ entries;
    final int t = (i * 6 % entries) * 255 ~/ entries;
    plte.addAll(switch (seg) {
      0 => <int>[255, t, 0],
      1 => <int>[255 - t, 255, 0],
      2 => <int>[0, 255, t],
      3 => <int>[0, 255 - t, 255],
      4 => <int>[t, 0, 255],
      _ => <int>[255, 0, 255 - t],
    });
  }
  final List<List<int>> rows = <List<int>>[];
  for (int y = 0; y < h; y++) {
    rows.add(List<int>.generate(w, (int x) => (x * entries ~/ w)));
  }
  return buildPng(
    width: w,
    height: h,
    bitDepth: 8,
    colorType: 3,
    rows: rows,
    palette: plte,
    transparency: List<int>.generate(8, (int i) => i * 32),
  );
}

/// 16 位灰度渐变，64×64。
///
/// 每个采样两字节大端。这张图存在的意义是验证 16 → 8 的降位：低字节
/// 若被直接丢弃（而不是四舍五入），渐变上会出现规律的台阶。
Uint8List pngGray16() {
  const int n = 64;
  final List<List<int>> rows = <List<int>>[];
  for (int y = 0; y < n; y++) {
    final List<int> row = <int>[];
    for (int x = 0; x < n; x++) {
      final int v = (y * n + x) * 65535 ~/ (n * n - 1);
      row.addAll(<int>[(v >> 8) & 0xFF, v & 0xFF]);
    }
    rows.add(row);
  }
  return buildPng(width: n, height: n, bitDepth: 16, colorType: 0, rows: rows);
}

/// 1 位灰度棋盘，一格 5 像素，35×24。
///
/// 宽度 35 不是 8 的倍数，故意的：每行 5 字节里最后 5 位是填充。行与行
/// **不共享**字节，填充位的值无所谓 —— 若解码器把它们当像素，右边会多出
/// 一条杂边。
///
/// 位序是 MSB 先：一字节的最高位是最左边那个像素。这和 deflate 数据字段
/// 的 LSB 先正好相反，同一个文件里两种位序并存。
Uint8List pngGray1() {
  const int w = 35, h = 24;
  final List<List<int>> rows = <List<int>>[];
  for (int y = 0; y < h; y++) {
    final List<int> row = List<int>.filled((w + 7) ~/ 8, 0);
    for (int x = 0; x < w; x++) {
      final bool on = ((x ~/ 5) + (y ~/ 5)) % 2 == 0;
      if (on) {
        row[x >> 3] |= 0x80 >> (x & 7);
      }
    }
    rows.add(row);
  }
  return buildPng(width: w, height: h, bitDepth: 1, colorType: 0, rows: rows);
}

/// Adam7 隔行的 RGB8 同心环，64×64。
///
/// 隔行图的原始数据比非隔行的**更大** —— 七遍各自把行填充到字节边界，
/// 填充累计起来超过了隔行带来的任何好处。Adam7 换来的是「下载一半就能看
/// 出轮廓」，不是体积。
Uint8List pngInterlaced() {
  const int n = 64;
  final List<List<int>> rows = <List<int>>[];
  for (int y = 0; y < n; y++) {
    final List<int> row = <int>[];
    for (int x = 0; x < n; x++) {
      final double dx = x - (n - 1) / 2;
      final double dy = y - (n - 1) / 2;
      final int d = math.sqrt(dx * dx + dy * dy).round();
      final bool ring = (d ~/ 4) % 2 == 0;
      row.addAll(ring
          ? <int>[240, 60 + d * 2, 30]
          : <int>[30, 30, 120 + d * 2]);
    }
    rows.add(row);
  }
  return buildPng(
    width: n,
    height: n,
    bitDepth: 8,
    colorType: 2,
    rows: rows,
    interlace: true,
  );
}

// ———————————————————————————————————————————————————————————————
// 入口
// ———————————————————————————————————————————————————————————————

void main() {
  final Directory dir = Directory('assets/samples');
  dir.createSync(recursive: true);

  // 文件名里带上关键参数。对 BMP / PNM 只是方便识别，
  // 对 YUV 则是**必需的** —— 裸流没有头部，宽高和格式只能靠文件名传达。
  // 这也是现实中处理 .yuv 文件的通行做法。
  final Map<String, Uint8List> samples = <String, Uint8List>{
    'gradient_61x40_24bpp.bmp': bmp24Gradient(),
    'topdown_61x40_24bpp.bmp': bmp24TopDown(),
    'rainbow_128x40_8bpp.bmp': bmp8Palette(),
    'bands_80x32_rle8.bmp': bmp8Rle(),
    'circle_64x64_32bpp.bmp': bmp32Alpha(),
    'gradient_64x48.ppm': pnmP6(),
    'tiny_8x8_ascii.ppm': pnmP3(),
    'gradient_64x32.pgm': pnmP5(),
    'ramp_16x8_ascii.pgm': pnmP2(),
    'checker_20x16.pbm': pnmP4(),
    'ring_16x16_ascii.pbm': pnmP1(),
    'colorbars_96x64_i420_3frames.yuv': yuvColorBars(),
    'gradient_96x64_rgb8.png': pngRgb8Gradient(),
    'disc_64x64_rgba8.png': pngRgba8Disc(),
    'hues_64x48_palette8.png': pngPalette8(),
    'ramp_64x64_gray16.png': pngGray16(),
    'checker_35x24_gray1.png': pngGray1(),
    'rings_64x64_adam7.png': pngInterlaced(),
  };

  final List<String> names = samples.keys.toList()..sort();
  for (final String name in names) {
    final Uint8List bytes = samples[name]!;
    File('${dir.path}/$name').writeAsBytesSync(bytes);
    stdout.writeln('${name.padRight(36)} ${bytes.length} 字节');
  }
  stdout.writeln('\n共 ${samples.length} 个样图 → ${dir.path}/');
}
