import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// 低位在前（LSB-first）的位读取器 —— deflate（PNG）与 VP8L（WebP）专用。
///
/// 与 [BitReaderMsb] 的区别见那边的注释。这里只强调一件事：
///
/// ```
/// 字节 0b1011_0010，读 3 位 → 取最低 3 位 010 = 2
/// ```
///
/// 位在字节内从低位往高位填，跨字节时**先来的字节占据低位**。所以
/// 读 12 位会拿到 `(byte1 & 0x0F) << 8 | byte0`，而不是 MSB 那样的拼接顺序。
///
/// ## 为什么位缓冲要限制在 24 位
///
/// Dart 在 Web 上编译成 JS，位运算是 32 位有符号语义。一旦缓冲里的值
/// 越过 31 位，`<<` 会静默溢出，产生的错误极难定位（原生平台跑得好好的，
/// 只在 Web 上出错）。所以缓冲上限设在 24 位以内留足余量，单次读取也
/// 限制在 24 位。deflate 最多一次读 16 位，VP8L 最多 24 位，都够用。
class BitReaderLsb {
  BitReaderLsb(this.bytes, {int start = 0, this.format = 'deflate'})
      : _pos = start;

  /// 原始字节。
  final Uint8List bytes;

  /// 格式名，仅用于异常信息。
  final String format;

  int _pos;

  /// 位缓冲。已读入未消费的位放在**低** [_bitCount] 位里。
  int _bitBuffer = 0;
  int _bitCount = 0;

  /// 当前字节位置（不含缓冲里未消费的位）。
  int get bytePosition => _pos;

  /// 缓冲里还剩多少位没消费。
  int get bufferedBits => _bitCount;

  /// 是否所有字节都已读入缓冲。
  bool get isAtEnd => _pos >= bytes.length && _bitCount == 0;

  /// 剩余可读位数（近似，含缓冲）。
  int get remainingBits => (bytes.length - _pos) * 8 + _bitCount;

  /// 保证缓冲里至少有 [n] 位，不够就从字节流补。
  ///
  /// 与 MSB 版不同，这里数据耗尽时**抛异常**。deflate 与 VP8L 的码流是
  /// 自描述的（有明确的结束块标记），读超了一定意味着数据损坏或我们的
  /// 解码逻辑走偏了，静默补零只会把 bug 藏起来。
  void _fill(int n) {
    while (_bitCount < n) {
      if (_pos >= bytes.length) {
        throw ImageDecodeException(
          '压缩数据被截断：还需 ${n - _bitCount} 位，但字节流已耗尽',
          format: format,
          offset: _pos,
        );
      }
      // 新字节放到已有位的**高**位侧：先来的字节占低位。
      _bitBuffer |= bytes[_pos++] << _bitCount;
      _bitCount += 8;
    }
  }

  /// 读 1 位。
  int readBit() {
    _fill(1);
    final int v = _bitBuffer & 1;
    _bitBuffer >>= 1;
    _bitCount -= 1;
    return v;
  }

  /// 读 [n] 位，低位在前。
  int readBits(int n) {
    if (n == 0) {
      return 0;
    }
    if (n < 0 || n > 24) {
      throw ImageDecodeException(
        '内部错误：一次最多读 24 位，请求了 $n 位',
        format: format,
        offset: _pos,
      );
    }
    _fill(n);
    final int v = _bitBuffer & ((1 << n) - 1);
    _bitBuffer >>= n;
    _bitCount -= n;
    return v;
  }

  /// 预览 [n] 位但**不消费**。
  ///
  /// 规范化 Huffman 解码可以用它做查表加速：先 peek 出最大码长的位，
  /// 查表得到符号与实际码长，再 [skipBits] 掉实际用掉的位。
  ///
  /// 与 [readBits] 不同，这里数据不足时补零而不抛异常 —— peek 的语义就是
  /// "看一眼"，码流末尾不足最大码长是正常情况。
  int peekBits(int n) {
    if (n == 0) {
      return 0;
    }
    if (n < 0 || n > 24) {
      throw ImageDecodeException(
        '内部错误：一次最多预览 24 位，请求了 $n 位',
        format: format,
        offset: _pos,
      );
    }
    // 尽力填充，不足则算了。
    while (_bitCount < n && _pos < bytes.length) {
      _bitBuffer |= bytes[_pos++] << _bitCount;
      _bitCount += 8;
    }
    return _bitBuffer & ((1 << n) - 1);
  }

  /// 丢弃 [n] 位。配合 [peekBits] 使用。
  void skipBits(int n) {
    if (n == 0) {
      return;
    }
    _fill(n);
    _bitBuffer >>= n;
    _bitCount -= n;
  }

  /// 丢弃零散位回到字节边界。
  ///
  /// deflate 的 stored（非压缩）块必须调用：块头之后要对齐到字节边界，
  /// 然后才是 LEN/NLEN 与原始数据。
  void alignToByte() {
    final int drop = _bitCount % 8;
    if (drop > 0) {
      _bitBuffer >>= drop;
      _bitCount -= drop;
    }
  }

  /// 按字节读 [count] 字节，要求当前已在字节边界。
  ///
  /// stored 块的原始数据走这条路 —— 逐位读会慢得没必要。
  Uint8List readAlignedBytes(int count) {
    if (_bitCount % 8 != 0) {
      throw ImageDecodeException(
        '内部错误：未对齐到字节边界就读取字节（缓冲余 $_bitCount 位）',
        format: format,
        offset: _pos,
      );
    }
    final Uint8List out = Uint8List(count);
    int written = 0;

    // 先把缓冲里剩的完整字节取出来。
    while (_bitCount >= 8 && written < count) {
      out[written++] = _bitBuffer & 0xFF;
      _bitBuffer >>= 8;
      _bitCount -= 8;
    }
    // 剩下的直接从字节流拷。
    final int fromStream = count - written;
    if (fromStream > 0) {
      if (_pos + fromStream > bytes.length) {
        throw ImageDecodeException(
          '压缩数据被截断：需要 $fromStream 字节，'
          '但只剩 ${bytes.length - _pos} 字节',
          format: format,
          offset: _pos,
        );
      }
      out.setRange(written, count, bytes, _pos);
      _pos += fromStream;
    }
    return out;
  }
}
