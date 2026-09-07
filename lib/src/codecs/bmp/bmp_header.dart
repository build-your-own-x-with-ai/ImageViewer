import 'dart:typed_data';

import 'package:image_viewer/src/codecs/bmp/bmp_types.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 解析后的 BMP 头部：文件头 + DIB 头 + 通道掩码 + 调色板。
///
/// ## 头部布局
///
/// ```
/// 偏移 0     BITMAPFILEHEADER   14 字节，固定
/// 偏移 14    DIB 头             12/40/52/56/108/124 字节，按首字段长度分派
///            [通道掩码]          仅 40 字节 INFO 头 + BI_BITFIELDS 时在这里
///            [调色板]            bpp <= 8 时出现
/// bfOffBits  像素数据           位置由文件头声明
/// ```
///
/// 最后一行值得强调：像素数据的位置**必须**用文件头里的 `bfOffBits`，
/// 不能用「头部长度 + 调色板长度」推算。现实中有大量文件在调色板与像素
/// 数据之间留了空隙，推算会整片错位。
class BmpHeader {
  BmpHeader({
    required this.version,
    required this.width,
    required this.height,
    required this.isTopDown,
    required this.bitsPerPixel,
    required this.compression,
    required this.palette,
    required this.redMask,
    required this.greenMask,
    required this.blueMask,
    required this.alphaMask,
    required this.alphaIsImplicit,
    required this.pixelDataOffset,
    required this.declaredImageSize,
    this.xPixelsPerMeter = 0,
    this.yPixelsPerMeter = 0,
  });

  final BmpHeaderVersion version;

  /// 图像宽度（像素），恒为正。
  final int width;

  /// 图像高度（像素），恒为正 —— 方向信息在 [isTopDown] 里。
  final int height;

  /// 像素行是否自顶向下存储。
  ///
  /// BMP **默认自底向上**（第一行数据是图像最后一行），这是它最反直觉的
  /// 特性，源自 OS/2 的坐标系约定。`biHeight` 为负数时表示自顶向下。
  final bool isTopDown;

  /// 每像素位数：1 / 2 / 4 / 8 / 16 / 24 / 32。
  final int bitsPerPixel;

  final BmpCompression compression;

  /// 调色板，每项 `[r, g, b, a]`。非索引色图为空。
  final List<List<int>> palette;

  final ChannelMask redMask;
  final ChannelMask greenMask;
  final ChannelMask blueMask;
  final ChannelMask alphaMask;

  /// alpha 通道是否只是「名义上的填充位」。
  ///
  /// 32bpp 的 `BI_RGB` 按规范第四字节是未使用的填充，应视为不透明。
  /// 但现实中大量文件确实在那里放了 alpha 数据。所以解码器要用启发式：
  /// 若全图 alpha 字节都是 0，按不透明处理；否则当真正的 alpha 用。
  ///
  /// 只有在这个标志为 true 时才启用该启发式；`BI_BITFIELDS` 明确声明了
  /// alpha 掩码的情况一律照声明处理。
  final bool alphaIsImplicit;

  /// 像素数据起始偏移，取自文件头的 `bfOffBits`。
  final int pixelDataOffset;

  /// DIB 头里声明的像素数据长度。RLE 解码需要它作为上界。
  ///
  /// 可能为 0（无压缩时允许省略），此时按「到文件末尾」处理。
  final int declaredImageSize;

  final int xPixelsPerMeter;
  final int yPixelsPerMeter;

  /// 是否索引色（用调色板）。
  bool get isIndexed => bitsPerPixel <= 8;

  /// 每行像素占多少字节，**含 4 字节对齐填充**。
  ///
  /// 这个公式初学者常写错。正确写法是先算出该行需要多少位，向上取整到
  /// 32 位（4 字节）的整数倍，再换算成字节：
  ///
  /// ```
  /// rowStride = ((width * bpp + 31) / 32) * 4
  /// ```
  ///
  /// 例：宽 3 的 24bpp 图，每行 9 字节数据，但实际占 12 字节。
  /// 漏掉填充的话第二行开始整片错位并偏色。
  int get rowStride => ((width * bitsPerPixel + 31) ~/ 32) * 4;

