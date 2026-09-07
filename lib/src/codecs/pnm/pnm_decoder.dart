import 'dart:typed_data';

import 'package:image_viewer/src/codecs/pnm/pnm_header.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// PNM（PBM / PGM / PPM）解码器，支持 P1–P6 全部六种变体。
///
/// ## 为什么先写这个
///
/// PNM 是最简单的图像格式：没有压缩，没有调色板，头部是纯文本。
/// 所以它有两个作用：
///
/// 1. **入门样本** —— 完整走通"字节流 → RGBA"的全流程，但不被压缩算法干扰
/// 2. **参照解码器** —— 一旦它被手写字节测试彻底验证，就可以用它来校验
///    其它格式：把真实的 PNG/JPEG 用系统工具转成 PPM 存进仓库当期望值，
///    我们的 PNM 解码器读出期望像素，与我们的 PNG/JPEG 解码器输出逐点比对。
///    好处是期望值以简单格式存在仓库里，出错时能直接看出哪个像素不对。
///
/// ## 六种变体的关系
///
/// ```
///           ASCII   二进制    每像素样本数
/// 位图 PBM    P1      P4          1（1 位）
/// 灰度 PGM    P2      P5          1
/// 彩色 PPM    P3      P6          3
/// ```
class PnmDecoder extends ImageDecoder {
  const PnmDecoder();

  @override
  String get name => 'PNM';

  @override
  List<String> get extensions =>
      const <String>['pnm', 'pbm', 'pgm', 'ppm'];

  @override
  bool canDecode(Uint8List bytes) {
    // 魔数是 'P' 后跟 '1'..'6'。只有两字节，比大多数格式的魔数弱，
    // 但配合"版本号必须在 1..6"这个约束，误判概率可以接受。
    if (bytes.length < 2) {
      return false;
    }
    return bytes[0] == 0x50 && PnmVariant.fromDigit(bytes[1]) != null;
  }

  @override
  RgbaImage decode(Uint8List bytes) {
    final PnmHeader h = PnmHeader.parse(bytes);
    final RgbaImage img = RgbaImage.alloc(
      h.width,
      h.height,
      metadata: _buildMetadata(h),
    );

    switch (h.variant) {
      case PnmVariant.p1AsciiBitmap:
        _decodeAsciiBitmap(bytes, h, img);
      case PnmVariant.p2AsciiGray:
      case PnmVariant.p3AsciiRgb:
        _decodeAsciiSamples(bytes, h, img);
      case PnmVariant.p4BinaryBitmap:
        _decodeBinaryBitmap(bytes, h, img);
      case PnmVariant.p5BinaryGray:
      case PnmVariant.p6BinaryRgb:
        _decodeBinarySamples(bytes, h, img);
    }
    return img;
  }

  ImageMetadata _buildMetadata(PnmHeader h) {
    return ImageMetadata(
      format: 'PNM',
      variant: '${h.variant.magic} · ${h.variant.description}',
      bitDepth: h.variant.isBitmap ? 1 : (h.maxValue > 255 ? 16 : 8),
      channels: h.variant.samplesPerPixel,
      colorSpace: h.variant.samplesPerPixel == 3 ? 'RGB' : '灰度',
      compression: '无',
      isLossless: true,
      extra: <String, Object>{
        'maxval': h.maxValue,
        '编码': h.variant.isBinary ? '二进制' : 'ASCII 文本',
        '数据偏移': h.dataOffset,
      },
    );
  }

  // —————————————————————————————————————————————————————————————
  // P1：ASCII 位图
  // —————————————————————————————————————————————————————————————

