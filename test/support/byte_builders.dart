/// 手写字节的辅助构造器。
///
/// 测试里首选手写字节而不是外部样图文件：测试本身就成了格式教材，
/// 读测试就能看懂头部布局，不需要 hex 编辑器。
library;

import 'dart:typed_data';

/// 把 ASCII 文本转成字节。
///
/// PNM 的头部是纯文本，用它写测试比手敲十六进制清楚得多。
Uint8List ascii(String s) {
  return Uint8List.fromList(s.codeUnits);
}

/// 拼接若干字节片段。
///
/// 典型用法是「ASCII 头部 + 二进制像素数据」：
/// ```dart
/// concat([ascii('P5\n2 2\n255\n'), Uint8List.fromList([0, 85, 170, 255])])
/// ```
Uint8List concat(List<List<int>> parts) {
  int total = 0;
  for (final List<int> p in parts) {
    total += p.length;
  }
  final Uint8List out = Uint8List(total);
  int at = 0;
  for (final List<int> p in parts) {
    out.setRange(at, at + p.length, p);
    at += p.length;
  }
  return out;
}

/// 16 位无符号大端。PNG / JPEG 的多字节字段用它。
List<int> u16be(int v) => <int>[(v >> 8) & 0xFF, v & 0xFF];

/// 16 位无符号小端。BMP 用它。
List<int> u16le(int v) => <int>[v & 0xFF, (v >> 8) & 0xFF];

/// 32 位无符号大端。
List<int> u32be(int v) => <int>[
      (v >> 24) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 8) & 0xFF,
      v & 0xFF,
    ];

/// 32 位无符号小端。BMP 的头部字段用它。
List<int> u32le(int v) => <int>[
      v & 0xFF,
      (v >> 8) & 0xFF,
      (v >> 16) & 0xFF,
      (v >> 24) & 0xFF,
    ];

/// 32 位有符号小端。BMP 的 `biHeight` 用它（负值表示自顶向下）。
List<int> i32le(int v) {
  final ByteData d = ByteData(4);
  d.setInt32(0, v, Endian.little);
  return d.buffer.asUint8List().toList();
}