  /// 无压缩时像素数据的实际所需字节数。
  int get uncompressedDataSize => rowStride * height;

  /// 信息面板上显示的子类型描述。
  String get variantDescription => version.description;

  @override
  String toString() =>
      'BmpHeader(${version.name}, ${width}x$height, ${bitsPerPixel}bpp, '
      '${compression.name}, ${isTopDown ? "自顶向下" : "自底向上"}, '
      'stride=$rowStride, data@$pixelDataOffset)';

  /// 解析文件头与 DIB 头。
  static BmpHeader parse(Uint8List bytes) {
    final ByteReader r = ByteReader(bytes, format: 'BMP');

    // —————————————— BITMAPFILEHEADER，14 字节 ——————————————
    final String magic = r.ascii(2, '文件魔数');
    if (magic != 'BM') {
      throw ImageDecodeException(
        'BMP 魔数应为 "BM"，实际是 "$magic"',
        format: 'BMP',
        offset: 0,
      );
    }
    r.skip(4, 'bfSize');      // 声明的文件总长，不可信，忽略
    r.skip(4, 'bfReserved');  // 两个 u16 保留字段
    final int pixelDataOffset = r.u32le('bfOffBits');

    // —————————————— DIB 头，长度自描述 ——————————————
    final int dibSize = r.u32le('DIB 头长度');
    final BmpHeaderVersion version = BmpHeaderVersion.fromSize(dibSize);

    int width;
    int rawHeight;
    int planes;
    int bpp;
    BmpCompression compression = BmpCompression.rgb;
    int declaredImageSize = 0;
    int xPpm = 0;
    int yPpm = 0;
    int paletteColors = 0;

    if (version == BmpHeaderVersion.core) {
      // OS/2 1.x：宽高是 u16，没有压缩与调色板长度字段。
      width = r.u16le('bcWidth');
      rawHeight = r.u16le('bcHeight');
      planes = r.u16le('bcPlanes');
      bpp = r.u16le('bcBitCount');
    } else {
      width = r.i32le('biWidth');
      rawHeight = r.i32le('biHeight');
      planes = r.u16le('biPlanes');
      bpp = r.u16le('biBitCount');
      compression = BmpCompression.fromCode(r.u32le('biCompression'));
      declaredImageSize = r.u32le('biSizeImage');
      xPpm = r.i32le('biXPelsPerMeter');
      yPpm = r.i32le('biYPelsPerMeter');
      paletteColors = r.u32le('biClrUsed');
      r.skip(4, 'biClrImportant');
    }

    if (planes != 1) {
      throw ImageDecodeException(
        'biPlanes 必须为 1，实际是 $planes',
        format: 'BMP',
        offset: 14,
      );
    }
    _validateBitsPerPixel(bpp);
    _validateCompression(compression, bpp);

    // 负高度表示自顶向下。取绝对值后再校验，避免把负数带进尺寸检查。
    final bool isTopDown = rawHeight < 0;
    final int height = rawHeight < 0 ? -rawHeight : rawHeight;
    RgbaImage.validateDimensions(width, height, format: 'BMP');

    // —————————————— 通道掩码 ——————————————
    final _Masks masks = _readMasks(r, version, compression, bpp, dibSize);

    // —————————————— 调色板 ——————————————
    //
    // 位置：DIB 头结束处。注意 40 字节 INFO 头 + BI_BITFIELDS 时，
    // 掩码占据了调色板区域的前 12 字节，_readMasks 已经把偏移推过去了。
    final List<List<int>> palette = bpp <= 8
        ? _readPalette(r, bytes, version, bpp, paletteColors, pixelDataOffset)
        : const <List<int>>[];

    // —————————————— 像素数据偏移校验 ——————————————
    if (pixelDataOffset < 14 || pixelDataOffset > bytes.length) {
      throw ImageDecodeException(
        'bfOffBits 声明像素数据在偏移 $pixelDataOffset，'
        '超出文件范围 14..${bytes.length}',
        format: 'BMP',
        offset: 10,
      );
    }

    return BmpHeader(
      version: version,
      width: width,
      height: height,
      isTopDown: isTopDown,
      bitsPerPixel: bpp,
      compression: compression,
      palette: palette,
      redMask: masks.red,
      greenMask: masks.green,
      blueMask: masks.blue,
      alphaMask: masks.alpha,
      alphaIsImplicit: masks.alphaIsImplicit,
      pixelDataOffset: pixelDataOffset,
      declaredImageSize: declaredImageSize,
      xPixelsPerMeter: xPpm,
      yPixelsPerMeter: yPpm,
    );
  }
  static void _validateBitsPerPixel(int bpp) {
    // 2bpp 不在原始规范里，但 Windows CE 用过，且解码逻辑与 1/4 完全同构，
    // 顺手支持没有额外成本。
    const List<int> allowed = <int>[1, 2, 4, 8, 16, 24, 32];
    if (!allowed.contains(bpp)) {
      throw ImageDecodeException(
        '每像素位数 $bpp 不受支持（应为 ${allowed.join("/")} 之一）',
        format: 'BMP',
        offset: 14,
      );
    }
  }

