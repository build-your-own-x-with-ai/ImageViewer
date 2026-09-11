/// PNG 的五种行滤波器（逆向）。
///
/// ## 滤波器不压缩，它只是把数据变得好压
///
/// 一张渐变图的一行像素可能是 `100 102 104 106 108`，五个各不相同的
/// 字节，deflate 找不到重复，压不动。但如果每个字节都减去左邻居，
/// 变成 `100 2 2 2 2` —— 一串重复的 2，deflate 一下就吃掉了。
///
/// 这就是滤波器的全部作用：**它一个字节都不省，只是把「数值相近」
/// 改写成「数值重复」，让后面的 deflate 有东西可压**。所以滤波器输出
/// 的长度和输入完全一样，PNG 的压缩率却能因它翻倍。
///
/// 图像数据里相邻像素相近，这是几乎所有图像格式都在利用的先验。
/// JPEG 用 DCT，WebP 用预测模式，PNG 用的就是这五个减法。
///
/// ## 逆向时的关键约束
///
/// 编码时可以任选滤波器；解码时**必须**按行首那个字节指定的方式还原。
/// 而且还原是**串行**的：第 n 行要用已还原的第 n-1 行做参考，所以不能
/// 并行处理，也不能跳着解。这是 PNG 无法随机访问某一行的根本原因。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/png/png_types.dart';

/// Paeth 预测器。
///
/// ## 三个邻居里挑一个，而不是求平均
///
/// 给定左邻 [a]、上邻 [b]、左上 [c]，先算 `p = a + b - c`（把三点当作
/// 一个平面来线性外推），然后返回 a、b、c 里**离 p 最近**的那个。
///
/// 注意它返回的是三者之一，不是算出来的 p。这个设计很妙：在边缘处
/// 平均值会跨过边界把两侧混在一起，而「挑最近的一个」会自动选中边缘
/// 同一侧的邻居 —— 于是它在平坦区域表现和 Average 相当，在边缘处明显
/// 更好。Alan Paeth 1991 年提出，PNG 采纳它作为第五种滤波器。
///
/// 平局时按 a、b、c 的顺序取先者。这个顺序是规范强制的：编码器和解码器
/// 必须在平局时做出同样的选择，否则解出来就是错的。
int paethPredictor(int a, int b, int c) {
  final int p = a + b - c;
  final int pa = (p - a).abs();
  final int pb = (p - b).abs();
  final int pc = (p - c).abs();
  if (pa <= pb && pa <= pc) {
    return a;
  }
  return pb <= pc ? b : c;
}

/// 就地还原一行滤波数据。
///
/// [row] 是当前行的图像字节（**不含**行首的滤波器类型字节），函数直接
/// 在它上面改写。[prev] 是已还原的上一行；第一行传 `null`。
/// [bytesPerPixel] 是滤波单元距离，见 `PngHeader.bytesPerPixel`。
///
/// ## 为什么第一行不需要特殊的滤波器
///
/// 第一行没有上邻居，但规范没有为它定义专门的滤波器 —— 而是规定
/// **越界的邻居一律当 0**。于是第一行用 Up 滤波器就等于什么都不做，
/// 用 Paeth 就退化成 Sub。编码器可以放心地对任意行选任意滤波器，
/// 解码器也不必为第一行写分支。
///
/// 同理，每行最左边的像素其左邻居也当 0。这条「越界补零」的约定让
/// 五个滤波器的实现都不需要边界判断，只需要把 prev 传 null、
/// 把 i < bytesPerPixel 的部分单独处理。
void unfilterRow(
  Uint8List row,
  Uint8List? prev,
  int bytesPerPixel,
  PngFilterType filter,
) {
  final int n = row.length;
  final int bpp = bytesPerPixel;

  switch (filter) {
    case PngFilterType.none:
      // 原样存储。编码器在数据本就杂乱无章时选它 —— 滤波帮不上忙的话
      // 就别添乱。
      break;

    case PngFilterType.sub:
      // 减左邻。从 bpp 开始：前 bpp 个字节的左邻越界当 0，即保持原值。
      for (int i = bpp; i < n; i++) {
        row[i] = (row[i] + row[i - bpp]) & 0xFF;
      }

    case PngFilterType.up:
      // 减上邻。第一行 prev 为 null，上邻全 0，什么都不用做。
      if (prev != null) {
        for (int i = 0; i < n; i++) {
          row[i] = (row[i] + prev[i]) & 0xFF;
        }
      }

    case PngFilterType.average:
      // 减 (左 + 上) / 2，向下取整。
      //
      // 注意这里必须用 `~/ 2` 而不是 `>> 1` 之外的任何写法：和是
      // 两个字节相加，最大 510，在 Dart 里不会溢出。但用 C 写 PNG
      // 时如果拿 uint8 存这个和就会翻车 —— 这是移植时的经典坑。
      if (prev == null) {
        for (int i = bpp; i < n; i++) {
          row[i] = (row[i] + (row[i - bpp] ~/ 2)) & 0xFF;
        }
      } else {
        for (int i = 0; i < bpp; i++) {
          row[i] = (row[i] + (prev[i] ~/ 2)) & 0xFF;
        }
        for (int i = bpp; i < n; i++) {
          row[i] = (row[i] + ((row[i - bpp] + prev[i]) ~/ 2)) & 0xFF;
        }
      }

    case PngFilterType.paeth:
      if (prev == null) {
        // 上邻和左上都是 0，paeth(a, 0, 0) 恒等于 a，退化成 Sub。
        for (int i = bpp; i < n; i++) {
          row[i] = (row[i] + row[i - bpp]) & 0xFF;
        }
      } else {
        // 前 bpp 个字节：左邻和左上都越界当 0，
        // paeth(0, b, 0) = b，退化成 Up。
        for (int i = 0; i < bpp; i++) {
          row[i] = (row[i] + prev[i]) & 0xFF;
        }
        for (int i = bpp; i < n; i++) {
          row[i] = (row[i] +
                  paethPredictor(row[i - bpp], prev[i], prev[i - bpp])) &
              0xFF;
        }
      }
  }
}

/// 各滤波器的使用行数统计。
///
/// 纯粹为教学模式的信息面板服务 —— 看一眼某张图里 Paeth 占了多大比例，
/// 比读一段解释更能说明这五个滤波器谁更有用。隔行图把七遍的行数累加
/// 在一起。
class FilterStats {
  /// 各滤波器的使用行数，下标即 [PngFilterType.value]。
  final List<int> counts = List<int>.filled(5, 0);

  /// 总行数。
  int total = 0;

  void record(PngFilterType filter) {
    counts[filter.value]++;
    total++;
  }

  /// 人类可读的用量摘要，如 `'none×1, paeth×15'`。
  String get summary {
    final List<String> parts = <String>[];
    for (final PngFilterType f in PngFilterType.values) {
      final int c = counts[f.value];
      if (c > 0) {
        parts.add('${f.name}×$c');
      }
    }
    return parts.isEmpty ? '无' : parts.join(', ');
  }
}

