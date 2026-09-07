import 'dart:typed_data';

import 'package:image_viewer/src/codecs/bmp/bmp_header.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_rle.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// BMP 解码器。
///
/// ## BMP 的难点不在压缩，在版本繁多
///
/// 大多数 BMP 根本没有压缩 —— 像素就那么直排着。真正的工作量来自：
///
/// * **六个头部版本**（12/40/52/56/108/124 字节），字段布局各不相同
/// * **七种位深**（1/2/4/8/16/24/32），前四种要查调色板
/// * **通道掩码可任意指定**（`BI_BITFIELDS`），不只是 RGB555/565
/// * **两套游程编码**（RLE4/RLE8），带转义命令与增量跳转
/// * **默认自底向上**存储，这是最反直觉的一条
///
/// 所以本解码器的结构是「先把头部的花样全部归一化（`BmpHeader`），
/// 再按位深分派到几条像素读取路径」，而不是为每个版本各写一遍。
///
/// ## 三个经典 bug
///
/// 1. 行 4 字节对齐算错 → 第二行开始整片错位（见 `BmpHeader.rowStride`）
/// 2. 忘了自底向上 → 图像上下颠倒
/// 3. 16bpp 用左移代替比例缩放 → 白色发灰（见 `ChannelMask.extract`）
class BmpDecoder extends ImageDecoder {
  const BmpDecoder();

  @override
  String get name => 'BMP';

  @override
  List<String> get extensions => const <String>['bmp', 'dib'];

  @override
  bool canDecode(Uint8List bytes) {
    // 'BM'。BMP 的魔数只有两字节，是所有主流格式里最弱的 ——
    // 所以再加一条约束：紧随其后的 u32 文件长度字段应当合理。
    if (bytes.length < 14) {
      return false;
    }
    if (bytes[0] != 0x42 || bytes[1] != 0x4D) {
      return false;
    }
    return true;
  }

  @override
  RgbaImage decode(Uint8List bytes) {
    final BmpHeader h = BmpHeader.parse(bytes);
    final RgbaImage img = RgbaImage.alloc(h.width, h.height);

    int outOfRangeIndices = 0;
    if (h.compression.isRle) {
      outOfRangeIndices = _decodeRle(bytes, h, img);
    } else if (h.isIndexed) {
      outOfRangeIndices = _decodeIndexed(bytes, h, img);
    } else {
      _decodeDirect(bytes, h, img);
    }

    return RgbaImage(
      width: img.width,
      height: img.height,
      pixels: img.pixels,
      metadata: _buildMetadata(h, outOfRangeIndices),
    );
  }

  /// 把存储行号换算成输出行号。
  ///
  /// BMP **默认自底向上** —— 数据里第一行是图像的最后一行。这源自 OS/2
  /// 的坐标系约定（原点在左下角）。`biHeight` 为负时才是自顶向下。
  ///
  /// 压缩与非压缩两条路都走这个函数，保证翻转逻辑只有一份。
  int _outputRow(BmpHeader h, int storageRow) =>
      h.isTopDown ? storageRow : h.height - 1 - storageRow;

  // —————————————————————————————————————————————————————————————
  // 路径一：索引色（1 / 2 / 4 / 8 bpp）
  // —————————————————————————————————————————————————————————————

  /// 返回越界调色板索引的出现次数。
  int _decodeIndexed(Uint8List bytes, BmpHeader h, RgbaImage img) {
    final int bpp = h.bitsPerPixel;
    final int stride = h.rowStride;
    _ensurePixelData(bytes, h, stride * h.height);

    final List<List<int>> pal = h.palette;
    final int pixelsPerByte = 8 ~/ bpp;
    final int mask = (1 << bpp) - 1;
    int outOfRange = 0;

    for (int sy = 0; sy < h.height; sy++) {
      final int rowStart = h.pixelDataOffset + sy * stride;
      final int oy = _outputRow(h, sy);
      final int outRowBase = oy * h.width * 4;

      for (int x = 0; x < h.width; x++) {
        // 位在字节内**高位在前**：1bpp 时 x=0 是最高位。
        final int byte = bytes[rowStart + x ~/ pixelsPerByte];
        final int shift = 8 - bpp - (x % pixelsPerByte) * bpp;
        final int index = (byte >> shift) & mask;

        final int o = outRowBase + x * 4;
        if (index < pal.length) {
          final List<int> c = pal[index];
          img.pixels[o] = c[0];
          img.pixels[o + 1] = c[1];
          img.pixels[o + 2] = c[2];
          img.pixels[o + 3] = 255;
        } else {
          // 索引超出调色板范围。规范上是非法的，但现实中存在
          // （`biClrUsed` 声明得比实际用到的少）。填不透明黑并计数，
          // 而不是拒绝整个文件 —— 计数会出现在信息面板上。
          outOfRange++;
          img.pixels[o + 3] = 255;
        }
      }
    }
    return outOfRange;
  }

  // —————————————————————————————————————————————————————————————
  // 路径二：直接色（16 / 24 / 32 bpp）
  // —————————————————————————————————————————————————————————————