  static void _validateCompression(BmpCompression c, int bpp) {
    // 内嵌 JPEG/PNG：像素数据整个是另一个格式的文件。规范里有，
    // 现实中几乎不存在（打印驱动的私有用法）。明确拒绝而不是悄悄出错。
    if (c == BmpCompression.jpeg || c == BmpCompression.png) {
      throw UnsupportedImageFeature(
        '${c.description}的 BMP 不受支持',
        format: 'BMP',
        offset: 14,
      );
    }
    // 游程编码与位深是绑定的，不匹配说明文件损坏。
    if (c == BmpCompression.rle8 && bpp != 8) {
      throw ImageDecodeException(
        'RLE8 压缩要求 8bpp，实际声明 ${bpp}bpp',
        format: 'BMP',
        offset: 14,
      );
    }
    if (c == BmpCompression.rle4 && bpp != 4) {
      throw ImageDecodeException(
        'RLE4 压缩要求 4bpp，实际声明 ${bpp}bpp',
        format: 'BMP',
        offset: 14,
      );
    }
    if (c.usesMasks && bpp != 16 && bpp != 32) {
      throw ImageDecodeException(
        'BI_BITFIELDS 只用于 16bpp 或 32bpp，实际声明 ${bpp}bpp',
        format: 'BMP',
        offset: 14,
      );
    }
  }

  /// 读取通道掩码。
  ///
  /// 掩码可能出现在两个不同位置，这是 BMP 最容易搞错的细节之一：
  ///
  /// * **V2 及以后**（>= 52 字节）：掩码是 DIB 头自身的字段
  /// * **40 字节 INFO 头 + BI_BITFIELDS**：掩码放在**调色板区域**的
  ///   前 12（或 16）字节，即 DIB 头之后
  ///
  /// 后一种是历史包裹 —— Windows 3.0 时代 INFO 头已经定型，要加掩码
  /// 只能借用调色板的位置。
  static _Masks _readMasks(
    ByteReader r,
    BmpHeaderVersion version,
    BmpCompression compression,
    int bpp,
    int dibSize,
  ) {
    if (version.hasInlineMasks) {
      // V2/V3/V4/V5：掩码在头部里，当前偏移正好停在 54（14+40）。
      final int red = r.u32le('bV2RedMask');
      final int green = r.u32le('bV2GreenMask');
      final int blue = r.u32le('bV2BlueMask');
      final int alpha =
          version.hasInlineAlphaMask ? r.u32le('bV3AlphaMask') : 0;
      // 跳过本版本剩余的字段（色彩空间、端点、gamma、渲染意图、ICC）。
      r.offset = 14 + dibSize;

      // V4/V5 头 + BI_RGB 时掩码字段可能全为 0，此时按位深取默认值。
      if (red == 0 && green == 0 && blue == 0) {
        return _defaultMasks(bpp);
      }
      return _Masks(
        red: ChannelMask(red),
        green: ChannelMask(green),
        blue: ChannelMask(blue),
        alpha: ChannelMask(alpha),
        alphaIsImplicit: false,
      );
    }

    if (compression.usesMasks) {
      // 40 字节 INFO 头 + BI_BITFIELDS：掩码借用调色板区域。
      final int red = r.u32le('RedMask');
      final int green = r.u32le('GreenMask');
      final int blue = r.u32le('BlueMask');
      final int alpha = compression == BmpCompression.alphaBitfields
          ? r.u32le('AlphaMask')
          : 0;
      return _Masks(
        red: ChannelMask(red),
        green: ChannelMask(green),
        blue: ChannelMask(blue),
        alpha: ChannelMask(alpha),
        alphaIsImplicit: false,
      );
    }

    return _defaultMasks(bpp);
  }

