/// 把已还原滤波的 PNG 行数据展开成 RGBA8888。
///
/// ## 五种色彩类型 × 五种位深 = 十五种合法组合
///
/// 不是 5 × 5 = 25：只有灰度（类型 0）支持全部五种位深，调色板（类型 3）
/// 没有 16 位（索引本来就不缩放，16 位索引意味着 65536 色的调色板，而
/// `PLTE` 最多 256 项），其余三种带彩色通道的只支持 8 和 16 位。
/// 5 + 2 + 4 + 2 + 2 = 15。
///
/// 直接为每种组合写一份循环会得到十五段近乎重复的代码。这里改用
/// 「统一取采样 + 按类型组装」两步：`_sampleAt` 负责把任意位深的第 k 个
/// 采样取出来（返回原始值），组装循环负责按色彩类型决定这些采样是
/// 灰度、RGB 还是索引。
///
/// 代价是热路径上多一层函数调用。对这个项目值得 —— 十五份手写循环里
/// 藏一个位移方向写反的 bug，比慢一点难查得多。
///
/// ## 缩放：为什么不是简单的右移
///
/// 4 位深的 15 要变成 8 位的 255。右移是反的（要左移），左移 4 位得到
/// 240 —— 最白的白变成了浅灰。正确做法是按比例缩放：`v * 255 / 15`。
///
/// 巧的是位深 1/2/4 时 255 恰好能被 maxValue 整除（255、85、17），
/// 所以是精确的整数乘法，等价于「把该位深的位模式重复填满 8 位」。
/// 只有 16→8 位需要真正的除法与四舍五入，取整方式与 PNM 解码器
/// 的 `scaleToByte` 保持一致。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/png/png_palette.dart';
import 'package:image_viewer/src/codecs/png/png_types.dart';

/// 取一行里第 [index] 个采样的原始值（未缩放）。
///
/// [bitDepth] 为 1/2/4 时按**高位在前**从字节里取 —— PNG 的位序是
/// MSB first，一个字节里的第一个像素在最高位。这和 BMP 的 4 位/1 位
/// 位图一致，也和 deflate 的 LSB first 位序相反（同一个文件里两种位序
/// 并存，这是写 PNG 解码器时最容易搞混的地方之一）。
int sampleAt(Uint8List row, int index, int bitDepth) {
  switch (bitDepth) {
    case 8:
      return row[index];
    case 16:
      // 大端序双字节。用乘法而不是 `<< 8`，与项目其他地方保持一致。
      return row[index * 2] * 256 + row[index * 2 + 1];
    case 4:
      final int b = row[index >> 1];
      return (index & 1) == 0 ? (b >> 4) & 0x0F : b & 0x0F;
    case 2:
      final int b = row[index >> 2];
      // index & 3 = 0 时取最高的两位，故位移 6、4、2、0。
      return (b >> (6 - (index & 3) * 2)) & 0x03;
    case 1:
      final int b = row[index >> 3];
      return (b >> (7 - (index & 7))) & 0x01;
    default:
      // PngColorType.validateBitDepth 已经拦掉了其他值，走到这里
      // 说明是内部错误而不是文件问题。
      throw StateError('非法位深 $bitDepth');
  }
}

/// 把原始采样缩放到 0..255。
int scaleSample(int value, int bitDepth) {
  switch (bitDepth) {
    case 8:
      return value;
    case 16:
      // 四舍五入，与 pnm_header.dart 的 scaleToByte 同一套算法。
      return (value * 255 + 32767) ~/ 65535;
    case 4:
      return value * 17; // 255 / 15
    case 2:
      return value * 85; // 255 / 3
    case 1:
      return value * 255;
    default:
      throw StateError('非法位深 $bitDepth');
  }
}

/// 一行数据的展开参数。
class PixelExpander {
  PixelExpander({
    required this.colorType,
    required this.bitDepth,
    this.palette,
    this.colorKey,
  });

