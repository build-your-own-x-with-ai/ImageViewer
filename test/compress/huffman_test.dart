import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/compress/deflate_tables.dart';
import 'package:image_viewer/src/compress/huffman.dart';
import 'package:image_viewer/src/core/bit_reader_lsb.dart';
import 'package:image_viewer/src/core/errors.dart';

import '../support/deflate_builders.dart';

/// 把一串 (码字, 位数) 写成位流后逐个解码。
List<int> decodeAll(HuffmanTable table, List<List<int>> codes) {
  final BitWriterLsb w = BitWriterLsb();
  for (final List<int> c in codes) {
    w.writeCode(c[0], c[1]);
  }
  final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(w.toBytes()));
  return <int>[for (int i = 0; i < codes.length; i++) table.decode(r)];
}

void main() {
  group('规范化 Huffman：码长唯一决定码字', () {
    // RFC 1951 第 3.2.2 节的例子：三个符号，码长 2、1、3、3。
    // 规范化构造的结果是唯一的 —— 只给码长，编码方和解码方就能
    // 独立算出同一套码字，所以 deflate 的动态块只需要传码长。
    //
    //   符号 A 码长 2 → 10
    //   符号 B 码长 1 → 0
    //   符号 C 码长 3 → 110
    //   符号 D 码长 3 → 111
    final HuffmanTable table =
        HuffmanTable.fromLengths(const <int>[2, 1, 3, 3]);

    test('按规范算出的码字能正确解回符号', () {
      expect(
        decodeAll(table, const <List<int>>[
          <int>[0x0, 1], // B
          <int>[0x2, 2], // A
          <int>[0x6, 3], // C
          <int>[0x7, 3], // D
        ]),
        <int>[1, 0, 2, 3],
      );
    });

    test('符号数与码长表长度一致（码长 0 的不计入）', () {
      expect(table.symbolCount, 4);
      expect(HuffmanTable.fromLengths(const <int>[2, 0, 1, 2]).symbolCount, 3);
    });

    test('码长 0 表示该符号不参与编码', () {
      // 动态块里绝大多数符号的码长是 0 —— 一张只用到十几个字节值的图，
      // 288 个字面量符号里 270 多个都不出现。
      final HuffmanTable t = HuffmanTable.fromLengths(const <int>[1, 0, 0, 1]);
      expect(t.symbolCount, 2);
      expect(
        decodeAll(t, const <List<int>>[
          <int>[0, 1],
          <int>[1, 1],
        ]),
        <int>[0, 3],
      );
    });
  });

  group('固定 Huffman 表', () {
    test('字面量表 288 项，码长按 8/9/7/8 分段', () {
      final List<int> lengths = buildFixedLiteralLengths();
      expect(lengths.length, 288);
      expect(lengths[0], 8);
      expect(lengths[143], 8);
      expect(lengths[144], 9);
      expect(lengths[255], 9);
      expect(lengths[256], 7); // 结束符最短 —— 每个块都要用一次
      expect(lengths[279], 7);
      expect(lengths[280], 8);
      expect(lengths[287], 8);
    });

    test('字面量表的码字与规范给的值对得上', () {
      // RFC 1951 明确给出：0..143 → 00110000..10111111（8 位），
      // 144..255 → 110010000..111111111（9 位），256..279 → 0000000..0010111（7 位）。
      final HuffmanTable t =
          HuffmanTable.fromLengths(buildFixedLiteralLengths());
      expect(
        decodeAll(t, const <List<int>>[
          <int>[0x30, 8], // 符号 0
          <int>[0xBF, 8], // 符号 143
          <int>[0x190, 9], // 符号 144
          <int>[0x1FF, 9], // 符号 255
          <int>[0x00, 7], // 符号 256
          <int>[0xC0, 8], // 符号 280
        ]),
        <int>[0, 143, 144, 255, 256, 280],
      );
    });

    test('距离表 32 项全为 5 位', () {
      final List<int> lengths = buildFixedDistanceLengths();
      expect(lengths.length, 32);
      expect(lengths.every((int l) => l == 5), isTrue);
      // 30、31 两个符号在规范里没有定义含义，但码表里仍占位 ——
      // 因为 32 是 2 的幂，码表刚好填满，构造起来最简单。
    });
  });

  group('非法码长表', () {
    test('过度订阅（码字总数超出容量）被拒', () {
      // 三个 1 位码字：1 位最多只能有 2 个。这在 deflate 里意味着
      // 压缩数据被破坏了，硬解下去会得到一堆错符号。
      expect(
        () => HuffmanTable.fromLengths(const <int>[1, 1, 1]),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('码长表全为 0 得到空表', () {
      // 距离表可以是空的 —— 一个块里全是字面量、没有任何 LZ77 匹配时
      // 就是这种情况。
      final HuffmanTable t = HuffmanTable.fromLengths(const <int>[0, 0, 0]);
      expect(t.isEmpty, isTrue);
      expect(t.symbolCount, 0);
    });

    test('不完整码表被拒，但单码字的退化情况放行', () {
      // 两个 2 位码字只占了 4 个槽里的 2 个，剩下两个位模式无法解码 ——
      // 遇到它们就只能报错，所以构造时就该拒绝。
      expect(
        () => HuffmanTable.fromLengths(const <int>[2, 2]),
        throwsA(isA<ImageDecodeException>()),
      );

      // 但「只有一个 1 位码字」是 zlib 实际会产出的：某些数据里距离码
      // 只用到一个值。规范上这是不完整码表，实现上必须容忍。
      final HuffmanTable single = HuffmanTable.fromLengths(const <int>[1]);
      expect(single.symbolCount, 1);
    });

    test('码长超过 15 位被拒', () {
      expect(kMaxCodeBits, 15);
      expect(
        () => HuffmanTable.fromLengths(const <int>[16, 1]),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('解码时的错误处理', () {
    test('位流耗尽时抛异常而不是返回错符号', () {
      final HuffmanTable t = HuffmanTable.fromLengths(const <int>[1, 1]);
      final BitReaderLsb r = BitReaderLsb(Uint8List(0));
      expect(() => t.decode(r), throwsA(isA<ImageDecodeException>()));
    });

    test('空表解码直接报错', () {
      final HuffmanTable t = HuffmanTable.fromLengths(const <int>[0, 0]);
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0xFF]));
      expect(() => t.decode(r), throwsA(isA<ImageDecodeException>()));
    });

    test('异常信息带上表的用途，便于定位是哪张表出的问题', () {
      final HuffmanTable t = HuffmanTable.fromLengths(
        const <int>[0, 0],
        what: '距离码表',
      );
      final BitReaderLsb r = BitReaderLsb(Uint8List.fromList(<int>[0x00]));
      expect(
        () => t.decode(r),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('距离码表'),
          ),
        ),
      );
    });
  });

  group('deflate 静态表', () {
    test('长度与距离的基值表长度正确', () {
      expect(kLengthBase.length, 29);
      expect(kLengthExtraBits.length, 29);
      expect(kDistanceBase.length, 30);
      expect(kDistanceExtraBits.length, 30);
    });

    test('长度码的边界值', () {
      // 符号 257 对应长度 3（最短匹配），符号 285 对应 258（最长）。
      // 最短是 3 而不是 2：两字节的匹配用「长度+距离」编码通常比直接
      // 写两个字面量更长，不值得。
      expect(kLengthBase.first, 3);
      expect(kLengthBase.last, 258);
      expect(kLengthExtraBits.last, 0); // 285 是单值，无额外位
    });

    test('距离码的边界值', () {
      expect(kDistanceBase.first, 1); // 距离 1 = 重复上一个字节
      expect(kDistanceBase.last, 24577);
      // 最大距离 24577 + (2^13 - 1) = 32768，正好是滑动窗口大小。
      expect(kDistanceBase.last + (1 << kDistanceExtraBits.last) - 1, 32768);
    });

    test('码长顺序表是 19 个值的置换', () {
      expect(kCodeLengthOrder.length, 19);
      expect(kCodeLengthOrder.toSet().length, 19);
      expect(kCodeLengthOrder.reduce((int a, int b) => a > b ? a : b), 18);
      // 开头是 16、17、18 —— 三个重复符号最常用，放前面让 HCLEN
      // 能把后面用不到的位置截掉。
      expect(kCodeLengthOrder.take(3), <int>[16, 17, 18]);
    });
  });
}
