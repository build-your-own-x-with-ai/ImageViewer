/// PNG 的 chunk 容器层：签名校验与 chunk 遍历。
///
/// ## 为什么 PNG 是「一串 chunk」而不是「一个头部加数据」
///
/// BMP 的头部是定长结构体，加字段就得加一个头部版本（BMP 因此有六个版本，
/// 见 `bmp_types.dart`）。PNG 1996 年设计时避开了这条路：每块数据自带
/// 长度和类型，解码器**遇到不认识的类型就按长度跳过**。
///
/// 于是三十年来 PNG 加了几十种 chunk（动画的 `acTL`、色彩管理的 `iCCP`、
/// EXIF 的 `eXIf`），老解码器一个都不认识，却都能正常打开新文件。代价是
/// 每个 chunk 多花 12 字节的开销（长度 4 + 类型 4 + CRC 4）。
///
/// 这个取舍值得记住：**自描述的容器换来的是向前兼容**。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/png/png_crc.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

/// PNG 文件签名，八字节。
///
/// ## 每个字节都在防一种具体的传输事故
///
/// 这是所有格式里设计得最讲究的魔数，1996 年的设计者假定文件会经过各种
/// 会自作聪明改内容的通道（FTP 的文本模式、邮件网关）：
///
/// ```
/// 0x89  高位为 1 —— 走 7 位通道会被剥成 0x09，一测就知道
/// 'P''N''G'  人能读出来，用文本编辑器打开也认得
/// 0x0D 0x0A  CRLF —— 被转成单个 LF 就说明通道改过行尾
/// 0x1A  DOS 的 EOF ——「TYPE 文件.png」会停在这里，不会刷屏乱码
/// 0x0A  LF —— 被转成 CRLF 同样能测出来
/// ```
///
/// 第 3~5 和第 7 字节合起来能识别**四种**行尾转换事故。放在今天多半是
/// 过度设计，但它是「魔数不只是标识，还可以是探针」的最佳教材。
const List<int> kPngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// chunk 长度字段的上限。规范定为 2^31 - 1。
///
/// 规范用 31 位而不是 32 位，是为了让「int 是有符号 32 位」的语言也能安全
/// 处理长度字段而不出现负数。这个上限远大于任何真实文件，所以它实际的作用
/// 是拦住畸形数据。
const int kMaxChunkLength = 0x7FFFFFFF;

/// 一个已读出的 chunk。
class PngChunk {
  const PngChunk({
    required this.type,
    required this.data,
    required this.offset,
  });

  /// 四字符类型名，如 `'IHDR'`。
  final String type;

  /// chunk 数据（不含长度、类型、CRC），是原字节的视图，零拷贝。
  final Uint8List data;

  /// 本 chunk 长度字段在文件里的偏移，用于异常信息。
  final int offset;

  /// 是否是关键 chunk（类型名首字母大写）。
  ///
  /// ## 大小写不是命名风格，是四个功能位
  ///
  /// 类型名的四个字母各自的**第 5 位**（即大小写）都有含义：
  ///
  /// ```
  /// 第 1 字母大写 → 关键 chunk，不认识就必须报错
  /// 第 2 字母大写 → 公有 chunk（登记在册），小写是私有扩展
  /// 第 3 字母      保留，必须大写
  /// 第 4 字母大写 → 不可安全复制（编辑器改图后必须丢弃它）
  /// ```
  ///
  /// 于是解码器面对未知 chunk 时不需要查表就知道该报错还是该跳过 ——
  /// 判断依据就在名字里。`IHDR` 全大写：关键、公有、不可复制。
  /// `tEXt` 首字母小写：辅助信息，跳过无妨。
  bool get isCritical {
    final int first = type.codeUnitAt(0);
    return first >= 0x41 && first <= 0x5A;
  }

  /// 是否是私有 chunk（第 2 字母小写）。
  bool get isPrivate {
    final int second = type.codeUnitAt(1);
    return second >= 0x61 && second <= 0x7A;
  }

  @override
  String toString() => 'PngChunk($type, ${data.length} 字节 @ $offset)';
}

/// 顺序读出 PNG 的各个 chunk。
///
/// 刻意做成「拉取式」而不是一次性全读进 List：`IDAT` 可能有几十个、总量
/// 几 MB，逐个处理完就能丢，不必同时留在内存里。
class PngChunkReader {
  PngChunkReader(Uint8List bytes)
      : _reader = ByteReader(bytes, format: 'PNG'),
        _bytes = bytes {
    _verifySignature();
  }

  final ByteReader _reader;
  final Uint8List _bytes;

  /// 是否还有 chunk 可读。
  bool get hasMore => _reader.remaining > 0;

  /// 当前读取偏移。
  int get offset => _reader.offset;

  void _verifySignature() {
    if (!_reader.matches(kPngSignature, at: 0)) {
      throw ImageDecodeException(
        'PNG 签名不匹配。期望 89 50 4E 47 0D 0A 1A 0A，'
        '实际 ${_hex(_bytes, 8)}',
        format: 'PNG',
        offset: 0,
      );
    }
    _reader.skip(kPngSignature.length, 'PNG 签名');
  }

  static String _hex(Uint8List b, int n) {
    final int count = b.length < n ? b.length : n;
    final List<String> parts = <String>[];
    for (int i = 0; i < count; i++) {
      parts.add(b[i].toRadixString(16).toUpperCase().padLeft(2, '0'));
    }
    return parts.join(' ');
  }

  /// 读下一个 chunk，并校验它的 CRC。
  ///
  /// 顺序是「长度(4) + 类型(4) + 数据 + CRC(4)」。
  PngChunk next() {
    final int chunkOffset = _reader.offset;
    final int length = _reader.u32be('chunk 长度');

    if (length > kMaxChunkLength) {
      throw ImageDecodeException(
        'chunk 长度 $length 超出规范上限 $kMaxChunkLength',
        format: 'PNG',
        offset: chunkOffset,
      );
    }

    final int typeStart = _reader.offset;
    final String type = _reader.ascii(4, 'chunk 类型');

    // 类型名必须是四个 ASCII 字母。这一条能把「长度字段读错导致
    // 位置错位」的情况立刻暴露出来 —— 错位后读到的四字节几乎不可能
    // 恰好都是字母。
    for (int i = 0; i < 4; i++) {
      final int c = type.codeUnitAt(i);
      final bool isLetter =
          (c >= 0x41 && c <= 0x5A) || (c >= 0x61 && c <= 0x7A);
      if (!isLetter) {
        throw ImageDecodeException(
          'chunk 类型 "${_printable(type)}" 含非字母字符。'
          '多半是上一个 chunk 的长度字段有误，导致读取位置错位',
          format: 'PNG',
          offset: typeStart,
        );
      }
    }

    // 数据取视图而非副本 —— IDAT 可能很大，拷贝一遍纯属浪费。
    final Uint8List data = _reader.bytesView(length, '$type chunk 数据');
    final int crc = _reader.u32be('$type chunk 的 CRC');

    verifyChunkCrc(
      _bytes,
      typeStart: typeStart,
      dataLength: length,
      expected: crc,
      type: type,
    );

    return PngChunk(type: type, data: data, offset: chunkOffset);
  }

  static String _printable(String s) {
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      final int c = s.codeUnitAt(i);
      sb.write(c >= 0x20 && c < 0x7F ? s[i] : '.');
    }
    return sb.toString();
  }
}
