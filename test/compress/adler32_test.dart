import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/compress/adler32.dart';

import '../support/deflate_builders.dart';

void main() {
  group('Adler-32 已知值', () {
    test('空数据是 1', () {
      // a 初值 1、b 初值 0，什么都不加就是 b=0, a=1 → 0x00000001。
      // 这个初值不是随便定的：a 从 1 开始，空数据和「一个 0 字节」
      // 才能算出不同的结果。
      expect(adler32(Uint8List(0)), 1);
    });

    test('"Wikipedia" 是 0x11E60398', () {
      // RFC 1950 与维基百科都用这个串举例，是最常见的对照值。
      expect(adler32(Uint8List.fromList('Wikipedia'.codeUnits)), 0x11E60398);
    });

    test('单个 0 字节', () {
      // a = 1 + 0 = 1，b = 0 + 1 = 1 → 0x00010001
      expect(adler32(Uint8List.fromList(<int>[0])), 0x00010001);
    });

    test('单个 0xFF 字节', () {
      // a = 1 + 255 = 256 = 0x100，b = 256 → 0x01000100
      expect(adler32(Uint8List.fromList(<int>[0xFF])), 0x01000100);
    });
  });

  group('与朴素实现交叉验证', () {
    test('各种长度都一致', () {
      // 被测实现为了性能延迟取模（每 5552 字节才取一次），朴素实现
      // 逐字节取模。跨过 5552 这个批处理边界是重点 —— 延迟取模写错时
      // 短数据往往看不出来。
      for (final int len in <int>[1, 2, 15, 255, 256, 5551, 5552, 5553, 12000]) {
        final Uint8List data = Uint8List(len);
        for (int i = 0; i < len; i++) {
          data[i] = (i * 31 + 7) & 0xFF;
        }
        expect(
          adler32(data),
          naiveAdler32(data),
          reason: '长度 $len 处两种实现不一致',
        );
      }
    });

    test('全 0xFF 不溢出', () {
      // b 增长最快的情况。若中间用 32 位有符号数存 b 会在这里溢出。
      final Uint8List data = Uint8List(20000)..fillRange(0, 20000, 0xFF);
      expect(adler32(data), naiveAdler32(data));
    });
  });

  group('区间参数', () {
    final Uint8List data = Uint8List.fromList(<int>[9, 9, 1, 2, 3, 9]);

    test('start 与 end 界定的子区间等价于独立计算', () {
      expect(
        adler32(data, start: 2, end: 5),
        adler32(Uint8List.fromList(<int>[1, 2, 3])),
      );
    });

    test('end 省略时算到末尾', () {
      expect(
        adler32(data, start: 2),
        adler32(Uint8List.fromList(<int>[1, 2, 3, 9])),
      );
    });

    test('空区间返回初值 1', () {
      expect(adler32(data, start: 3, end: 3), 1);
    });
  });

  group('对改动敏感', () {
    test('调换两个字节的顺序会改变结果', () {
      // 这正是 Adler-32 优于「简单求和」的地方：b 累加的是 a 的历史，
      // 所以它对字节顺序敏感。用求和的话 [1,2] 和 [2,1] 无法区分。
      final int ab = adler32(Uint8List.fromList(<int>[1, 2]));
      final int ba = adler32(Uint8List.fromList(<int>[2, 1]));
      expect(ab, isNot(ba));
    });

    test('结果落在 32 位无符号范围内', () {
      final Uint8List data = Uint8List(1000)..fillRange(0, 1000, 0xFF);
      final int sum = adler32(data);
      expect(sum, greaterThanOrEqualTo(0));
      expect(sum, lessThanOrEqualTo(0xFFFFFFFF));
    });
  });
}
