// 临时验证脚本，用完即删。
//
// 手工拼一个最小 VP8L 码流：2x1，像素 0 是字面量不透明黑，像素 1 是一步
// 反向引用（长度 1、距离 1，指回像素 0）。目的是把字节值定死，好当字面量
// 写进测试 —— 覆盖「简单码只有零位码」这条基本不可能从 cwebp 拿到的路径。
import 'dart:typed_data';

import 'package:image_viewer/src/codecs/webp/webp_decoder.dart';

class W {
  final List<int> bits = <int>[];
  void b(int v) => bits.add(v & 1);
  void n(int v, int count) {
    for (int i = 0; i < count; i++) {
      b(v >> i);
    }
  }

  /// 简单码，一个符号。符号值一律用 8 位那档 —— 1 位那档只表示 0 和 1，
  /// 而 alpha 要 255。
  void simple(int symbol) {
    b(1); // 是简单码
    b(0); // 一个符号
    b(1); // 符号值占 8 位
    n(symbol, 8);
  }

  Uint8List bytes() {
    final Uint8List out = Uint8List((bits.length + 7) ~/ 8);
    for (int i = 0; i < bits.length; i++) {
      if (bits[i] != 0) {
        out[i >> 3] |= 1 << (i & 7);
      }
    }
    return out;
  }
}

void main() {
  final W w = W();
  w.n(0x2F, 8); // 签名
  w.n(1, 14); // 宽 2
  w.n(0, 14); // 高 1
  w.b(0); // alpha 提示位
  w.n(0, 3); // 版本 0
  w.b(0); // 没有变换
  w.b(0); // 不开颜色缓存
  w.b(0); // 没有 meta-Huffman 熵图像

  final int tablesAt = w.bits.length;
  w.simple(0); // 绿：只用得到符号 0（字面量）
  w.simple(0); // 红
  w.simple(0); // 蓝
  w.simple(255); // alpha
  w.simple(0); // 距离：符号 0 → 平面码 1 → 距离 1
  print('表起点 $tablesAt 位，表结束 ${w.bits.length} 位');

  final int dataAt = w.bits.length;
  // 像素 0：绿 0（字面量）、红 0、蓝 0、alpha 255。
  w.simple(0);
  w.simple(0);
  w.simple(0);
  w.simple(255);
  // 像素 1：绿 256 → 长度码 0 → 长度 1；距离符号 0 → 平面码 1 → 距离 1。
  w.simple(256);
  w.simple(0);
  print('数据起点 $dataAt 位');

  final Uint8List vp8l = w.bytes();
  print('位数 ${w.bits.length} → ${vp8l.length} 字节');
  print(vp8l
      .map((int b) => '0x${b.toRadixString(16).padLeft(2, '0')}')
      .join(', '));

  for (final int pad in <int>[0, 2]) {
    // pad=2 时给载荷补两个 0 字节凑成奇数长度，看容器能不能跳过对齐字节。
    final Uint8List payload = Uint8List(vp8l.length + pad)
      ..setAll(0, vp8l);
    final int size = payload.length;
    final int padByte = size & 1;
    final Uint8List out = Uint8List(12 + 8 + size + padByte);
    final ByteData d = ByteData.sublistView(out);
    out.setAll(0, 'RIFF'.codeUnits);
    d.setUint32(4, 4 + 8 + size + padByte, Endian.little);
    out.setAll(8, 'WEBP'.codeUnits);
    out.setAll(12, 'VP8L'.codeUnits);
    d.setUint32(16, size, Endian.little);
    out.setAll(20, payload);
    for (int i = 0; i < padByte; i++) {
      out[20 + size + i] = 0xAB; // 非零的填充字节，被当成数据就会露馅
    }

    print('--- 载荷 $size 字节（${size & 1 == 1 ? "奇数，带填充" : "偶数"}），'
        '文件 ${out.length} 字节 ---');
    final img = const WebpDecoder().decode(out);
    print('解出 ${img.width}x${img.height} 变换 ${img.metadata.extra['变换']} '
        'chunk ${img.metadata.extra['chunk']}');
    print('像素0 ${img.channelsAt(0, 0)}  像素1 ${img.channelsAt(1, 0)}');
  }
}