  /// 无掩码声明时按位深取默认通道布局。
  ///
  /// BMP 的字节序是 **BGR**（不是 RGB），这是另一个常见错误来源。
  static _Masks _defaultMasks(int bpp) {
    switch (bpp) {
      case 16:
        // 默认 RGB555，最高位未使用。RGB565 必须靠 BI_BITFIELDS 声明。
        return _Masks(
          red: ChannelMask(0x7C00),
          green: ChannelMask(0x03E0),
          blue: ChannelMask(0x001F),
          alpha: ChannelMask(0),
          alphaIsImplicit: false,
        );
      case 32:
        // BGRX：低位到高位是 B, G, R, 未使用。
        // 第四字节按规范是填充，但现实中常放 alpha，所以标记为「隐式」，
        // 让解码器用启发式判断。
        return _Masks(
          red: ChannelMask(0x00FF0000),
          green: ChannelMask(0x0000FF00),
          blue: ChannelMask(0x000000FF),
          alpha: ChannelMask(0xFF000000),
          alphaIsImplicit: true,
        );
      default:
        // 24bpp 与索引色不走掩码路径，这里的值不会被用到。
        return _Masks(
          red: ChannelMask(0x00FF0000),
          green: ChannelMask(0x0000FF00),
          blue: ChannelMask(0x000000FF),
          alpha: ChannelMask(0),
          alphaIsImplicit: false,
        );
    }
  }

  /// 读调色板。
  ///
  /// 每项字节数按版本不同（CORE 是 3，其余是 4）。项数取 `biClrUsed`，
  /// 为 0 时按位深推算满表（`2^bpp`）。
  static List<List<int>> _readPalette(
    ByteReader r,
    Uint8List bytes,
    BmpHeaderVersion version,
    int bpp,
    int declaredColors,
    int pixelDataOffset,
  ) {
    final int maxColors = 1 << bpp;
    int count = declaredColors == 0 ? maxColors : declaredColors;
    // biClrUsed 来自文件，可能声明一个荒谬的大数。按位深硬上限截断。
    if (count > maxColors) {
      count = maxColors;
    }

    final int entrySize = version.paletteEntrySize;
    // 调色板不能越过像素数据的起点，也不能越过文件末尾。
    // 现实中有文件声明满表但实际只写了用到的几项，所以这里截断而不报错，
    // 解码时遇到越界的索引再单独处理。
    final int limit = pixelDataOffset > r.offset && pixelDataOffset <= bytes.length
        ? pixelDataOffset
        : bytes.length;
    final int available = (limit - r.offset) ~/ entrySize;
    if (available < count) {
      count = available < 0 ? 0 : available;
    }

    final List<List<int>> palette = <List<int>>[];
    for (int i = 0; i < count; i++) {
      // 调色板也是 BGR 顺序
      final int b = r.u8('调色板 B');
      final int g = r.u8('调色板 G');
      final int rr = r.u8('调色板 R');
      if (entrySize == 4) {
        r.skip(1, '调色板保留字节');
      }
      palette.add(<int>[rr, g, b, 255]);
    }
    return palette;
  }
}

/// 四个通道掩码 + alpha 是否为隐式填充。
class _Masks {
  _Masks({
    required this.red,
    required this.green,
    required this.blue,
    required this.alpha,
    required this.alphaIsImplicit,
  });

  final ChannelMask red;
  final ChannelMask green;
  final ChannelMask blue;
  final ChannelMask alpha;
  final bool alphaIsImplicit;
}
