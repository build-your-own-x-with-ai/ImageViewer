import 'dart:typed_data';

import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// PNM 家族的六种子格式。
///
/// 命名来自 Netpbm 工具集：PBM=位图、PGM=灰度图、PPM=彩色图，
/// 每种各有 ASCII 与二进制两个变体。
enum PnmVariant {
  /// P1：ASCII 位图，每像素一个 `0`/`1` 字符。
  p1AsciiBitmap('P1', 'ASCII 位图 (PBM)', 1, false),

  /// P2：ASCII 灰度图，每像素一个十进制数。
  p2AsciiGray('P2', 'ASCII 灰度图 (PGM)', 1, false),

  /// P3：ASCII 彩色图，每像素三个十进制数。
  p3AsciiRgb('P3', 'ASCII 彩色图 (PPM)', 3, false),

  /// P4：二进制位图，每行按字节对齐打包。
  p4BinaryBitmap('P4', '二进制位图 (PBM)', 1, true),

  /// P5：二进制灰度图。
  p5BinaryGray('P5', '二进制灰度图 (PGM)', 1, true),

  /// P6：二进制彩色图。
  p6BinaryRgb('P6', '二进制彩色图 (PPM)', 3, true);

  const PnmVariant(this.magic, this.description, this.samplesPerPixel, this.isBinary);

  /// 魔数，如 `'P1'`。
  final String magic;

  /// 中文描述，显示在信息面板上。
  final String description;

  /// 每像素样本数：灰度与位图 1，彩色 3。
  final int samplesPerPixel;

  /// 是否二进制变体。
  final bool isBinary;

  /// 是否位图（P1/P4）—— 它们没有 maxval 字段，且 1 表示黑。
  bool get isBitmap =>
      this == PnmVariant.p1AsciiBitmap || this == PnmVariant.p4BinaryBitmap;

  /// 按魔数第二字符查找，如 `'1'` → [p1AsciiBitmap]。
  static PnmVariant? fromDigit(int charCode) {
    switch (charCode) {
      case 0x31:
        return PnmVariant.p1AsciiBitmap;
      case 0x32:
        return PnmVariant.p2AsciiGray;
      case 0x33:
        return PnmVariant.p3AsciiRgb;
      case 0x34:
        return PnmVariant.p4BinaryBitmap;
      case 0x35:
        return PnmVariant.p5BinaryGray;
      case 0x36:
        return PnmVariant.p6BinaryRgb;
      default:
        return null;
    }
  }
}

/// 解析后的 PNM 头部。
class PnmHeader {
  PnmHeader({
    required this.variant,
    required this.width,
    required this.height,
    required this.maxValue,
    required this.dataOffset,
  });

  final PnmVariant variant;
  final int width;
  final int height;

  /// 样本最大值。位图（P1/P4）没有这个字段，固定视为 1。
  ///
  /// 大于 255 时二进制变体的每个样本占 2 字节（大端）。
  final int maxValue;

  /// 像素数据的起始字节偏移。
  final int dataOffset;

  /// 二进制变体里每个样本占几字节。
  int get bytesPerSample => maxValue > 255 ? 2 : 1;

  /// 把原始样本值缩放到 0..255。
  ///
  /// maxval 不一定是 255 —— 规范允许任意 1..65535。常见的有 1（位图）、
  /// 255（8 位）、65535（16 位），但 `maxval 100` 这种也完全合法，
  /// 所以必须按比例缩放而不是简单移位。
  int scaleToByte(int sample) {
    if (maxValue == 255) {
      return sample;
    }
    if (maxValue == 1) {
      return sample == 0 ? 0 : 255;
    }
    // 四舍五入的整数缩放
    final int v = (sample * 255 + maxValue ~/ 2) ~/ maxValue;
    return v < 0 ? 0 : (v > 255 ? 255 : v);
  }

