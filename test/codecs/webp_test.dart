import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/webp/webp_decoder.dart';
import 'package:image_viewer/src/codecs/webp/webp_vp8l_transform.dart';
import 'package:image_viewer/src/codecs/webp/webp_types.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

void main() {
  group('WebP container', () {
    test('简单布局 RIFF+WEBP+VP8L', () {
      final bytes = File('assets/samples/gradient_64x48_lossless.webp')
          .readAsBytesSync();
      final img = const WebpDecoder().decode(bytes);
      expect(img.width, 64);
      expect(img.height, 48);
      expect(img.metadata.extra['chunk'], 'VP8L');
    });

    test('VP8X 扩展布局', () {
      final bytes =
          File('assets/samples/disc_64x64_vp8x_exif.webp').readAsBytesSync();
      final img = const WebpDecoder().decode(bytes);
      expect(img.width, 64);
      expect(img.height, 64);
      expect(img.metadata.extra['chunk'], contains('VP8X'));
    });

    test('奇数载荷长度跳过填充字节', () {
      // 手工拼一个 2x1、21 字节载荷（奇数）的 VP8L，末尾放非零填充。
      final vp8l = Uint8List.fromList(const <int>[
        0x2f, 0x01, 0x00, 0x00, 0x00, 0x28, 0x40, 0x01, 0x0a, 0xd0, 0xff,
        0x02, 0x14, 0xa0, 0x00, 0x05, 0xe8, 0x7f, 0x01, 0x0a, 0x00,
      ]);
      const size = 21;
      final out = Uint8List(12 + 8 + size + 1);
      final d = ByteData.sublistView(out);
      out.setAll(0, 'RIFF'.codeUnits);
      d.setUint32(4, 4 + 8 + size + 1, Endian.little);
      out.setAll(8, 'WEBP'.codeUnits);
      out.setAll(12, 'VP8L'.codeUnits);
      d.setUint32(16, size, Endian.little);
      out.setAll(20, vp8l);
      out[41] = 0xAB; // 非零填充，被读到就会出错

      final img = const WebpDecoder().decode(out);
      expect(img.width, 2);
      expect(img.height, 1);
      expect(img.channelsAt(0, 0), <int>[0, 0, 0, 255]);
      expect(img.channelsAt(1, 0), <int>[0, 0, 0, 255]);
    });
  });

  group('VP8L Huffman', () {
    test('简单码零位码路径', () {
      // scratch_build.dart 构造的 2x1 图，全是简单码，每个只有一个符号。
      final bytes = Uint8List.fromList(const <int>[
        0x2f, 0x01, 0x00, 0x00, 0x00, 0x28, 0x40, 0x01, 0x0a, 0xd0, 0xff,
        0x02, 0x14, 0xa0, 0x00, 0x05, 0xe8, 0x7f, 0x01, 0x0a, 0x00,
      ]);
      const size = 21;
      final out = Uint8List(12 + 8 + size);
      final d = ByteData.sublistView(out);
      out.setAll(0, 'RIFF'.codeUnits);
      d.setUint32(4, 4 + 8 + size, Endian.little);
      out.setAll(8, 'WEBP'.codeUnits);
      out.setAll(12, 'VP8L'.codeUnits);
      d.setUint32(16, size, Endian.little);
      out.setAll(20, bytes);

      final img = const WebpDecoder().decode(out);
      expect(img.width, 2);
      expect(img.channelsAt(0, 0), <int>[0, 0, 0, 255]);
      expect(img.channelsAt(1, 0), <int>[0, 0, 0, 255]);
    });
  });

  group('ARGB 打包/拆包', () {
    test('roundtrip', () {
      const a = 0xAB, r = 0x12, g = 0x34, b = 0x56;
      final packed = packArgb(a, r, g, b);
      expect(argbA(packed), a);
      expect(argbR(packed), r);
      expect(argbG(packed), g);
      expect(argbB(packed), b);
    });

    test('全透明黑', () {
      final packed = packArgb(0, 0, 0, 0);
      expect(packed, 0);
    });

    test('不透明白', () {
      final packed = packArgb(255, 255, 255, 255);
      expect(packed, 0xFFFFFFFF);
    });
  });

  group('VP8L 变换', () {
    test('加绿恢复被减过的绿', () {
      // 模拟解码器收到的减绿后的像素
      final pixels = Uint32List.fromList(<int>[
        packArgb(255, 100, 50, 80),
        packArgb(128, 200, 150, 30),
        packArgb(0, 0, 255, 0),
      ]);

      applyAddGreen(pixels);

      // 加绿后 R/B 应该都增加了绿色通道的值
      expect(argbA(pixels[0]), 255);
      expect(argbG(pixels[0]), 50);
      expect(argbR(pixels[0]), (100 + 50) & 0xFF);
      expect(argbB(pixels[0]), (80 + 50) & 0xFF);
    });

    test('扩展色表差分还原', () {
      final raw = Uint32List.fromList(<int>[
        packArgb(255, 10, 20, 30), // 第一个颜色
        packArgb(0, 5, 10, 15), // 差分值
        packArgb(0, 253, 2, 251), // 差分值（会回绕）
      ]);

      final expanded = expandColorMap(raw, 3, colorIndexBits(3));

      // 第一个颜色保持不变
      expect(argbA(expanded[0]), 255);
      expect(argbR(expanded[0]), 10);
      expect(argbG(expanded[0]), 20);
      expect(argbB(expanded[0]), 30);

      // 第二个颜色是第一个加上差分
      expect(argbA(expanded[1]), 255);
      expect(argbR(expanded[1]), 15);
      expect(argbG(expanded[1]), 30);
      expect(argbB(expanded[1]), 45);

      // 第三个颜色是第二个加上差分（模 256）
      expect(argbA(expanded[2]), 255);
      expect(argbR(expanded[2]), (15 + 253) % 256);
      expect(argbG(expanded[2]), 32);
      expect(argbB(expanded[2]), (45 + 251) % 256);
    });

    test('逆变换顺序：从后往前施加', () {
      // 空变换列表
      final pixels = Uint32List.fromList(<int>[packArgb(255, 1, 2, 3)]);
      final result = applyInverseTransforms(<Vp8lTransform>[], pixels);
      expect(result, pixels);
    });
  });
}
