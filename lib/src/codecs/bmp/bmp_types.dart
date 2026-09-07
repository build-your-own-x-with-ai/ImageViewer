import 'package:image_viewer/src/core/errors.dart';

/// BMP 的 DIB 头部版本，由头部第一个 u32 字段（头部自身长度）区分。
///
/// BMP 是「同一个扩展名下藏着五代格式」的典型例子。判据只有一个：
/// 头部长度。这个设计的好处是解码器可以只认识老版本也能工作（多出来的
/// 字段直接跳过），代价是必须按长度分派，不能靠版本号。
enum BmpHeaderVersion {
  /// 12 字节，OS/2 1.x。宽高是 **u16**，调色板每项 **3 字节**。
  core(12, 'BITMAPCOREHEADER (OS/2 1.x)'),

  /// 40 字节，Windows 3.0。绝大多数 BMP 是这一版。
  info(40, 'BITMAPINFOHEADER (Windows 3.0)'),

  /// 52 字节，加了 RGB 掩码字段。
  v2(52, 'BITMAPV2INFOHEADER'),

  /// 56 字节，再加 alpha 掩码字段。
  v3(56, 'BITMAPV3INFOHEADER'),

  /// 108 字节，加了色彩空间类型、端点、gamma。
  v4(108, 'BITMAPV4HEADER'),

  /// 124 字节，加了渲染意图与 ICC 配置文件。
  v5(124, 'BITMAPV5HEADER');

  const BmpHeaderVersion(this.byteSize, this.description);

  /// 头部长度，也是识别依据。
  final int byteSize;

  /// 中文/英文描述，显示在信息面板上。
  final String description;

  /// 调色板每项占几字节。
  ///
  /// CORE 版是 3 字节的 RGB 三元组，之后各版都是 4 字节（BGRA，
  /// 第四字节通常为 0 且被忽略）。这是 CORE 版最容易漏掉的差异。
  int get paletteEntrySize => this == BmpHeaderVersion.core ? 3 : 4;

  /// 是否自带 RGB/alpha 掩码字段（V2 及以后）。
  bool get hasInlineMasks => byteSize >= BmpHeaderVersion.v2.byteSize;

  /// 是否自带 alpha 掩码字段（V3 及以后）。
  bool get hasInlineAlphaMask => byteSize >= BmpHeaderVersion.v3.byteSize;

  static BmpHeaderVersion fromSize(int size) {
    for (final BmpHeaderVersion v in BmpHeaderVersion.values) {
      if (v.byteSize == size) {
        return v;
      }
    }
    throw ImageDecodeException(
      'DIB 头部长度 $size 不是已知版本'
      '（应为 12/40/52/56/108/124 之一）',
      format: 'BMP',
      offset: 14,
    );
  }
}

/// BMP 的压缩方式。
enum BmpCompression {
  /// 0：无压缩，像素直排。
  rgb(0, '无'),

  /// 1：8 位游程编码，仅用于 8bpp。
  rle8(1, 'RLE8 游程编码'),

  /// 2：4 位游程编码，仅用于 4bpp。
  rle4(2, 'RLE4 游程编码'),

  /// 3：无压缩，但通道位置由头部的掩码字段指定。
  bitfields(3, '无（自定义通道掩码）'),

  /// 4：像素数据是一整个 JPEG 文件。极罕见，本项目不支持。
  jpeg(4, '内嵌 JPEG'),

  /// 5：像素数据是一整个 PNG 文件。极罕见，本项目不支持。
  png(5, '内嵌 PNG'),

  /// 6：同 [bitfields] 但含 alpha 掩码，Windows CE 专有。
  alphaBitfields(6, '无（自定义通道掩码含 alpha）');

  const BmpCompression(this.code, this.description);

  final int code;
  final String description;

  /// 是否是游程编码。
  bool get isRle =>
      this == BmpCompression.rle8 || this == BmpCompression.rle4;

  /// 是否用掩码指定通道位置。
  bool get usesMasks =>
      this == BmpCompression.bitfields ||
      this == BmpCompression.alphaBitfields;

  static BmpCompression fromCode(int code) {
    for (final BmpCompression c in BmpCompression.values) {
      if (c.code == code) {
        return c;
      }
    }
    throw ImageDecodeException(
      '未知的压缩方式代码 $code',
      format: 'BMP',
    );
  }
}

/// 一个通道的位掩码，把任意位置的若干位抽出来并缩放到 0..255。
///
/// ## 为什么需要它
///
/// `BI_BITFIELDS` 让文件自己声明每个通道占哪几位。常见的是
/// RGB555（各 5 位）、RGB565（绿 6 位）、BGRA8888，但规范允许**任意**
/// 掩码 —— 见过 4-4-4-4 的，也见过通道顺序颠倒的。
///
/// 所以不能为每种排列写一个分支，必须参数化：从掩码算出移位量与位宽，
/// 然后统一处理。
class ChannelMask {
  ChannelMask(this.mask)
      : shift = _trailingZeros(mask),
        width = _popCount(mask) {
    if (mask == 0) {
      return; // 空掩码表示该通道不存在（如 16bpp 无 alpha）
    }
    // 校验掩码是连续的一段 1。规范没明确禁止不连续，但现实中不存在，
    // 而支持它会让缩放逻辑复杂一大截。宁可明确拒绝也不要悄悄算错。
    final int normalized = mask >> shift;
    if ((normalized & (normalized + 1)) != 0) {
      throw ImageDecodeException(
        '通道掩码 0x${mask.toRadixString(16)} 不是连续的位段，暂不支持',
        format: 'BMP',
      );
    }
    if (width > 16) {
      throw ImageDecodeException(
        '通道掩码 0x${mask.toRadixString(16)} 位宽 $width 超出合理范围',
        format: 'BMP',
      );
    }
  }

  /// 原始掩码值。
  final int mask;

  /// 该通道在像素值里的起始位（末尾零的个数）。
  final int shift;

  /// 该通道占几位。
  final int width;

  /// 该通道是否存在。
  bool get isPresent => mask != 0;

  /// 从像素原始值里抽出该通道并缩放到 0..255。
  ///
  /// 缩放用 `v * 255 / (2^width - 1)` 而不是左移补零：5 位的最大值 31
  /// 必须映射到 255，左移 3 位只能得到 248，白色会发灰。这是个经典 bug。
  int extract(int pixel) {
    if (mask == 0) {
      return 255; // 通道不存在时按不透明/满值处理
    }
    final int maxValue = (1 << width) - 1;
    final int v = (pixel >> shift) & maxValue;
    if (width == 8) {
      return v;
    }
    return (v * 255 + maxValue ~/ 2) ~/ maxValue;
  }

  static int _trailingZeros(int v) {
    if (v == 0) {
      return 0;
    }
    int n = 0;
    while ((v & 1) == 0) {
      v >>= 1;
      n++;
    }
    return n;
  }

  static int _popCount(int v) {
    int n = 0;
    while (v != 0) {
      n += v & 1;
      v >>= 1;
    }
    return n;
  }

  @override
  String toString() =>
      'ChannelMask(0x${mask.toRadixString(16)}, shift=$shift, width=$width)';
}