  /// P1 的每个像素是一个 `0` 或 `1` 字符，之间的空白可有可无。
  ///
  /// 注意**颜色是反的**：位图里 `1` 表示黑，`0` 表示白。这源于 PBM 的
  /// 出身 —— 它描述的是"哪里要落墨"，而不是"哪里是亮的"。P4 同理。
  void _decodeAsciiBitmap(Uint8List bytes, PnmHeader h, RgbaImage img) {
    int pos = h.dataOffset;
    final int total = h.width * h.height;

    for (int i = 0; i < total; i++) {
      // 跳过空白与注释，找到下一个 0/1 字符
      while (true) {
        if (pos >= bytes.length) {
          throw ImageDecodeException(
            '像素数据不足：期望 $total 个像素，只读到 $i 个',
            format: 'PNM',
            offset: pos,
          );
        }
        final int c = bytes[pos];
        if (c == 0x30 || c == 0x31) {
          break;
        }
        if (c == 0x23) {
          // 注释吃到行尾
          while (pos < bytes.length &&
              bytes[pos] != 0x0A &&
              bytes[pos] != 0x0D) {
            pos++;
          }
          continue;
        }
        if (_isWhitespace(c)) {
          pos++;
          continue;
        }
        throw ImageDecodeException(
          'P1 数据里只允许 0 / 1 与空白，'
          '实际读到 0x${c.toRadixString(16)}',
          format: 'PNM',
          offset: pos,
        );
      }

      // 1 = 黑，0 = 白
      final int v = bytes[pos] == 0x31 ? 0 : 255;
      pos++;
      final int o = i * 4;
      img.pixels[o] = v;
      img.pixels[o + 1] = v;
      img.pixels[o + 2] = v;
      img.pixels[o + 3] = 255;
    }
  }

  // —————————————————————————————————————————————————————————————
  // P2 / P3：ASCII 灰度与彩色
  // —————————————————————————————————————————————————————————————

  /// P2 每像素一个十进制数，P3 每像素三个（R G B）。
  void _decodeAsciiSamples(Uint8List bytes, PnmHeader h, RgbaImage img) {
    final ByteReader r = ByteReader(bytes, format: 'PNM')
      ..offset = h.dataOffset;
    final int spp = h.variant.samplesPerPixel;
    final int total = h.width * h.height;

    for (int i = 0; i < total; i++) {
      int rr = 0;
      int gg = 0;
      int bb = 0;
      if (spp == 1) {
        final int v = h.scaleToByte(_readAsciiSample(r, h, i));
        rr = v;
        gg = v;
        bb = v;
      } else {
        rr = h.scaleToByte(_readAsciiSample(r, h, i));
        gg = h.scaleToByte(_readAsciiSample(r, h, i));
        bb = h.scaleToByte(_readAsciiSample(r, h, i));
      }
      final int o = i * 4;
      img.pixels[o] = rr;
      img.pixels[o + 1] = gg;
      img.pixels[o + 2] = bb;
      img.pixels[o + 3] = 255;
    }
  }

  /// 读一个 ASCII 十进制样本，跳过空白与注释。
  int _readAsciiSample(ByteReader r, PnmHeader h, int pixelIndex) {
    // 跳过空白与注释
    while (true) {
      final int? c = r.peek();
      if (c == null) {
        throw ImageDecodeException(
          '像素数据不足：读到第 $pixelIndex 个像素时文件已结束',
          format: 'PNM',
          offset: r.offset,
        );
      }
      if (_isWhitespace(c)) {
        r.skip(1);
        continue;
      }
      if (c == 0x23) {
        while (true) {
          final int? cc = r.peek();
          if (cc == null) {
            throw ImageDecodeException(
              '注释未闭合且像素数据不足',
              format: 'PNM',
              offset: r.offset,
            );
          }
          r.skip(1);
          if (cc == 0x0A || cc == 0x0D) {
            break;
          }
        }
        continue;
      }
      break;
    }

    final int start = r.offset;
    int value = 0;
    int digits = 0;
    while (true) {
      final int? c = r.peek();
      if (c == null || c < 0x30 || c > 0x39) {
        break;
      }
      value = value * 10 + (c - 0x30);
      digits++;
      if (digits > 6) {
        throw ImageDecodeException(
          '样本数值过大（超过 6 位数）',
          format: 'PNM',
          offset: start,
        );
      }
      r.skip(1);
    }
    if (digits == 0) {
      final int? c = r.peek();
      throw ImageDecodeException(
        '期望一个十进制样本值，实际读到 '
        '0x${c!.toRadixString(16)}',
        format: 'PNM',
        offset: start,
      );
    }
    if (value > h.maxValue) {
      throw ImageDecodeException(
        '样本值 $value 超过声明的 maxval ${h.maxValue}',
        format: 'PNM',
        offset: start,
      );
    }
    return value;
  }