  final PngColorType colorType;
  final int bitDepth;
  final PngPalette? palette;
  final PngColorKey? colorKey;

  /// 是否有像素因关键色或 tRNS 而透明。解码后写进元数据。
  bool sawTransparency = false;

  /// 把 [row] 里的 [count] 个像素写入 [out]。
  ///
  /// 写入位置由 [dstIndex]（目标首像素的线性下标）与 [dstStep]（相邻两个
  /// 源像素在目标里隔几个像素）决定 —— 隔行扫描时步长就是该 pass 的
  /// `xStep`，非隔行时是 1。于是隔行和非隔行共用同一段展开代码。
  void expandRow(
    Uint8List row,
    Uint8List out, {
    required int count,
    required int dstIndex,
    required int dstStep,
  }) {
    int dst = dstIndex * 4;
    final int stride = dstStep * 4;

    switch (colorType) {
      case PngColorType.grayscale:
        final int? key = colorKey?.gray;
        for (int i = 0; i < count; i++) {
          final int raw = sampleAt(row, i, bitDepth);
          final int g = scaleSample(raw, bitDepth);
          int a = 255;
          if (key != null && raw == key) {
            a = 0;
            sawTransparency = true;
          }
          out[dst] = g;
          out[dst + 1] = g;
          out[dst + 2] = g;
          out[dst + 3] = a;
          dst += stride;
        }

      case PngColorType.rgb:
        final PngColorKey? key = colorKey;
        for (int i = 0; i < count; i++) {
          final int r = sampleAt(row, i * 3, bitDepth);
          final int g = sampleAt(row, i * 3 + 1, bitDepth);
          final int b = sampleAt(row, i * 3 + 2, bitDepth);
          int a = 255;
          if (key != null && r == key.red && g == key.green && b == key.blue) {
            a = 0;
            sawTransparency = true;
          }
          out[dst] = scaleSample(r, bitDepth);
          out[dst + 1] = scaleSample(g, bitDepth);
          out[dst + 2] = scaleSample(b, bitDepth);
          out[dst + 3] = a;
          dst += stride;
        }

      case PngColorType.palette:
        final PngPalette p = palette!;
        for (int i = 0; i < count; i++) {
          // 索引不缩放 —— 它是编号不是亮度。这是唯一一个不该缩放
          // 采样值的类型，缩放了就会查到完全无关的颜色。
          final int index = sampleAt(row, i, bitDepth);
          p.checkIndex(index);
          out[dst] = p.red(index);
          out[dst + 1] = p.green(index);
          out[dst + 2] = p.blue(index);
          final int a = p.alpha(index);
          out[dst + 3] = a;
          if (a != 255) {
            sawTransparency = true;
          }
          dst += stride;
        }

      case PngColorType.grayscaleAlpha:
        for (int i = 0; i < count; i++) {
          final int g = scaleSample(sampleAt(row, i * 2, bitDepth), bitDepth);
          final int a =
              scaleSample(sampleAt(row, i * 2 + 1, bitDepth), bitDepth);
          out[dst] = g;
          out[dst + 1] = g;
          out[dst + 2] = g;
          out[dst + 3] = a;
          if (a != 255) {
            sawTransparency = true;
          }
          dst += stride;
        }

      case PngColorType.rgba:
        for (int i = 0; i < count; i++) {
          final int base = i * 4;
          out[dst] = scaleSample(sampleAt(row, base, bitDepth), bitDepth);
          out[dst + 1] =
              scaleSample(sampleAt(row, base + 1, bitDepth), bitDepth);
          out[dst + 2] =
              scaleSample(sampleAt(row, base + 2, bitDepth), bitDepth);
          final int a =
              scaleSample(sampleAt(row, base + 3, bitDepth), bitDepth);
          out[dst + 3] = a;
          if (a != 255) {
            sawTransparency = true;
          }
          dst += stride;
        }
    }
  }
}
