/// PNG 的枚举字段：色彩类型、filter 类型、隔行方式。
///
/// 单独成文件是因为这三个枚举各自都带着**合法性规则**，而不只是数字到
/// 名字的映射。规则写在枚举里，解码器就不必到处散落 if 判断。
library;

import 'package:image_viewer/src/core/errors.dart';

/// PNG 色彩类型（IHDR 第 10 字节）。
///
/// ## 编号为什么是 0/2/3/4/6 这样跳着的
///
/// 因为它是**位标志的组合**，不是顺序编号：
///
/// ```
/// bit 0 (值 1) = 使用调色板
/// bit 1 (值 2) = 彩色（否则灰度）
/// bit 2 (值 4) = 带 alpha 通道
/// ```
///
/// 于是 2 = 彩色，3 = 彩色+调色板，4 = 灰度+alpha，6 = 彩色+alpha。
/// 1（只有调色板没有彩色）和 5（调色板+alpha）没有定义 —— 调色板本身就
/// 隐含彩色，而调色板的透明度走 `tRNS` chunk 而不是第四通道。
///
/// 看懂这一点，"为什么没有色彩类型 1 和 5" 就不再是需要死记的事。
enum PngColorType {
  /// 0：灰度。每像素一个样本。
  grayscale(0, 1, <int>[1, 2, 4, 8, 16], '灰度'),

  /// 2：真彩色。每像素 R/G/B 三个样本。
  rgb(2, 3, <int>[8, 16], '真彩色 RGB'),

  /// 3：调色板。每像素一个索引，查 `PLTE` 得到 RGB。
  ///
  /// 注意位深指的是**索引的位数**，不是颜色的位数 —— 调色板项恒为 8 位/通道。
  /// 所以 `bitDepth: 4` 的调色板图有 16 种颜色，每种都是 24 位色。
  palette(3, 1, <int>[1, 2, 4, 8], '调色板'),

  /// 4：灰度 + alpha。每像素两个样本。
  grayscaleAlpha(4, 2, <int>[8, 16], '灰度 + alpha'),

  /// 6：真彩色 + alpha。每像素四个样本，与我们的 RGBA 输出天然对齐。
  rgba(6, 4, <int>[8, 16], '真彩色 RGBA');

  const PngColorType(
    this.value,
    this.channels,
    this.allowedBitDepths,
    this.description,
  );

  /// IHDR 里的数值。
  final int value;

  /// 每像素的样本数。调色板是 1（一个索引）。
  final int channels;

  /// 规范允许的位深。**这张表是硬性约束**，见 [validateBitDepth]。
  final List<int> allowedBitDepths;

  /// 中文描述，显示在信息面板上。
  final String description;

  /// 是否自带 alpha 通道。
  ///
  /// 调色板图返回 false —— 它的透明度来自 `tRNS`，不是第四个样本。
  bool get hasAlpha =>
      this == PngColorType.grayscaleAlpha || this == PngColorType.rgba;

  /// 是否是调色板图（需要 `PLTE`）。
  bool get isIndexed => this == PngColorType.palette;

  /// 是否是灰度图（灰度或灰度+alpha）。
  bool get isGrayscale =>
      this == PngColorType.grayscale || this == PngColorType.grayscaleAlpha;

  static PngColorType fromValue(int value, {int? offset}) {
    for (final PngColorType t in PngColorType.values) {
      if (t.value == value) {
        return t;
      }
    }
    throw ImageDecodeException(
      '色彩类型 $value 未定义（合法值 0/2/3/4/6；'
      '1 和 5 从未被定义过，因为色彩类型是位标志组合）',
      format: 'PNG',
      offset: offset,
    );
  }

  /// 校验位深与色彩类型的组合是否合法。
  ///
  /// 单看位深合法（1/2/4/8/16）不够 —— 组合才是规范约束的对象。比如
  /// 1 位真彩色说不通（三个通道各 1 位？），16 位调色板也说不通
  /// （索引最多 8 位，因为调色板最多 256 项）。
  void validateBitDepth(int bitDepth, {int? offset}) {
    if (!allowedBitDepths.contains(bitDepth)) {
      throw ImageDecodeException(
        '$description（色彩类型 $value）不允许位深 $bitDepth，'
        '只能是 ${allowedBitDepths.join(" / ")}',
        format: 'PNG',
        offset: offset,
      );
    }
  }
}

/// 每条扫描线开头那个字节：本行用了哪种 filter。
///
/// filter 是 PNG 压缩率的一半来源。它不压缩数据，而是**把数据变得更好压**：
/// 相邻像素往往接近，做差之后大量字节变成 0 附近的小值，deflate 的 Huffman
/// 就能给它们很短的码字。详见 `png_filters.dart`。
enum PngFilterType {
  /// 0：原样，不做差。
  none(0, '无'),

  /// 1：减左边的像素。
  sub(1, 'Sub（减左）'),

  /// 2：减上一行同列。
  up(2, 'Up（减上）'),

  /// 3：减「左与上的平均」。
  average(3, 'Average（减左上均值）'),

  /// 4：减 Paeth 预测值。
  paeth(4, 'Paeth（三点预测）');

  const PngFilterType(this.value, this.description);

  final int value;
  final String description;

  static PngFilterType fromValue(int value, {int? offset, int? row}) {
    for (final PngFilterType t in PngFilterType.values) {
      if (t.value == value) {
        return t;
      }
    }
    throw ImageDecodeException(
      '第 $row 行的 filter 类型 $value 未定义（合法值 0..4）。'
      '常见原因：行字节数算错了，导致读到的不是 filter 字节而是像素数据',
      format: 'PNG',
      offset: offset,
    );
  }
}

/// 隔行方式（IHDR 最后一字节）。
enum PngInterlaceMethod {
  /// 0：逐行顺序存储。
  none(0, '无'),

  /// 1：Adam7 七遍隔行，图片从模糊到清晰渐显。
  adam7(1, 'Adam7 隔行');

  const PngInterlaceMethod(this.value, this.description);

  final int value;
  final String description;

  static PngInterlaceMethod fromValue(int value, {int? offset}) {
    for (final PngInterlaceMethod m in PngInterlaceMethod.values) {
      if (m.value == value) {
        return m;
      }
    }
    throw ImageDecodeException(
      '隔行方式 $value 未定义（只有 0=无 与 1=Adam7）',
      format: 'PNG',
      offset: offset,
    );
  }
}
