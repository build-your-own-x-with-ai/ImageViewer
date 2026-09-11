/// Adam7 隔行扫描的几何计算。
///
/// ## 为什么会有隔行
///
/// 1996 年的调制解调器下一张 50KB 的图要十几秒。隔行让浏览器在收到
/// 1/64 的数据时就能显示一张模糊的全图，随着数据到达逐步变清晰 ——
/// 用户不用盯着一条一条往下长的图等。
///
/// 代价是压缩率降低约 5%（每个 pass 独立滤波，跨 pass 的相关性被切断），
/// 而且解码器必须把七遍数据拼回一张图。宽带普及后这个功能基本没人用了，
/// 但规范里它是**关键**特性 —— 不支持就不能声称支持 PNG。
///
/// ## 七个 pass 的排布
///
/// 把图像划成 8×8 的格子，每个格子里的 64 个位置按下表编号，第 n 个
/// pass 取走所有标着 n 的位置：
///
/// ```
/// 1 6 4 6 2 6 4 6
/// 7 7 7 7 7 7 7 7
/// 5 6 5 6 5 6 5 6
/// 7 7 7 7 7 7 7 7
/// 3 6 4 6 3 6 4 6
/// 7 7 7 7 7 7 7 7
/// 5 6 5 6 5 6 5 6
/// 7 7 7 7 7 7 7 7
/// ```
///
/// 数一下就能看出各 pass 的像素占比：1/64, 1/64, 2/64, 4/64, 8/64,
/// 16/64, 32/64 —— 每一遍的数据量大致是之前所有遍的总和，所以清晰度
/// 提升的观感是均匀的。最后一遍（全部奇数行）就占了一半数据。
///
/// 名字来自 Adam M. Costello，他把早期方案的七遍布局定了下来。
library;

import 'package:image_viewer/src/codecs/png/png_header.dart';
import 'package:image_viewer/src/codecs/png/png_types.dart';

/// 一遍扫描的几何参数。
///
/// 非隔行图也用它表示（步长 1、偏移 0 的单遍），这样解码主循环
/// 不必为隔行与否分叉。
class Adam7Pass {
  const Adam7Pass({
    required this.index,
    required this.xOffset,
    required this.yOffset,
    required this.xStep,
    required this.yStep,
  });

  /// 第几遍，从 1 起；非隔行的单遍记 0。
  final int index;

  final int xOffset;
  final int yOffset;
  final int xStep;
  final int yStep;

  /// 本遍的像素宽度。
  ///
  /// ## 这里是 PNG 解码器最经典的一个 bug
  ///
  /// 必须**按本遍宽度重新算**每行字节数，不能沿用整图的。举个例子：
  /// 8×8 的 RGB8 图整行 24 字节，但第 1 遍只有 1 个像素宽，那一行是
  /// 3 字节。沿用 24 会让滤波和拼接同时错位，症状是图像出现斜向的
  /// 撕裂 —— 而且小图上未必看得出来，正好躲过草率的测试。
  ///
  /// 向上取整：宽 5 时第 1 遍（偏移 0 步长 8）取到第 0 列，宽度 1。
  int widthFor(int imageWidth) {
    if (imageWidth <= xOffset) {
      return 0;
    }
    return (imageWidth - xOffset + xStep - 1) ~/ xStep;
  }

  /// 本遍的像素行数。
  int heightFor(int imageHeight) {
    if (imageHeight <= yOffset) {
      return 0;
    }
    return (imageHeight - yOffset + yStep - 1) ~/ yStep;
  }

  /// 本遍每行的字节数（不含滤波器类型字节）。
  int bytesPerRowFor(int imageWidth, int bitsPerPixel) =>
      (widthFor(imageWidth) * bitsPerPixel + 7) ~/ 8;

  /// 本遍在解压流里占的字节数，含每行行首的滤波器类型字节。
  ///
  /// 宽或高为 0 的 pass 一个字节都不占 —— 连滤波器类型字节都没有。
  /// 小图（比如 1×1）会有好几个空 pass，漏掉这个判断就会把后面的
  /// 数据全部读偏。
  int rawSizeFor(int imageWidth, int imageHeight, int bitsPerPixel) {
    final int h = heightFor(imageHeight);
    if (h == 0 || widthFor(imageWidth) == 0) {
      return 0;
    }
    return h * (bytesPerRowFor(imageWidth, bitsPerPixel) + 1);
  }

  @override
  String toString() => 'Adam7Pass($index, 偏移 ($xOffset,$yOffset), '
      '步长 ($xStep,$yStep))';
}

/// Adam7 的七遍参数，顺序即解码顺序。
const List<Adam7Pass> kAdam7Passes = <Adam7Pass>[
  Adam7Pass(index: 1, xOffset: 0, yOffset: 0, xStep: 8, yStep: 8),
  Adam7Pass(index: 2, xOffset: 4, yOffset: 0, xStep: 8, yStep: 8),
  Adam7Pass(index: 3, xOffset: 0, yOffset: 4, xStep: 4, yStep: 8),
  Adam7Pass(index: 4, xOffset: 2, yOffset: 0, xStep: 4, yStep: 4),
  Adam7Pass(index: 5, xOffset: 0, yOffset: 2, xStep: 2, yStep: 4),
  Adam7Pass(index: 6, xOffset: 1, yOffset: 0, xStep: 2, yStep: 2),
  Adam7Pass(index: 7, xOffset: 0, yOffset: 1, xStep: 1, yStep: 2),
];

/// 非隔行图的等价单遍：从 (0,0) 起，步长 1，即逐行逐像素。
const Adam7Pass kSinglePass =
    Adam7Pass(index: 0, xOffset: 0, yOffset: 0, xStep: 1, yStep: 1);

/// 取本图应走的扫描遍序列。
///
/// 已剔除宽或高为 0 的空 pass，调用方拿到的每一遍都有实际数据。
List<Adam7Pass> passesFor(PngHeader header) {
  if (header.interlace == PngInterlaceMethod.none) {
    return const <Adam7Pass>[kSinglePass];
  }
  return kAdam7Passes
      .where((Adam7Pass p) =>
          p.widthFor(header.width) > 0 && p.heightFor(header.height) > 0)
      .toList(growable: false);
}

/// 解压流应有的总字节数。
///
/// 这个值给 inflate 当硬上限用：解压结果超出它就说明数据有问题，
/// 顺便也挡住了解压炸弹。
int expectedRawSize(PngHeader header) {
  if (header.interlace == PngInterlaceMethod.none) {
    return header.rawSize;
  }
  int total = 0;
  for (final Adam7Pass p in kAdam7Passes) {
    total += p.rawSizeFor(header.width, header.height, header.bitsPerPixel);
  }
  return total;
}
