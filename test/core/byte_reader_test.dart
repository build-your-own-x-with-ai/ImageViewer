import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

void main() {
  group('ByteReader 基本读取', () {
    test('u8 / i8 顺序推进', () {
      final ByteReader r = ByteReader(Uint8List.fromList(<int>[0x01, 0xFF]));
      expect(r.u8(), 0x01);
      expect(r.offset, 1);
      // 同一个字节，无符号读是 255，有符号读是 -1。
      r.offset = 1;
      expect(r.i8(), -1);
    });

    test('16 位大小端读的是同一批字节的不同解释', () {
      final Uint8List bytes = Uint8List.fromList(<int>[0x12, 0x34]);
      expect(ByteReader(bytes).u16le(), 0x3412);
      expect(ByteReader(bytes).u16be(), 0x1234);
    });

    test('32 位大小端', () {
      final Uint8List bytes = Uint8List.fromList(<int>[0x12, 0x34, 0x56, 0x78]);
      expect(ByteReader(bytes).u32le(), 0x78563412);
      expect(ByteReader(bytes).u32be(), 0x12345678);
    });

    test('i32le 读出负数 —— BMP 的负 height 靠它', () {
      // -4 的小端补码表示
      final Uint8List bytes = Uint8List.fromList(<int>[0xFC, 0xFF, 0xFF, 0xFF]);
      expect(ByteReader(bytes).i32le(), -4);
    });

    test('ascii 读四字符标签', () {
      final ByteReader r = ByteReader(
        Uint8List.fromList(<int>[0x52, 0x49, 0x46, 0x46]),
      );
      expect(r.ascii(4), 'RIFF');
    });

    test('bytesView 是零拷贝视图，copyBytes 是独立副本', () {
      final Uint8List src = Uint8List.fromList(<int>[1, 2, 3, 4]);
      final ByteReader r = ByteReader(src);
      final Uint8List view = r.bytesView(2);
      r.offset = 0;
      final Uint8List copy = r.copyBytes(2);

      src[0] = 99;
      expect(view[0], 99, reason: '视图应随原数组变化');
      expect(copy[0], 1, reason: '副本应与原数组隔离');
    });

    test('skip 与 remaining', () {
      final ByteReader r = ByteReader(Uint8List(10));
      r.skip(4);
      expect(r.offset, 4);
      expect(r.remaining, 6);
      expect(r.isAtEnd, isFalse);
      r.skip(6);
      expect(r.isAtEnd, isTrue);
    });
  });

  group('ByteReader 越界防护 —— 不信任输入的第一道闸', () {
    test('读超末尾抛 ImageDecodeException 而非 RangeError', () {
      final ByteReader r = ByteReader(
        Uint8List.fromList(<int>[0x01]),
        format: 'BMP',
      );
      r.u8();
      expect(
        () => r.u8(),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('异常信息带格式名、偏移与语义说明', () {
      final ByteReader r = ByteReader(
        Uint8List.fromList(<int>[0x01, 0x02]),
        format: 'PNG',
      );
      try {
        r.u32be('IHDR 宽度');
        fail('应当抛异常');
      } on ImageDecodeException catch (e) {
        expect(e.format, 'PNG');
        expect(e.offset, 0);
        final String s = e.toString();
        expect(s, contains('PNG'));
        expect(s, contains('IHDR 宽度'), reason: '要指出是在读什么字段时断的');
        expect(s, contains('截断'));
      }
    });

    test('多字节读取跨越末尾时也拦得住', () {
      // 只有 3 字节却要读 4 字节的 u32
      final ByteReader r = ByteReader(Uint8List.fromList(<int>[1, 2, 3]));
      expect(() => r.u32le(), throwsA(isA<ImageDecodeException>()));
      expect(r.offset, 0, reason: '失败的读取不应推进偏移');
    });

    test('定位到非法位置抛异常', () {
      final ByteReader r = ByteReader(Uint8List(4));
      expect(() => r.offset = 5, throwsA(isA<ImageDecodeException>()));
      expect(() => r.offset = -1, throwsA(isA<ImageDecodeException>()));
      r.offset = 4; // 末尾是合法位置
      expect(r.offset, 4);
    });

    test('请求负数长度视为内部错误', () {
      final ByteReader r = ByteReader(Uint8List(4));
      expect(() => r.skip(-1), throwsA(isA<ImageDecodeException>()));
    });

    test('空文件上的任何读取都失败', () {
      final ByteReader r = ByteReader(Uint8List(0));
      expect(() => r.u8(), throwsA(isA<ImageDecodeException>()));
      expect(r.isAtEnd, isTrue);
    });
  });

  group('ByteReader 预览与魔数匹配', () {
    test('peek 不移动偏移，越界返回 null', () {
      final ByteReader r = ByteReader(Uint8List.fromList(<int>[0x42, 0x4D]));
      expect(r.peek(), 0x42);
      expect(r.peek(1), 0x4D);
      expect(r.peek(2), isNull, reason: '"看一眼"允许看不到');
      expect(r.offset, 0);
    });

    test('matches 做魔数嗅探', () {
      final ByteReader r = ByteReader(
        Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47]),
      );
      expect(r.matches(<int>[0x89, 0x50]), isTrue);
      expect(r.matches(<int>[0x4E, 0x47], at: 2), isTrue);
      expect(r.matches(<int>[0x42, 0x4D]), isFalse);
      expect(r.offset, 0, reason: 'matches 不应移动偏移');
    });

    test('魔数比文件还长时返回 false 而不抛异常', () {
      final ByteReader r = ByteReader(Uint8List.fromList(<int>[0x89]));
      expect(r.matches(<int>[0x89, 0x50, 0x4E, 0x47]), isFalse);
    });
  });
}
