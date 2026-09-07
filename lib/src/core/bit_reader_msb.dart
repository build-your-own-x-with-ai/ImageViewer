import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// 高位在前（MSB-first）的位读取器 —— JPEG 熵编码数据专用。
///
/// ## 为什么位序要分两个类
///
/// 这是初学者最容易踩的坑。同样一个字节 `0b1011_0010`，读 3 位：
///
/// * MSB 优先（本类）→ 取最高 3 位 `101` = 5
/// * LSB 优先（[BitReaderLsb]）→ 取最低 3 位 `010` = 2
///
/// JPEG 用前者，deflate（PNG）和 VP8L（WebP）用后者。两者绝不能混用，
/// 所以做成两个独立的类而不是一个带 flag 的类 —— 让类型系统直接拦住用错。
///
/// ## JPEG 特有的字节填充
///
/// 熵编码数据里 `0xFF` 有特殊含义，因为它是 marker 的前缀。规范规定：
///
/// * `FF 00` → 数据里真的有一个 `0xFF` 字节，`00` 是填充物，要丢弃
/// * `FF D0`..`FF D7` → RSTn 重启 marker，本段熵数据到此结束
/// * `FF xx`（其它）→ 别的 marker，熵数据到此结束
/// * `FF FF` → 填充字节，marker 前可以有任意多个 `FF`，跳过即可
///
/// 所以本类在字节层面就要处理这些，上层的 Huffman 解码器只管取位。
class BitReaderMsb {
  BitReaderMsb(this.bytes, {int start = 0, this.format = 'JPEG'})
      : _pos = start;

  /// 原始字节。
  final Uint8List bytes;

  /// 格式名，仅用于异常信息。
  final String format;

  int _pos;

  /// 位缓冲：已读入但尚未消费的位，**左对齐**存放在低 [_bitCount] 位里。
  int _bitBuffer = 0;
  int _bitCount = 0;

  /// 遇到的 marker 的第二字节（如 RST0 是 `0xD0`）。没遇到则为 null。
  int? _pendingMarker;

  bool _hitEnd = false;

  /// 当前字节位置。
  int get bytePosition => _pos;

  /// 是否已经撞上 marker（熵数据段结束）。
  bool get hitMarker => _pendingMarker != null;

  /// 撞上的 marker 的第二字节，未撞上则为 null。
  int? get pendingMarker => _pendingMarker;

  /// 是否已读到文件末尾。
  bool get hitEnd => _hitEnd;

  /// 缓冲里还剩多少位没消费（诊断/教学用）。
  int get bufferedBits => _bitCount;

  /// 取下一个**数据字节**，已处理字节填充与 marker 检测。
  ///
  /// 返回 null 表示熵数据结束（撞上 marker 或文件末尾）。
  int? _nextDataByte() {
    if (_pendingMarker != null || _hitEnd) {
      return null;
    }
    if (_pos >= bytes.length) {
      _hitEnd = true;
      return null;
    }
    final int b = bytes[_pos++];
    if (b != 0xFF) {
      return b;
    }

    // 撞上 0xFF，要看下一个字节才知道它是数据还是 marker 前缀。
    // 规范允许 marker 前有任意多个 0xFF 填充字节，所以这里要循环跳过。
    while (_pos < bytes.length && bytes[_pos] == 0xFF) {
      _pos++;
    }
    if (_pos >= bytes.length) {
      // 文件以 0xFF 结尾，既不是合法填充也不是合法 marker。
      _hitEnd = true;
      return null;
    }
    final int next = bytes[_pos];
    if (next == 0x00) {
      _pos++; // 丢弃填充物，返回真正的数据字节 0xFF
      return 0xFF;
    }
    // 是 marker：记下来，但**不**消费这两个字节，
    // 让上层能从 _pos 处继续做 marker 扫描。
    _pos--; // 退回到 0xFF 上
    _pendingMarker = next;
    return null;
  }

  /// 保证缓冲里至少有 [n] 位。
  ///
  /// 数据耗尽时补 0 位而不是抛异常 —— 有些编码器会把末尾的填充位截掉，
  /// libjpeg 和 stb_image 都是补位继续，我们保持一致。补位事实通过
  /// [hitEnd] / [hitMarker] 暴露给上层判断。
  void _fill(int n) {
    while (_bitCount < n) {
      final int? b = _nextDataByte();
      if (b == null) {
        // 补零位。左移让已有的位保持在高位侧。
        _bitBuffer = (_bitBuffer << (n - _bitCount)) & 0x7FFFFFFF;
        _bitCount = n;
        return;
      }
      _bitBuffer = ((_bitBuffer << 8) | b) & 0x7FFFFFFF;
      _bitCount += 8;
    }
  }

  /// 读 1 位。
  int readBit() {
    _fill(1);
    _bitCount -= 1;
    return (_bitBuffer >> _bitCount) & 1;
  }

  /// 读 [n] 位，高位在前。
  ///
  /// [n] 最多 24 —— 位缓冲要留出余量避免超过 31 位（Web 上 Dart 的位运算
  /// 是 32 位语义，越过就静默出错）。JPEG 实际最多一次读 16 位。
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
    _bitCount -= n;
    return (_bitBuffer >> _bitCount) & ((1 << n) - 1);
  }

  /// JPEG 的 EXTEND 过程：把 [n] 位的幅值转成有符号数。
  ///
  /// JPEG 用"幅值类别 + 幅值位"编码差分系数。同一类别里，前半段码值表示
  /// 负数，后半段表示正数。例如 n=3 时：
  ///
  /// ```
  /// 读到 000..011 (0..3)  → 实际值 -7..-4
  /// 读到 100..111 (4..7)  → 实际值  4..7
  /// ```
  ///
  /// 判据是"最高位为 0 则是负数"，转换式 `v - (2^n - 1)`。
  int receiveExtend(int n) {
    if (n == 0) {
      return 0;
    }
    final int v = readBits(n);
    // 最高位为 0 → 落在负数半段
    if (v < (1 << (n - 1))) {
      return v - (1 << n) + 1;
    }
    return v;
  }

  /// 丢弃缓冲里的零散位，回到字节边界。
  ///
  /// 遇到重启 marker（RSTn）时必须调用：每个重启间隔都从字节边界重新开始。
  void alignToByte() {
    _bitCount = 0;
    _bitBuffer = 0;
  }

  /// 越过已检测到的 marker，继续读下一段熵数据。
  ///
  /// 用于 RSTn：调用后清空位缓冲、跳过 `FF Dn` 两个字节、重置 marker 状态。
  void consumePendingMarker() {
    if (_pendingMarker == null) {
      return;
    }
    alignToByte();
    // _pos 停在 0xFF 上（见 _nextDataByte），跳过 FF 与 marker 两字节。
    if (_pos + 1 < bytes.length) {
      _pos += 2;
    } else {
      _pos = bytes.length;
      _hitEnd = true;
    }
    _pendingMarker = null;
  }
}
