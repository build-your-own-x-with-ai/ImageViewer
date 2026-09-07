import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// 顺序字节读取器，带越界检查。
///
/// 所有解码器都从这里开始。它存在的理由只有一个：**不信任输入文件**。
///
/// 畸形图像文件最常见的攻击面就是声明一个与实际数据不符的长度 —— 声明
/// 一个 40 字节的 chunk 但只给了 8 字节，或者声明 65535×65535 的尺寸。
/// 如果直接用 `bytes[offset++]`，Dart 会抛 RangeError，信息里没有任何
/// 格式上下文，调试时只能猜。所以这里每次读取前显式检查，并抛出带偏移
/// 和格式名的 [ImageDecodeException]。
class ByteReader {
  ByteReader(this.bytes, {this.format}) : _view = ByteData.sublistView(bytes);

  /// 被读取的原始字节。
  final Uint8List bytes;

  /// 格式名，仅用于异常信息，如 `'BMP'`。
  final String? format;

  /// 用于多字节读取。`ByteData` 的 getter 会处理对齐与端序，
  /// 比手工移位拼装更不容易写错。
  final ByteData _view;

  int _offset = 0;

  /// 当前读取位置。
  int get offset => _offset;

  set offset(int value) {
    if (value < 0 || value > bytes.length) {
      throw ImageDecodeException(
        '定位越界：目标 $value 超出文件范围 0..${bytes.length}',
        format: format,
        offset: _offset,
      );
    }
    _offset = value;
  }

  /// 剩余未读字节数。
  int get remaining => bytes.length - _offset;

  /// 是否已读到末尾。
  bool get isAtEnd => _offset >= bytes.length;

  /// 检查从当前位置起是否还有 [count] 字节可读，不够就抛异常。
  ///
  /// 这是本类的核心。每个读取方法的第一行都是它。
  void ensureAvailable(int count, [String? what]) {
    if (count < 0) {
      throw ImageDecodeException(
        '内部错误：请求读取负数长度 $count',
        format: format,
        offset: _offset,
      );
    }
    if (_offset + count > bytes.length) {
      final String subject = what == null ? '数据' : '"$what"';
      throw ImageDecodeException(
        '文件在此处被截断：读取 $subject 需要 $count 字节，'
        '但只剩 $remaining 字节',
        format: format,
        offset: _offset,
      );
    }
  }

  /// 读一个无符号字节。
  int u8([String? what]) {
    ensureAvailable(1, what);
    return bytes[_offset++];
  }

  /// 读一个有符号字节。
  int i8([String? what]) {
    ensureAvailable(1, what);
    return _view.getInt8(_offset++);
  }

  /// 读 16 位无符号，小端（BMP、部分 TIFF）。
  int u16le([String? what]) {
    ensureAvailable(2, what);
    final int v = _view.getUint16(_offset, Endian.little);
    _offset += 2;
    return v;
  }

  /// 读 16 位无符号，大端（PNG、JPEG —— 网络字节序）。
  int u16be([String? what]) {
    ensureAvailable(2, what);
    final int v = _view.getUint16(_offset, Endian.big);
    _offset += 2;
    return v;
  }

  /// 读 32 位无符号，小端。
  int u32le([String? what]) {
    ensureAvailable(4, what);
    final int v = _view.getUint32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  /// 读 32 位无符号，大端。
  int u32be([String? what]) {
    ensureAvailable(4, what);
    final int v = _view.getUint32(_offset, Endian.big);
    _offset += 4;
    return v;
  }

  /// 读 32 位有符号，小端。
  ///
  /// BMP 的 `biHeight` 需要它 —— 负值表示自顶向下存储。
  int i32le([String? what]) {
    ensureAvailable(4, what);
    final int v = _view.getInt32(_offset, Endian.little);
    _offset += 4;
    return v;
  }

  /// 读 32 位有符号，大端。
  int i32be([String? what]) {
    ensureAvailable(4, what);
    final int v = _view.getInt32(_offset, Endian.big);
    _offset += 4;
    return v;
  }

  /// 读 [count] 字节，返回**视图**（零拷贝，与原数组共享内存）。
  ///
  /// 适合只读扫描的大块数据。若调用方会修改内容，用 [copyBytes]。
  Uint8List bytesView(int count, [String? what]) {
    ensureAvailable(count, what);
    final Uint8List v = Uint8List.sublistView(bytes, _offset, _offset + count);
    _offset += count;
    return v;
  }

  /// 读 [count] 字节，返回独立副本。
  Uint8List copyBytes(int count, [String? what]) {
    ensureAvailable(count, what);
    final Uint8List v = Uint8List.fromList(
      bytes.sublist(_offset, _offset + count),
    );
    _offset += count;
    return v;
  }

  /// 读 [count] 字节并按 Latin-1 解释为字符串。
  ///
  /// 用于 BMP/RIFF 的四字符标签、PNG 的 chunk 类型这类 ASCII 标识。
  /// 刻意不用 UTF-8：这些字段按规范就是单字节标识符，用 UTF-8 解码
  /// 遇到高位字节会抛异常或产生替换字符，反而掩盖问题。
  String ascii(int count, [String? what]) {
    ensureAvailable(count, what);
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < count; i++) {
      sb.writeCharCode(bytes[_offset + i]);
    }
    _offset += count;
    return sb.toString();
  }

  /// 跳过 [count] 字节。
  void skip(int count, [String? what]) {
    ensureAvailable(count, what);
    _offset += count;
  }

  /// 不移动读取位置，预览接下来的第 [ahead] 个字节。
  ///
  /// 魔数嗅探与 PNM 的词法分析需要它。越界返回 `null` 而不抛异常 ——
  /// "看一眼后面有没有东西"本身就该允许没有。
  int? peek([int ahead = 0]) {
    final int i = _offset + ahead;
    if (i < 0 || i >= bytes.length) {
      return null;
    }
    return bytes[i];
  }

  /// 检查从 [at]（默认当前位置）开始的字节是否匹配 [signature]。
  ///
  /// 魔数嗅探用。不移动读取位置，越界返回 false 而非抛异常。
  bool matches(List<int> signature, {int? at}) {
    final int start = at ?? _offset;
    if (start < 0 || start + signature.length > bytes.length) {
      return false;
    }
    for (int i = 0; i < signature.length; i++) {
      if (bytes[start + i] != signature[i]) {
        return false;
      }
    }
    return true;
  }
}
