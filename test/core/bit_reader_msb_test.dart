import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/core/bit_reader_msb.dart';
import 'package:image_viewer/src/core/errors.dart';

void main() {
  group('BitReaderMsb 位序', () {
    test('从字节高位往低位取', () {
      // 0xB2 = 1011 0010，MSB 优先依次取 3/3/2 位
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0xB2]));
      expect(r.readBits(3), 0x5, reason: '101');
      expect(r.readBits(3), 0x4, reason: '100');
      expect(r.readBits(2), 0x2, reason: '10');
    });

    test('readBit 逐位', () {
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0xB2]));
      expect(
        <int>[for (int i = 0; i < 8; i++) r.readBit()],
        <int>[1, 0, 1, 1, 0, 0, 1, 0],
      );
    });

    test('跨字节拼接：先来的字节占高位', () {
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0x0F, 0xF0]),
      );
      expect(r.readBits(12), 0x0FF);
      expect(r.readBits(4), 0x0);
    });

    test('readBits(0) 返回 0 且不消耗位', () {
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0xFF, 0x00]));
      expect(r.readBits(0), 0);
      expect(r.bufferedBits, 0);
    });

    test('一次读超过 24 位视为内部错误', () {
      final BitReaderMsb r = BitReaderMsb(Uint8List(8));
      expect(() => r.readBits(25), throwsA(isA<ImageDecodeException>()));
    });
  });

  group('BitReaderMsb JPEG 字节填充', () {
    test('FF 00 解出真正的数据字节 0xFF', () {
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0xFF, 0x00]),
      );
      expect(r.readBits(8), 0xFF);
      expect(r.hitMarker, isFalse);
    });

    test('FF 00 混在普通数据中间', () {
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0x12, 0xFF, 0x00, 0x34]),
      );
      expect(r.readBits(8), 0x12);
      expect(r.readBits(8), 0xFF);
      expect(r.readBits(8), 0x34);
      expect(r.hitMarker, isFalse);
    });

    test('FF D0 识别为 RST0 marker，熵数据到此结束', () {
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0x2A, 0xFF, 0xD0, 0x33]),
      );
      expect(r.readBits(8), 0x2A);
      expect(r.hitMarker, isFalse);

      // 撞上 marker 后继续读只会拿到补的零位
      expect(r.readBits(8), 0x00);
      expect(r.hitMarker, isTrue);
      expect(r.pendingMarker, 0xD0);
    });

    test('consumePendingMarker 越过 RSTn 继续读下一段', () {
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0x2A, 0xFF, 0xD0, 0x33]),
      );
      r.readBits(8);
      r.readBits(1); // 触发 marker 检测
      expect(r.hitMarker, isTrue);

      r.consumePendingMarker();
      expect(r.hitMarker, isFalse);
      expect(r.readBits(8), 0x33, reason: '应接着读 marker 之后的数据');
    });

    test('marker 前的多个 FF 填充字节要跳过', () {
      // 规范允许 marker 前有任意多个 0xFF
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0x2A, 0xFF, 0xFF, 0xFF, 0xD9]),
      );
      expect(r.readBits(8), 0x2A);
      r.readBits(1);
      expect(r.hitMarker, isTrue);
      expect(r.pendingMarker, 0xD9, reason: 'EOI');
    });
  });

  group('BitReaderMsb receiveExtend —— JPEG 幅值符号还原', () {
    test('n=4 时最高位为 1 是正数，为 0 是负数', () {
      // 0xF0 = 1111 0000
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0xF0]));
      expect(r.receiveExtend(4), 15, reason: '1111 → 正数 15');
      expect(r.receiveExtend(4), -15, reason: '0000 → 负数 -15');
    });

    test('n=3 的完整值域是 -7..-4 与 4..7', () {
      // 逐个验证 8 个码值映射到的实际值
      const List<int> expected = <int>[-7, -6, -5, -4, 4, 5, 6, 7];
      for (int code = 0; code < 8; code++) {
        // 把 3 位码值放在字节最高位
        final BitReaderMsb r = BitReaderMsb(
          Uint8List.fromList(<int>[code << 5]),
        );
        expect(r.receiveExtend(3), expected[code], reason: '码值 $code');
      }
    });

    test('n=0 直接返回 0，不消耗位', () {
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0xAB]));
      expect(r.receiveExtend(0), 0);
      expect(r.readBits(8), 0xAB);
    });
  });

  group('BitReaderMsb 对齐与末尾', () {
    test('alignToByte 丢弃零散位', () {
      final BitReaderMsb r = BitReaderMsb(
        Uint8List.fromList(<int>[0xAB, 0xCD]),
      );
      expect(r.readBits(3), 0x5);
      r.alignToByte();
      expect(r.readBits(8), 0xCD, reason: '应跳到下一个字节');
    });

    test('数据耗尽时补零位并置 hitEnd', () {
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0x01]));
      expect(r.readBits(8), 0x01);
      expect(r.hitEnd, isFalse);
      expect(r.readBits(8), 0x00, reason: '不抛异常，补零 —— 与 libjpeg 一致');
      expect(r.hitEnd, isTrue);
    });

    test('以孤立 0xFF 结尾不崩溃', () {
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0x2A, 0xFF]));
      expect(r.readBits(8), 0x2A);
      expect(r.readBits(8), 0x00);
      expect(r.hitEnd, isTrue);
    });
  });
}