  // —————————————————————————————————————————————————————————————
  // P4：二进制位图
  // —————————————————————————————————————————————————————————————

  /// P4 每行按**字节对齐**打包，高位在前，`1` 表示黑。
  ///
  /// 行对齐是这里唯一的坑：宽 12 的图每行占 2 字节（12 位数据 + 4 位填充），
  /// 而不是 1.5 字节。P5/P6 没有这个问题（它们每样本至少一字节）。
  void _decodeBinaryBitmap(Uint8List bytes, PnmHeader h, RgbaImage img) {
    final int rowBytes = (h.width + 7) ~/ 8;
    final int needed = rowBytes * h.height;
    final int available = bytes.length - h.dataOffset;
    if (available < needed) {
      throw ImageDecodeException(
        'P4 数据不足：${h.width}x${h.height} 每行 $rowBytes 字节，'
        '共需 $needed 字节，实际只有 $available 字节',
        format: 'PNM',
        offset: h.dataOffset,
      );
    }

    for (int y = 0; y < h.height; y++) {
      final int rowStart = h.dataOffset + y * rowBytes;
      for (int x = 0; x < h.width; x++) {
        final int byte = bytes[rowStart + (x >> 3)];
        // 高位在前：x=0 对应最高位
        final int bit = (byte >> (7 - (x & 7))) & 1;
        final int v = bit == 1 ? 0 : 255; // 1 = 黑
        final int o = (y * h.width + x) * 4;
        img.pixels[o] = v;
        img.pixels[o + 1] = v;
        img.pixels[o + 2] = v;
        img.pixels[o + 3] = 255;
      }
    }
  }

  // —————————————————————————————————————————————————————————————
  // P5 / P6：二进制灰度与彩色
  // —————————————————————————————————————————————————————————————

  /// maxval > 255 时每样本 2 字节，**大端**。
  void _decodeBinarySamples(Uint8List bytes, PnmHeader h, RgbaImage img) {
    final int spp = h.variant.samplesPerPixel;
    final int bps = h.bytesPerSample;
    final int total = h.width * h.height;
    final int needed = total * spp * bps;
    final int available = bytes.length - h.dataOffset;
    if (available < needed) {
      throw ImageDecodeException(
        '${h.variant.magic} 数据不足：${h.width}x${h.height} × $spp 通道 '
        '× $bps 字节 = $needed 字节，实际只有 $available 字节',
        format: 'PNM',
        offset: h.dataOffset,
      );
    }

    int pos = h.dataOffset;
    for (int i = 0; i < total; i++) {
      int rr;
      int gg;
      int bb;
      if (spp == 1) {
        final int s = bps == 1
            ? bytes[pos]
            : (bytes[pos] << 8) | bytes[pos + 1];
        pos += bps;
        final int v = h.scaleToByte(s);
        rr = v;
        gg = v;
        bb = v;
      } else {
        if (bps == 1) {
          rr = h.scaleToByte(bytes[pos]);
          gg = h.scaleToByte(bytes[pos + 1]);
          bb = h.scaleToByte(bytes[pos + 2]);
          pos += 3;
        } else {
          rr = h.scaleToByte((bytes[pos] << 8) | bytes[pos + 1]);
          gg = h.scaleToByte((bytes[pos + 2] << 8) | bytes[pos + 3]);
          bb = h.scaleToByte((bytes[pos + 4] << 8) | bytes[pos + 5]);
          pos += 6;
        }
      }
      final int o = i * 4;
      img.pixels[o] = rr;
      img.pixels[o + 1] = gg;
      img.pixels[o + 2] = bb;
      img.pixels[o + 3] = 255;
    }
  }

  static bool _isWhitespace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C;
}
