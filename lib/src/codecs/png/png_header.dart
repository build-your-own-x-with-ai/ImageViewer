/// PNG 的 `IHDR` chunk：图像头部与由它推导出的几何量。
///
/// `IHDR` 只有 13 字节，但后面每一步解码都要靠它算出来的几个数字：
/// 一行有多少字节、滤波器的「左邻居」隔多远、解压后总共该有多少字节。
/// 这些推导量算错一个，整张图就会斜着错开 —— 所以集中放在这里，
/// 附带算式的来由。
library;

import 'package:image_viewer/src/codecs/png/png_types.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// `IHDR` 的固定长度。
const int kIhdrLength = 13;

/// PNG 图像头部。
class PngHeader {
  PngHeader({
    required this.width,
    required this.height,
    required this.bitDepth,
    required this.colorType,
    required this.interlace,
  });

  final int width;
  final int height;

  /// 每个**采样**的位数，不是每像素 —— RGB8 的 bitDepth 是 8 而非 24。
  final int bitDepth;

  final PngColorType colorType;
  final PngInterlaceMethod interlace;

  /// 每像素位数。
  int get bitsPerPixel => colorType.channels * bitDepth;

  /// 滤波单元的字节数，即滤波器眼里「左邻居」的距离。
  ///
  /// ## 为什么小于 8 位时要向上取整到 1
  ///
  /// 滤波器做的是「当前字节减去左边那个字节」。对 RGB8 来说左邻居隔
  /// 3 字节，对 RGBA16 隔 8 字节，都很自然。但 1 位灰度图一个字节里
  /// 装了 8 个像素，「左边一个像素」根本不在另一个字节里。
  ///
  /// 规范的处理很干脆：**位深小于 8 时，bpp 按 1 字节算**，滤波器直接
  /// 拿上一个字节做参考。这在语义上有点糙（相当于减去左边 8 个像素中
  /// 最远的那个），但保持了「滤波器只跟字节打交道，完全不用理解像素
  /// 格式」这个简洁性 —— 滤波和像素解释因此彻底解耦。
  int get bytesPerPixel {
    final int bits = bitsPerPixel;
    return bits < 8 ? 1 : bits ~/ 8;
  }

  /// 一行图像数据的字节数，不含行首的滤波器类型字节。
  ///
  /// 向上取整：1 位深、宽 5 的图一行占 1 字节，末尾 3 位是填充。
  /// 每行都单独填充到字节边界，行与行之间不共享字节。
  int get bytesPerRow => (width * bitsPerPixel + 7) ~/ 8;

  /// 解压后应得的总字节数（非隔行时）。
  ///
  /// 每行多出的那 1 字节是滤波器类型。这个值同时用作 inflate 的
  /// **硬上限**：解压结果多一个字节都说明数据有问题，正好也把
  /// 「解压炸弹」挡在门外。
  int get rawSize => height * (bytesPerRow + 1);

  /// 采样值的最大值，如 8 位深是 255。
  int get maxSampleValue => (1 << bitDepth) - 1;

  /// 从 `IHDR` 的 13 字节数据解析。
  ///
  /// [chunkOffset] 是 chunk 在文件中的偏移，仅用于异常信息定位。
  factory PngHeader.parse(List<int> data, {int chunkOffset = 0}) {
    if (data.length != kIhdrLength) {
      throw ImageDecodeException(
        'IHDR 长度应为 $kIhdrLength 字节，实际 ${data.length}',
        format: 'PNG',
        offset: chunkOffset,
      );
    }

    // 大端序 —— PNG 通篇用网络字节序。用乘法而不是 `<< 24`：
    // Web 上的位运算是 32 位有符号的，左移 24 位遇到高位为 1 会得到负数。
    final int width = data[0] * 16777216 + data[1] * 65536 + data[2] * 256 + data[3];
    final int height = data[4] * 16777216 + data[5] * 65536 + data[6] * 256 + data[7];

    RgbaImage.validateDimensions(width, height, format: 'PNG');

    final int bitDepth = data[8];
    final PngColorType colorType = PngColorType.fromValue(
      data[9],
      offset: chunkOffset + 9,
    );
    colorType.validateBitDepth(bitDepth, offset: chunkOffset + 8);

    // 压缩方法与滤波方法各只有一个合法值。三十年过去，规范里
    // 这两个字节始终只允许填 0 —— 预留的扩展位从没用上，但留着
    // 不亏：一个字节换一条「以后可以换算法」的退路。
    final int compression = data[10];
    if (compression != 0) {
      throw UnsupportedImageFeature(
        '未知的压缩方法 $compression。PNG 规范目前只定义了 0（deflate）',
        format: 'PNG',
        offset: chunkOffset + 10,
      );
    }

    final int filterMethod = data[11];
    if (filterMethod != 0) {
      throw UnsupportedImageFeature(
        '未知的滤波方法 $filterMethod。PNG 规范目前只定义了 0（五种基础滤波器）',
        format: 'PNG',
        offset: chunkOffset + 11,
      );
    }

    final PngInterlaceMethod interlace = PngInterlaceMethod.fromValue(
      data[12],
      offset: chunkOffset + 12,
    );

    return PngHeader(
      width: width,
      height: height,
      bitDepth: bitDepth,
      colorType: colorType,
      interlace: interlace,
    );
  }

  @override
  String toString() =>
      'PngHeader(${width}x$height, $bitDepth 位 ${colorType.description}, '
      '隔行=${interlace.description})';
}