  /// 解析头部，读取位置停在像素数据的第一个字节上。
  ///
  /// 头部形如（`#` 起的注释可出现在任意 token 之间）：
  /// ```
  /// P6
  /// # 这是注释
  /// 4 4
  /// 255
  /// <二进制数据紧随其后>
  /// ```
  static PnmHeader parse(Uint8List bytes) {
    final ByteReader r = ByteReader(bytes, format: 'PNM');

    // —— 魔数 ——
    final int p = r.u8('魔数首字符');
    if (p != 0x50) {
      throw ImageDecodeException(
        'PNM 魔数应以 "P" 开头，实际是 0x${p.toRadixString(16)}',
        format: 'PNM',
        offset: 0,
      );
    }
    final int digit = r.u8('魔数版本号');
    final PnmVariant? variant = PnmVariant.fromDigit(digit);
    if (variant == null) {
      throw ImageDecodeException(
        'PNM 版本号只能是 P1..P6，实际是 "P${String.fromCharCode(digit)}"',
        format: 'PNM',
        offset: 1,
      );
    }

    // —— 宽高 ——
    final int width = _readIntToken(r, '宽度');
    final int height = _readIntToken(r, '高度');
    RgbaImage.validateDimensions(width, height, format: 'PNM');

    // —— maxval：位图没有这个字段 ——
    int maxValue = 1;
    if (!variant.isBitmap) {
      maxValue = _readIntToken(r, 'maxval');
      if (maxValue < 1 || maxValue > 65535) {
        throw ImageDecodeException(
          'maxval 必须在 1..65535 之间，实际是 $maxValue',
          format: 'PNM',
          offset: r.offset,
        );
      }
    }

    // —— 头部与数据的分界 ——
    //
    // 这是二进制变体最容易写错的地方：规范规定最后一个头部 token 之后
    // **恰好一个**空白字符就是分界，之后的字节全部是像素数据。
    //
    // 不能像处理 ASCII 那样"跳过所有空白" —— 如果像素数据的第一个字节
    // 正好是 0x20（空格）或 0x0A（换行），跳过它就会把整幅图错位一个字节。
    if (variant.isBinary) {
      final int? sep = r.peek();
      if (sep == null) {
        throw ImageDecodeException(
          '头部之后没有数据',
          format: 'PNM',
          offset: r.offset,
        );
      }
      if (!_isWhitespace(sep)) {
        throw ImageDecodeException(
          '二进制 PNM 头部之后应有一个空白字符作分界，'
          '实际是 0x${sep.toRadixString(16)}',
          format: 'PNM',
          offset: r.offset,
        );
      }
      r.skip(1);
    }

    return PnmHeader(
      variant: variant,
      width: width,
      height: height,
      maxValue: maxValue,
      dataOffset: r.offset,
    );
  }

  /// 读一个十进制整数 token，跳过前置空白与 `#` 注释。
  static int _readIntToken(ByteReader r, String what) {
    _skipWhitespaceAndComments(r, what);

    final int start = r.offset;
    int value = 0;
    int digits = 0;
    while (true) {
      final int? c = r.peek();
      if (c == null || !_isDigit(c)) {
        break;
      }
      value = value * 10 + (c - 0x30);
      digits++;
      // 防止畸形文件用一长串数字把 value 撑成天文数字。
      // 65535 是规范上限，六位数已经足够判定越界。
      if (digits > 6) {
        throw ImageDecodeException(
          '$what 的数值过大（超过 6 位数）',
          format: 'PNM',
          offset: start,
        );
      }
      r.skip(1);
    }
    if (digits == 0) {
      final int? c = r.peek();
      throw ImageDecodeException(
        '期望 $what 是一个十进制数，'
        '实际读到 ${c == null ? "文件末尾" : "0x${c.toRadixString(16)}"}',
        format: 'PNM',
        offset: start,
      );
    }
    return value;
  }

  /// 跳过空白与注释。
  ///
  /// 注释以 `#` 开始，到行尾结束，可以出现在任意两个 token 之间 ——
  /// 包括魔数与宽度之间、宽度与高度之间。
  static void _skipWhitespaceAndComments(ByteReader r, String what) {
    while (true) {
      final int? c = r.peek();
      if (c == null) {
        throw ImageDecodeException(
          '读取 $what 时文件已结束',
          format: 'PNM',
          offset: r.offset,
        );
      }
      if (_isWhitespace(c)) {
        r.skip(1);
        continue;
      }
      if (c == 0x23) {
        // '#'：吃到行尾
        while (true) {
          final int? cc = r.peek();
          if (cc == null) {
            throw ImageDecodeException(
              '注释后没有 $what',
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
      return;
    }
  }

  /// 空白字符：空格、制表、换行、回车、垂直制表、换页。
  static bool _isWhitespace(int c) =>
      c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D || c == 0x0B || c == 0x0C;

  static bool _isDigit(int c) => c >= 0x30 && c <= 0x39;

  @override
  String toString() =>
      'PnmHeader(${variant.magic}, ${width}x$height, maxval=$maxValue, '
      'data@$dataOffset)';
}
