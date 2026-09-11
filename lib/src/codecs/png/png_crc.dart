/// CRC-32，PNG 每个 chunk 尾部那四个字节。自建表，不用任何库。
///
/// ## 和 zlib 流尾部的 Adler-32 是两回事
///
/// 一个 PNG 里有两套校验，保护对象不同 —— 详见 `compress/adler32.dart`
/// 顶部那张表。简单说：CRC-32 管「箱子有没有破」，Adler-32 管「货对不对」。
///
/// ## 算法：查表法怎么来的
///
/// CRC 的数学定义是把数据当一个巨大的二进制多项式，除以生成多项式取余数。
/// 逐位做要循环 8 次移位判断，每字节 8 次。查表法的洞见是：**一个字节的
/// 8 次移位结果只取决于该字节自身与当前余数的低 8 位**，所以 256 种可能
/// 全部预先算好存表，运行时每字节只需一次查表加一次异或。
///
/// 生成多项式是 `0xEDB88320`，它是 IEEE 802.3 那个标准多项式的**位反转**
/// 形式。之所以用反转形式，是因为 CRC-32 按「低位在前」处理数据，反转过
/// 来写就能直接用右移实现，省掉每步的位序翻转。这也是为什么这个常数看起来
/// 和规范文档里写的 `0x04C11DB7` 完全不像 —— 它们是同一个多项式的两种写法。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// 生成多项式，位反转形式。
const int _kPolynomial = 0xEDB88320;

/// 查找表。首次使用时构造（256 项 × 4 字节 = 1KB，不值得写死在源码里）。
Uint32List? _table;

/// 构造查找表：把每个字节值单独跑一遍 8 次移位，结果存下来。
///
/// 用 [Uint32List] 而不是 `List<int>` 是刻意的：它保证元素**恒为 32 位
/// 无符号**。Dart 在原生平台上 int 是 64 位有符号、在 Web 上是双精度浮点，
/// 两边对「32 位溢出」的处理不同，用定宽类型可以一次性绕开这类差异。
Uint32List _buildTable() {
  final Uint32List table = Uint32List(256);
  for (int n = 0; n < 256; n++) {
    int c = n;
    for (int k = 0; k < 8; k++) {
      // 最低位是 1 就异或多项式。`>>>` 是无符号右移，
      // 保证高位补 0 而不是符号位。
      c = (c & 1) != 0 ? _kPolynomial ^ (c >>> 1) : c >>> 1;
    }
    table[n] = c;
  }
  return table;
}

/// 计算 [data] 在 `[start, end)` 区间上的 CRC-32。
///
/// 初值全 1、末尾再取反，是 CRC-32 规范的一部分：这两步让「开头的一串 0」
/// 也能影响结果。否则前导零字节对余数毫无作用，一个全零文件和空文件会算出
/// 同样的校验和。
int crc32(Uint8List data, {int start = 0, int? end}) {
  final int stop = end ?? data.length;
  RangeError.checkValidRange(start, stop, data.length);

  final Uint32List table = _table ??= _buildTable();
  int c = 0xFFFFFFFF;
  for (int i = start; i < stop; i++) {
    c = table[(c ^ data[i]) & 0xFF] ^ (c >>> 8);
  }
  return (c ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 校验一个 chunk 的 CRC，不符就抛异常。
///
/// ## 计算范围是「类型 + 数据」，不含长度字段
///
/// 这是最容易写错的一处。长度字段被刻意排除在外 —— 于是解码器可以在
/// 不知道长度可信与否的情况下先读类型，再用 CRC 反过来确认长度也是对的。
///
/// [expected] 是文件里写的值，[typeStart] 指向 chunk 类型的第一个字节。
void verifyChunkCrc(
  Uint8List bytes, {
  required int typeStart,
  required int dataLength,
  required int expected,
  required String type,
}) {
  final int actual = crc32(bytes, start: typeStart, end: typeStart + 4 + dataLength);
  if (actual != expected) {
    throw ImageDecodeException(
      '$type chunk 的 CRC-32 校验失败：'
      '文件里写的是 0x${expected.toRadixString(16).padLeft(8, "0")}，'
      '实际算出 0x${actual.toRadixString(16).padLeft(8, "0")}。'
      '这个 chunk 的字节已损坏',
      format: 'PNG',
      offset: typeStart,
    );
  }
}