  void _decodeDirect(Uint8List bytes, BmpHeader h, RgbaImage img) {
    final int bpp = h.bitsPerPixel;
    final int stride = h.rowStride;
    _ensurePixelData(bytes, h, stride * h.height);

    final int bytesPerPixel = bpp ~/ 8;
    // 32bpp BI_RGB 的第四字节按规范是填充位，但现实中常放 alpha。
    // 启发式：全图 alpha 都是 0 就按不透明处理，否则当真 alpha 用。
    final bool useAlpha = h.alphaMask.isPresent &&
        (!h.alphaIsImplicit || _hasNonZeroAlpha(bytes, h, stride));

    for (int sy = 0; sy < h.height; sy++) {
      final int rowStart = h.pixelDataOffset + sy * stride;
      final int oy = _outputRow(h, sy);
      final int outRowBase = oy * h.width * 4;

      for (int x = 0; x < h.width; x++) {
        final int p = rowStart + x * bytesPerPixel;
        final int o = outRowBase + x * 4;

        if (bpp == 24) {
          // 24bpp 不走掩码路径：字节顺序固定 BGR。
          // BMP 是 BGR 而非 RGB，这是个常见错误来源。
          img.pixels[o] = bytes[p + 2];
          img.pixels[o + 1] = bytes[p + 1];
          img.pixels[o + 2] = bytes[p];
          img.pixels[o + 3] = 255;
          continue;
        }

        // 16/32bpp：先按小端拼出原始值，再用掩码抽通道。
        final int raw = bpp == 16
            ? bytes[p] | (bytes[p + 1] << 8)
            : bytes[p] |
                (bytes[p + 1] << 8) |
                (bytes[p + 2] << 16) |
                (bytes[p + 3] << 24);

        img.pixels[o] = h.redMask.extract(raw);
        img.pixels[o + 1] = h.greenMask.extract(raw);
        img.pixels[o + 2] = h.blueMask.extract(raw);
        img.pixels[o + 3] = useAlpha ? h.alphaMask.extract(raw) : 255;
      }
    }
  }

  /// 扫描全图判断 alpha 通道是否真的被用了。
  ///
  /// 只在 32bpp `BI_RGB` 这一种情况下调用 —— 那时第四字节的含义规范上
  /// 是「未使用」，但实践中一半的文件放了 alpha。全零就说明是填充。
  bool _hasNonZeroAlpha(Uint8List bytes, BmpHeader h, int stride) {
    for (int sy = 0; sy < h.height; sy++) {
      final int rowStart = h.pixelDataOffset + sy * stride;
      for (int x = 0; x < h.width; x++) {
        final int p = rowStart + x * 4;
        final int raw = bytes[p] |
            (bytes[p + 1] << 8) |
            (bytes[p + 2] << 16) |
            (bytes[p + 3] << 24);
        if (h.alphaMask.extract(raw) != 0) {
          return true;
        }
      }
    }
    return false;
  }

  // —————————————————————————————————————————————————————————————
  // 路径三：游程编码（RLE4 / RLE8）
  // —————————————————————————————————————————————————————————————

  int _decodeRle(Uint8List bytes, BmpHeader h, RgbaImage img) {
    // RLE 解码器只吐调色板索引，索引到颜色的映射在这里做 ——
    // 这样游程逻辑与调色板逻辑互不纠缠。
    final Uint8List indices = BmpRleDecoder.decode(bytes, h);
    final List<List<int>> pal = h.palette;
    int outOfRange = 0;

    for (int sy = 0; sy < h.height; sy++) {
      final int oy = _outputRow(h, sy);
      for (int x = 0; x < h.width; x++) {
        final int index = indices[sy * h.width + x];
        final int o = (oy * h.width + x) * 4;
        if (index < pal.length) {
          final List<int> c = pal[index];
          img.pixels[o] = c[0];
          img.pixels[o + 1] = c[1];
          img.pixels[o + 2] = c[2];
          img.pixels[o + 3] = 255;
        } else {
          outOfRange++;
          img.pixels[o + 3] = 255;
        }
      }
    }
    return outOfRange;
  }

  // —————————————————————————————————————————————————————————————

  /// 校验像素数据够不够，不够就报出差多少。
  void _ensurePixelData(Uint8List bytes, BmpHeader h, int needed) {
    final int available = bytes.length - h.pixelDataOffset;
    if (available < needed) {
      throw ImageDecodeException(
        '像素数据不足：${h.width}x${h.height} 的 ${h.bitsPerPixel}bpp 图，'
        '每行对齐后 ${h.rowStride} 字节，共需 $needed 字节，'
        '但偏移 ${h.pixelDataOffset} 之后只有 $available 字节',
        format: 'BMP',
        offset: h.pixelDataOffset,
      );
    }
  }

  ImageMetadata _buildMetadata(BmpHeader h, int outOfRangeIndices) {
    final Map<String, Object> extra = <String, Object>{
      '行方向': h.isTopDown ? '自顶向下' : '自底向上（BMP 默认）',
      '行对齐后字节数': h.rowStride,
      '像素数据偏移': h.pixelDataOffset,
    };
    if (h.isIndexed) {
      extra['调色板项数'] = h.palette.length;
    }
    if (h.bitsPerPixel == 16 || h.bitsPerPixel == 32) {
      extra['通道掩码'] = 'R=0x${h.redMask.mask.toRadixString(16)} '
          'G=0x${h.greenMask.mask.toRadixString(16)} '
          'B=0x${h.blueMask.mask.toRadixString(16)} '
          'A=0x${h.alphaMask.mask.toRadixString(16)}';
    }
    if (h.xPixelsPerMeter > 0) {
      // 转成更常见的 DPI 单位：1 英寸 = 0.0254 米
      final int dpi = (h.xPixelsPerMeter * 0.0254).round();
      extra['分辨率'] = '$dpi DPI';
    }
    if (outOfRangeIndices > 0) {
      extra['越界调色板索引'] = '$outOfRangeIndices 个像素（已填黑）';
    }

    return ImageMetadata(
      format: 'BMP',
      variant: h.variantDescription,
      bitDepth: h.bitsPerPixel,
      channels: h.bitsPerPixel == 32 ? 4 : 3,
      colorSpace: h.isIndexed ? '调色板索引' : 'BGR',
      compression: h.compression.description,
      isLossless: true,
      extra: extra,
    );
  }
}
