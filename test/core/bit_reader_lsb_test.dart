import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/core/bit_reader_lsb.dart';
import 'package:image_viewer/src/core/errors.dart';

void main() {
  group('BitReaderLsb 位序 —— 与 MSB 版正好相反', () {
    test('从字节低位往高位取', () {
      // 同样是 0xB2 = 1011 0010。
      // MSB 优先读 3 位得 0b101 = 5；LSB 优先读 3 位得 0b010 = 2。
      // 这个对照是理解两种位序的关键。
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0xB2]));
      expect(r.readBits(3), 2, reason: '010');
      expect(r.readBits(3), 6, reason: '110');
      expect(r.readBits(2), 2, reason: '10');
    });

    test('readBit 逐位，顺序是从最低位开始', () {
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0xB2]));
      expect(
        <int>[for (int i = 0; i < 8; i++) r.readBit()],
        <int>[0, 1, 0, 0, 1, 1, 0, 1],
        reason: '0xB2 = 1011 0010，从右往左读',
      );
    });

    test('跨字节：先来的字节占低位', () {
      // 这也与 MSB 版相反。MSB 读 12 位得 0x0FF，LSB 得 0x00F。
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x0F, 0xF0]),
      );
      expect(r.readBits(12), 0x00F);
      expect(r.readBits(4), 0xF);
    });

    test('读 24 位不溢出（Web 上位运算是 32 位语义，这是上限所在）', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF]),
      );
      expect(r.readBits(24), 0xFFFFFF);
    });

    test('一次读超过 24 位视为内部错误', () {
      final BitReaderLsb r = BitReaderLsb(Uint8List(8));
      expect(() => r.readBits(25), throwsA(isA<ImageDecodeException>()));
    });

    test('readBits(0) 返回 0 且不消耗位', () {
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0xAB]));
      expect(r.readBits(0), 0);
      expect(r.readBits(8), 0xAB);
    });
  });

  group('BitReaderLsb 截断处理 —— 与 MSB 版策略不同', () {
    test('数据耗尽时抛异常，不补零', () {
      // deflate 与 VP8L 的码流是自描述的（有明确的结束块标记），
      // 读超了一定意味着数据损坏，静默补零只会把 bug 藏起来。
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0x01]));
      expect(r.readBits(8), 0x01);
      expect(() => r.readBit(), throwsA(isA<ImageDecodeException>()));
    });

    test('截断异常信息说明还差多少位', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x01]),
        format: 'PNG',
      );
      try {
        r.readBits(16);
        fail('应当抛异常');
      } on ImageDecodeException catch (e) {
        expect(e.format, 'PNG');
        expect(e.toString(), contains('截断'));
      }
    });

    test('peekBits 在末尾不足时补零而不抛异常', () {
      // peek 的语义是"看一眼"，码流末尾不足最大码长是正常情况 ——
      // 规范化 Huffman 查表解码依赖这个行为。
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0x0F]));
      expect(r.peekBits(16), 0x0F);
      expect(r.bufferedBits, 8, reason: 'peek 不应消费位');
    });
  });

  group('BitReaderLsb peek/skip 配合', () {
    test('peekBits 不消费，skipBits 才消费', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0xB2, 0xFF]),
      );
      expect(r.peekBits(3), 2);
      expect(r.peekBits(3), 2, reason: '再 peek 一次结果相同');
      r.skipBits(3);
      expect(r.peekBits(3), 6, reason: 'skip 之后才推进');
    });
  });

  group('BitReaderLsb 字节对齐 —— deflate stored 块要用', () {
    test('alignToByte 丢弃零散位', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x0F, 0xAA]),
      );
      expect(r.readBits(3), 7, reason: '0x0F 的低 3 位是 111');
      r.alignToByte();
      expect(r.readBits(8), 0xAA, reason: '应跳到下一个字节');
    });

    test('已在字节边界时 alignToByte 是空操作', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x0F, 0xAA]),
      );
      expect(r.readBits(8), 0x0F);
      r.alignToByte();
      expect(r.readBits(8), 0xAA);
    });

    test('readAlignedBytes 从字节流直读', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x01, 0x02, 0x03]),
      );
      expect(r.readAlignedBytes(3), <int>[0x01, 0x02, 0x03]);
      expect(r.isAtEnd, isTrue);
    });

    test('readAlignedBytes 先取尽缓冲里的完整字节', () {
      // peek 会把字节预读进缓冲，readAlignedBytes 必须先消费它们，
      // 否则会丢字节。这是个容易漏掉的边界。
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x0F, 0xAA, 0xBB]),
      );
      r.peekBits(16); // 把前两字节读进缓冲
      expect(r.readBits(8), 0x0F);
      expect(r.bufferedBits, 8, reason: '缓冲里还压着 0xAA');
      expect(r.readAlignedBytes(2), <int>[0xAA, 0xBB]);
    });

    test('未对齐就调 readAlignedBytes 视为内部错误', () {
      final BitReaderLsb r = BitReaderLsb(
        Uint8List.fromList(<int>[0x0F, 0xAA]),
      );
      r.readBits(3);
      expect(() => r.readAlignedBytes(1), throwsA(isA<ImageDecodeException>()));
    });

    test('readAlignedBytes 超出剩余数据时抛异常', () {
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0x01]));
      expect(() => r.readAlignedBytes(4), throwsA(isA<ImageDecodeException>()));
    });
  });

  group('BitReaderLsb 位置追踪', () {
    test('remainingBits 含缓冲里未消费的位', () {
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0x01, 0x02]));
      expect(r.remainingBits, 16);
      r.readBits(3);
      expect(r.remainingBits, 13);
    });

    test('isAtEnd 要求字节流与缓冲都空', () {
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0x01]));
      expect(r.isAtEnd, isFalse);
      r.readBits(4);
      expect(r.isAtEnd, isFalse, reason: '缓冲里还剩 4 位');
      r.readBits(4);
      expect(r.isAtEnd, isTrue);
    });
  });
}
