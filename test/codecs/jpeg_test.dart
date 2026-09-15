import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_frame.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_huffman.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_idct.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_markers.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';
import 'package:image_viewer/src/core/bit_reader_msb.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 一张 8 位量化表的 DQT 载荷：`[Pq|Tq]` 一字节 + 64 项。
Uint8List dqtPayload({int id = 0, int fill = 16}) {
  final Uint8List d = Uint8List(1 + kBlockSize);
  d[0] = id;
  for (int i = 0; i < kBlockSize; i++) {
    d[1 + i] = fill;
  }
  return d;
}

/// 16 项的 BITS 数组，只填指定码长。键是码长（1 起），值是该码长的码字个数。
List<int> bits(Map<int, int> lengthToCount) {
  final List<int> counts = List<int>.filled(kMaxJpegCodeBits, 0);
  for (final MapEntry<int, int> e in lengthToCount.entries) {
    counts[e.key - 1] = e.value;
  }
  return counts;
}

/// 跑一个块，返回紧凑的 8×8 输出。
Uint8List runIdct(Idct idct, Int32List block) {
  final Uint8List out = Uint8List(kBlockSize);
  idct.transform(block, out, 0, kBlockDim);
  return out;
}

/// 一个 SOF 段的载荷：精度 8、给定宽高，分量按 `[id, h, v, tq]` 四元组给。
Uint8List sofPayload(
  int width,
  int height,
  List<List<int>> comps, {
  int precision = 8,
}) {
  final List<int> d = <int>[
    precision,
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    comps.length,
  ];
  for (final List<int> c in comps) {
    d.addAll(<int>[c[0], (c[1] << 4) | c[2], c[3]]);
  }
  return Uint8List.fromList(d);
}

/// 朴素正变换：把 64 个 0..255 的样本变成一个**真实编码器可能产出**的系数块。
///
/// 测试里要「合法极值」时不能直接随机填 ±2047 —— 那个范围是存储上限，不是
/// 可达集合。正变换的能量上界（Parseval）把 8 位样本能生成的系数锁得死死的，
/// 只有从空间域倒推才拿得到真正能出现在文件里的极端块。
Int32List forwardDct(Uint8List samples) {
  final Int32List block = Int32List(kBlockSize);
  for (int v = 0; v < kBlockDim; v++) {
    final double cv = v == 0 ? math.sqrt1_2 : 1.0;
    for (int u = 0; u < kBlockDim; u++) {
      final double cu = u == 0 ? math.sqrt1_2 : 1.0;
      double sum = 0;
      for (int y = 0; y < kBlockDim; y++) {
        for (int x = 0; x < kBlockDim; x++) {
          sum += (samples[y * kBlockDim + x] - 128) *
              math.cos((2 * x + 1) * u * math.pi / 16) *
              math.cos((2 * y + 1) * v * math.pi / 16);
        }
      }
      block[v * kBlockDim + u] = (sum * cu * cv / 4).round();
    }
  }
  return block;
}

void main() {
  group('JPEG 段扫描', () {
    test('SOI + APP0 + EOI 的完整走法', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xFF, 0xD8, // SOI
        0xFF, 0xE0, 0x00, 0x04, 0xAA, 0xBB, // APP0，声明 4 = 2 字节数据
        0xFF, 0xD9, // EOI
      ]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes);
      s.readSoi();
      expect(s.offset, 2);

      final JpegSegment app0 = s.next()!;
      expect(app0.marker, kMarkerApp0);
      expect(app0.offset, 2);
      expect(app0.dataOffset, 6);
      expect(app0.length, 2, reason: '长度字段含自身两字节，4 - 2 = 2');
      expect(s.dataOf(app0), <int>[0xAA, 0xBB]);
      expect(app0.name, 'APP0');

      final JpegSegment eoi = s.next()!;
      expect(eoi.marker, kMarkerEoi);
      expect(eoi.length, 0, reason: '独立 marker 没有长度字段');

      expect(s.next(), isNull);
      expect(s.hasMore, isFalse);
    });

    test('marker 之前的 0xFF 填充要跳过', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xFF, 0xD8, //
        0xFF, 0xFF, 0xFF, 0xE0, 0x00, 0x02, // 两个多余的 0xFF
        0xFF, 0xD9, //
      ]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      final JpegSegment app0 = s.next()!;
      expect(app0.marker, kMarkerApp0);
      expect(app0.length, 0);
      expect(s.next()!.marker, kMarkerEoi);
    });

    test('段之间的杂字节要跳过（0xFF 重新同步）', () {
      final Uint8List bytes = Uint8List.fromList(<int>[
        0xFF, 0xD8, //
        0xAA, 0xBB, 0xCC, // 上一段长度写错留下的垃圾
        0xFF, 0xD9, //
      ]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      final JpegSegment eoi = s.next()!;
      expect(eoi.marker, kMarkerEoi);
      expect(eoi.offset, 5, reason: '停在 0xFF 上，不是垃圾的起点');
    });

    test('文件以单个 0xFF 结尾当作正常结束', () {
      final Uint8List bytes =
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xD9, 0xFF]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      expect(s.next()!.marker, kMarkerEoi);
      expect(s.next(), isNull, reason: '尾部多一个字节不该让整张图作废');
    });

    test('SOI 不对要报错', () {
      expect(
        () => JpegSegmentScanner(Uint8List.fromList(<int>[0x89, 0x50])).readSoi(),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('文件短到放不下 SOI 要报错', () {
      expect(
        () => JpegSegmentScanner(Uint8List.fromList(<int>[0xFF])).readSoi(),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('段边界上的 FF 00 要报错', () {
      final Uint8List bytes =
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0x00, 0xFF, 0xD9]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      expect(s.next, throwsA(isA<ImageDecodeException>()));
    });

    test('长度字段小于 2 要报错', () {
      final Uint8List bytes = Uint8List.fromList(
          <int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x01, 0xFF, 0xD9]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      expect(s.next, throwsA(isA<ImageDecodeException>()));
    });

    test('声明长度超出文件要报错', () {
      final Uint8List bytes =
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF, 0xE0, 0x00, 0x40, 0xAA]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      expect(s.next, throwsA(isA<ImageDecodeException>()));
    });

    test('offset 可写回：熵解码器停下来后由调用方接管位置', () {
      final Uint8List bytes =
          Uint8List.fromList(<int>[0xFF, 0xD8, 0xAA, 0xAA, 0xFF, 0xD9]);
      final JpegSegmentScanner s = JpegSegmentScanner(bytes)..readSoi();
      s.offset = 4;
      expect(s.next()!.marker, kMarkerEoi);
    });
  });

  group('JPEG marker 分类', () {
    test('独立 marker 没有长度字段', () {
      for (final int m in <int>[kMarkerSoi, kMarkerEoi, kMarkerTem]) {
        expect(isStandalone(m), isTrue, reason: markerName(m));
      }
      for (int m = kMarkerRst0; m <= kMarkerRst7; m++) {
        expect(isStandalone(m), isTrue, reason: 'RST');
        expect(isRestart(m), isTrue);
      }
      for (final int m in <int>[kMarkerSof0, kMarkerDqt, kMarkerSos, kMarkerApp0]) {
        expect(isStandalone(m), isFalse, reason: markerName(m));
      }
    });

    test('isSof 要绕开 0xC4（DHT）和 0xCC（DAC）两个洞', () {
      expect(isSof(kMarkerSof0), isTrue);
      expect(isSof(kMarkerSof2), isTrue);
      expect(isSof(0xC3), isTrue, reason: 'SOF3 无损，也是 SOF');
      expect(isSof(kMarkerDht), isFalse, reason: '0xC4 在 SOF 区间里但是 DHT');
      expect(isSof(0xCC), isFalse, reason: '0xCC 是 DAC');
      expect(isSof(kMarkerDqt), isFalse);
    });

    test('APPn 区间与命名', () {
      expect(isApp(kMarkerApp0), isTrue);
      expect(isApp(kMarkerApp15), isTrue);
      expect(isApp(kMarkerCom), isFalse, reason: '0xFE 在 APP 之后');
      expect(markerName(kMarkerApp0), 'APP0');
      expect(markerName(kMarkerApp1), 'APP1');
      expect(markerName(kMarkerApp14), 'APP14');
      expect(markerName(kMarkerRst0), 'RST0');
      expect(markerName(kMarkerRst7), 'RST7');
      expect(markerName(kMarkerSos), 'SOS');
      expect(markerName(0x02), contains('未知'), reason: '兜底不该崩');
    });
  });

  group('JPEG 量化表', () {
    test('一个 DQT 段里可以有多张表', () {
      final Uint8List data = Uint8List.fromList(<int>[
        ...dqtPayload(fill: 16),
        ...dqtPayload(id: 1, fill: 24),
      ]);
      final List<QuantizationTable> tables = parseDqt(data, offset: 4);
      expect(tables.length, 2, reason: '写死读一张表会打不开常见文件');
      expect(tables[0].id, 0);
      expect(tables[0].precision, 8);
      expect(tables[0].dcQuant, 16);
      expect(tables[1].id, 1);
      expect(tables[1].averageQuant, 24);
    });

    test('16 位精度表每项两字节', () {
      final Uint8List data = Uint8List(1 + kBlockSize * 2);
      data[0] = 0x10; // Pq=1，Tq=0
      for (int i = 0; i < kBlockSize; i++) {
        data[1 + i * 2] = 0x01; // 高字节
        data[2 + i * 2] = 0x00; // 低字节 → 256
      }
      final List<QuantizationTable> tables = parseDqt(data, offset: 0);
      expect(tables.single.precision, 16);
      expect(tables.single.dcQuant, 256);
    });

    test('量化表里的 0 是致命的', () {
      final Uint8List data = dqtPayload();
      data[1 + 5] = 0;
      expect(
        () => parseDqt(data, offset: 0),
        throwsA(isA<ImageDecodeException>()),
        reason: '反量化要乘它，整块会变成一片纯灰',
      );
    });

    test('Pq / Tq 越界与空段要报错', () {
      final Uint8List badPq = dqtPayload()..[0] = 0x20;
      expect(() => parseDqt(badPq, offset: 0),
          throwsA(isA<ImageDecodeException>()));

      final Uint8List badTq = dqtPayload()..[0] = 0x04;
      expect(() => parseDqt(badTq, offset: 0),
          throwsA(isA<ImageDecodeException>()));

      expect(() => parseDqt(Uint8List(0), offset: 0),
          throwsA(isA<ImageDecodeException>()));
    });

    test('表项少于 64 要报错', () {
      expect(
        () => parseDqt(Uint8List.sublistView(dqtPayload(), 0, 40), offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('zigzag 顺序：前几项走出对角折返', () {
      expect(kZigzagOrder.length, kBlockSize);
      expect(kZigzagOrder.take(6), <int>[0, 1, 8, 16, 9, 2]);
      expect(kZigzagOrder.last, 63);
      expect(kZigzagOrder.toSet().length, kBlockSize, reason: '必须是排列');
    });

    test('反量化同时做 zigzag 反序', () {
      final Int32List coefficients = Int32List(kBlockSize);
      coefficients[0] = 3; // DC
      coefficients[2] = 5; // zigzag 第 3 项 → 自然序下标 8
      final QuantizationTable table = parseDqt(dqtPayload(fill: 2), offset: 0)
          .single;
      final Int32List out = Int32List(kBlockSize);
      dequantizeBlock(coefficients, table, out);

      expect(out[0], 6, reason: '3 × 2');
      expect(out[8], 10, reason: 'zigzag 第 3 项落在自然序 8');
      expect(out[1], 0);
    });

    test('naturalValues 是 zigzagValues 的重排', () {
      final Uint8List data = dqtPayload();
      for (int i = 0; i < kBlockSize; i++) {
        data[1 + i] = i + 1; // 1..64，好认位置
      }
      final QuantizationTable t = parseDqt(data, offset: 0).single;
      final Int32List natural = t.naturalValues;
      for (int i = 0; i < kBlockSize; i++) {
        expect(natural[kZigzagOrder[i]], t.zigzagValues[i], reason: 'i=$i');
      }
    });
  });

  group('JPEG 霍夫曼码表', () {
    // BITS = {2 位两个, 3 位一个}，HUFFVAL = [0xA, 0xB, 0xC]
    // 规范码字：00 → 0xA，01 → 0xB，100 → 0xC
    JpegHuffmanTable sample() => JpegHuffmanTable.build(
          tableClass: HuffmanTableClass.dc,
          id: 0,
          counts: bits(<int, int>{2: 2, 3: 1}),
          symbols: Uint8List.fromList(<int>[0xA, 0xB, 0xC]),
        );

    test('规范码字按码长递增分配', () {
      // 00 01 100 + 补一位 0 = 0001 1000 = 0x18
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0x18]));
      final JpegHuffmanTable t = sample();
      expect(t.decode(r), 0xA);
      expect(t.decode(r), 0xB);
      expect(t.decode(r), 0xC);
      expect(t.symbolCount, 3);
      expect(t.maxCodeBits, 3);
      expect(t.tableClass, HuffmanTableClass.dc);
    });

    test('过订阅要报错', () {
      expect(
        () => JpegHuffmanTable.build(
          tableClass: HuffmanTableClass.ac,
          id: 0,
          counts: bits(<int, int>{1: 3}), // 1 位最多两个码字
          symbols: Uint8List.fromList(<int>[1, 2, 3]),
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('不完整码表必须接受（规范保留全 1 码字）', () {
      // 只有一个 1 位码字，编码空间没用满。deflate 会拒，JPEG 不能拒 ——
      // Annex K 的标准表本来就是不完整的。
      final JpegHuffmanTable t = JpegHuffmanTable.build(
        tableClass: HuffmanTableClass.dc,
        id: 0,
        counts: bits(<int, int>{1: 1}),
        symbols: Uint8List.fromList(<int>[0x5]),
      );
      expect(t.decode(BitReaderMsb(Uint8List.fromList(<int>[0x00]))), 0x5);
    });

    test('位模式落进空洞：16 位读完才能发现', () {
      final JpegHuffmanTable t = JpegHuffmanTable.build(
        tableClass: HuffmanTableClass.dc,
        id: 0,
        counts: bits(<int, int>{1: 1}),
        symbols: Uint8List.fromList(<int>[0x5]),
      );
      // 首位是 1，走进保留的那一半，此后无论怎么补都匹配不上。
      final BitReaderMsb r = BitReaderMsb(Uint8List.fromList(<int>[0x80, 0x00]));
      expect(() => t.decode(r), throwsA(isA<ImageDecodeException>()));
    });

    test('BITS 之和与 HUFFVAL 长度必须相等', () {
      expect(
        () => JpegHuffmanTable.build(
          tableClass: HuffmanTableClass.dc,
          id: 0,
          counts: bits(<int, int>{2: 2}),
          symbols: Uint8List.fromList(<int>[1]),
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('空表要报错', () {
      expect(
        () => JpegHuffmanTable.build(
          tableClass: HuffmanTableClass.dc,
          id: 0,
          counts: bits(<int, int>{}),
          symbols: Uint8List(0),
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('BITS 不是 16 项属于内部错误', () {
      expect(
        () => JpegHuffmanTable.build(
          tableClass: HuffmanTableClass.dc,
          id: 0,
          counts: List<int>.filled(15, 0),
          symbols: Uint8List.fromList(<int>[1]),
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('Tc 只有 0/1 两种', () {
      expect(HuffmanTableClass.fromValue(0), HuffmanTableClass.dc);
      expect(HuffmanTableClass.fromValue(1), HuffmanTableClass.ac);
      expect(HuffmanTableClass.dc.value, 0);
      expect(HuffmanTableClass.ac.label, 'AC');
      expect(() => HuffmanTableClass.fromValue(2),
          throwsA(isA<ImageDecodeException>()));
    });

    test('一个 DHT 段里可以有多张表', () {
      final Uint8List data = Uint8List.fromList(<int>[
        0x00, // Tc=0（DC）, Th=0
        ...bits(<int, int>{2: 2, 3: 1}),
        0xA, 0xB, 0xC,
        0x11, // Tc=1（AC）, Th=1
        ...bits(<int, int>{1: 1}),
        0x7,
      ]);
      final List<JpegHuffmanTable> tables = parseDht(data, offset: 0);
      expect(tables.length, 2);
      expect(tables[0].tableClass, HuffmanTableClass.dc);
      expect(tables[0].id, 0);
      expect(tables[0].symbolCount, 3);
      expect(tables[1].tableClass, HuffmanTableClass.ac);
      expect(tables[1].id, 1);
    });

    test('Th 越界、空段要报错', () {
      final Uint8List badTh = Uint8List.fromList(<int>[
        0x04, // Th=4
        ...bits(<int, int>{1: 1}),
        0x1,
      ]);
      expect(() => parseDht(badTh, offset: 0),
          throwsA(isA<ImageDecodeException>()));
      expect(() => parseDht(Uint8List(0), offset: 0),
          throwsA(isA<ImageDecodeException>()));
    });
  });

  group('JPEG IDCT', () {
    final IdctNaive naive = const IdctNaive();
    final IdctFast fast = IdctFast();

    test('全零块 → 一片 128（电平位移的中点）', () {
      final Int32List block = Int32List(kBlockSize);
      expect(runIdct(naive, block), everyElement(128));
      expect(runIdct(fast, block), everyElement(128));
    });

    test('只有 DC → 一片平坦，两套实现同值', () {
      final Int32List block = Int32List(kBlockSize)..[0] = 512;
      expect(runIdct(naive, block), everyElement(192),
          reason: '512 × ½ ÷ 4 + 128');
      expect(runIdct(fast, block), everyElement(192));

      final Int32List negative = Int32List(kBlockSize)..[0] = -512;
      expect(runIdct(naive, negative), everyElement(64));
      expect(runIdct(fast, negative), everyElement(64));
    });

    test('越界的重建值饱和到 0/255，不报错', () {
      // 有损压缩下重建值冲出 0..255 是正常现象（振铃），不是文件坏了。
      final Int32List high = Int32List(kBlockSize)..[0] = 20000;
      expect(runIdct(naive, high), everyElement(255));
      expect(runIdct(fast, high), everyElement(255));

      final Int32List low = Int32List(kBlockSize)..[0] = -20000;
      expect(runIdct(naive, low), everyElement(0));
      expect(runIdct(fast, low), everyElement(0));
    });

    test('clampSample 边界', () {
      expect(clampSample(-1), 0);
      expect(clampSample(0), 0);
      expect(clampSample(128), 128);
      expect(clampSample(255), 255);
      expect(clampSample(256), 255);
      expect(clampSample(-100000), 0);
      expect(clampSample(100000), 255);
    });

    test('两套实现在随机块上一致（真实系数范围）', () {
      // 这条断言替代「盯着蝶形连线图核对」—— 快版本写错时，几百个随机块
      // 里几乎必然有一个对不上。
      final math.Random rng = math.Random(20260910);
      int worst = 0;
      for (int trial = 0; trial < 300; trial++) {
        final Int32List block = Int32List(kBlockSize);
        block[0] = rng.nextInt(2048) - 1024;
        // 稀疏 AC：量化后的真实块就是这个样子，高频基本被清零。
        for (int k = 0; k < 8; k++) {
          block[1 + rng.nextInt(kBlockSize - 1)] = rng.nextInt(512) - 256;
        }
        final Uint8List a = runIdct(naive, block);
        final Uint8List b = runIdct(fast, block);
        for (int i = 0; i < kBlockSize; i++) {
          final int d = (a[i] - b[i]).abs();
          if (d > worst) {
            worst = d;
          }
        }
      }
      expect(worst, lessThanOrEqualTo(1),
          reason: '定点舍入允许差 1，差更多说明蝶形接错了');
    });

    test('从空间域倒推的合法极值块上两套实现一致，且能还原样本', () {
      // 极端但**可达**的输入：0..255 随机样本正变换回来。这样的块才是真实
      // 编码器能写进文件的东西，clamp 在这里一次都不该生效。
      // 顺带把还原精度也钉住 —— 正变换 + 反变换应该回到原样本附近，这一条
      // 同时验证了 IDCT 的归一化系数（差个 2 倍或 √2 会立刻露馅）。
      final math.Random rng = math.Random(7);
      int worstPair = 0;
      int worstRound = 0;
      for (int trial = 0; trial < 100; trial++) {
        final Uint8List samples = Uint8List(kBlockSize);
        for (int i = 0; i < kBlockSize; i++) {
          samples[i] = rng.nextInt(256);
        }
        final Int32List block = forwardDct(samples);
        final Uint8List a = runIdct(naive, block);
        final Uint8List b = runIdct(fast, block);
        for (int i = 0; i < kBlockSize; i++) {
          final int pair = (a[i] - b[i]).abs();
          if (pair > worstPair) {
            worstPair = pair;
          }
          final int round = (a[i] - samples[i]).abs();
          if (round > worstRound) {
            worstRound = round;
          }
        }
      }
      expect(worstPair, lessThanOrEqualTo(1),
          reason: '合法极值下 ±32767 的 clamp 不该削到数据，实测最大差 $worstPair');
      expect(worstRound, lessThanOrEqualTo(3),
          reason: '往返只该差在系数取整上，实测最大差 $worstRound');
    });

    test('全 64 项取 ±2047 时快版本被 clamp 截住 —— 这是设计的一部分', () {
      // ±2047 是存储上限，不是可达集合：要让中间值填满这个范围，得要求列变换
      // 输出到 ±61182，远超 ±32767 的夹取界。这种块只能来自损坏或恶意数据，
      // 对它我们只承诺三件事 —— 不崩、落在 0..255、每次跑出同一份结果。
      final math.Random rng = math.Random(11);
      final Int32List block = Int32List(kBlockSize);
      for (int i = 0; i < kBlockSize; i++) {
        block[i] = rng.nextInt(4095) - 2047;
      }
      final Int32List copy = Int32List.fromList(block);

      final Uint8List first = runIdct(fast, block);
      final Uint8List second = runIdct(fast, copy);
      expect(first, second, reason: '同一份垃圾输入必须给出同一份垃圾输出');

      // 与浮点基准的差可以很大，但不该是「随机数」那种大：夹取只压缩幅度，
      // 不会翻转符号，所以两边对「亮还是暗」的判断仍然一致。
      final Uint8List reference = runIdct(naive, block);
      int agreeOnSide = 0;
      for (int i = 0; i < kBlockSize; i++) {
        final bool sameSide = (first[i] >= 128) == (reference[i] >= 128);
        if (sameSide) {
          agreeOnSide++;
        }
      }
      expect(agreeOnSide, greaterThanOrEqualTo(kBlockSize ~/ 2),
          reason: '夹取只该压幅度，不该把亮暗关系搅乱');
    });

    test('只写 8×8 窗口，不碰平面上的邻居', () {
      // 块在分量平面上不连续，写越界会污染同一行的下一个块 —— 那种错误
      // 表现为「图像右侧有一条错位的竖带」，很难从现象反推原因。
      const int stride = 16;
      final Uint8List plane = Uint8List(stride * 10)..fillRange(0, stride * 10, 7);
      final int origin = stride * 1 + 4;
      final Int32List block = Int32List(kBlockSize)..[0] = 512;
      fast.transform(block, plane, origin, stride);

      for (int i = 0; i < plane.length; i++) {
        final int row = i ~/ stride;
        final int col = i % stride;
        final bool inside =
            row >= 1 && row <= 8 && col >= 4 && col <= 11;
        expect(plane[i], inside ? 192 : 7, reason: '行 $row 列 $col');
      }
    });

    test('不修改输入块，且实例可重复使用', () {
      final Int32List block = Int32List(kBlockSize)
        ..[0] = 300
        ..[1] = -120
        ..[9] = 44;
      final Int32List copy = Int32List.fromList(block);
      final Uint8List first = runIdct(fast, block);
      expect(block, copy, reason: '系数数组是只读的');

      // 复用 _work 缓冲不能串味：换一个块再换回来，结果必须一致。
      runIdct(fast, Int32List(kBlockSize)..[0] = -900);
      expect(runIdct(fast, block), first);
    });

    test('只有一个水平 AC → 水平余弦条纹，八行相同', () {
      final Int32List block = Int32List(kBlockSize)..[1] = 512;
      for (final Idct idct in <Idct>[naive, fast]) {
        final Uint8List out = runIdct(idct, block);
        for (int y = 1; y < kBlockDim; y++) {
          for (int x = 0; x < kBlockDim; x++) {
            expect(out[y * kBlockDim + x], out[x],
                reason: '${idct.name}：垂直方向没有变化，八行必须一样');
          }
        }
        for (int x = 0; x < kBlockDim; x++) {
          final int sum = out[x] + out[kBlockDim - 1 - x];
          expect(sum, closeTo(256, 1),
              reason: '${idct.name}：基函数关于中心反对称，两端之和 = 2 × 128');
        }
      }
    });

    test('AC 全零走捷径，结果和一般路径一致', () {
      // 捷径是性能优化，不能改变结果。DC 相同、AC 全零的块必须和
      // 「AC 只有一个极小值」的块给出几乎相同的输出。
      final Int32List shortcut = Int32List(kBlockSize)..[0] = 700;
      final Int32List general = Int32List(kBlockSize)
        ..[0] = 700
        ..[63] = 1; // 最高频塞一个 1，逼它走蝶形
      final Uint8List a = runIdct(fast, shortcut);
      final Uint8List b = runIdct(fast, general);
      for (int i = 0; i < kBlockSize; i++) {
        expect((a[i] - b[i]).abs(), lessThanOrEqualTo(1), reason: 'i=$i');
      }
    });

    test('两套实现自报身份，供信息面板展示', () {
      expect(naive.name, isNotEmpty);
      expect(fast.name, isNotEmpty);
      expect(naive.name, isNot(fast.name));
      expect(naive.description, isNotEmpty);
      expect(fast.description, isNotEmpty);
    });
  });

  group('JPEG 帧几何', () {
    test('4:2:0 正好对齐 MCU 时两套块数相同', () {
      final JpegFrame f = parseSof(
        sofPayload(16, 16, <List<int>>[
          <int>[1, 2, 2, 0],
          <int>[2, 1, 1, 1],
          <int>[3, 1, 1, 1],
        ]),
        marker: kMarkerSof0,
        offset: 0,
      );
      expect(f.width, 16);
      expect(f.height, 16);
      expect(f.maxHorizontalFactor, 2);
      expect(f.maxVerticalFactor, 2);
      expect(f.mcusPerLine, 1, reason: '16 像素正好一个 16×16 的 MCU');
      expect(f.mcusPerColumn, 1);
      expect(f.mcuWidth, 16);
      expect(f.mcuHeight, 16);
      expect(f.samplingLabel, '4:2:0');
      expect(f.isProgressive, isFalse);

      final JpegComponent y = f.components[0];
      expect(y.sampleWidth, 16);
      expect(y.blocksPerLine, 2);
      expect(y.blocksPerLineForMcu, 2, reason: '对齐时两套块数应当相同');
      expect(y.blocksPerMcu, 4);

      final JpegComponent cb = f.components[1];
      expect(cb.sampleWidth, 8, reason: '色度分辨率是亮度的一半');
      expect(cb.sampleHeight, 8);
      expect(cb.blocksPerLine, 1);
      expect(cb.blocksPerMcu, 1);
    });

    test('不对齐时 blocksPerLine 与 blocksPerLineForMcu 分道扬镳', () {
      // 17×17 的 4:2:0：真实只需要 3×3 个 Y 块，但 MCU 要补到 4×4。
      // 混用这两个数就是边缘越界或边缘发灰的根源。
      final JpegFrame f = parseSof(
        sofPayload(17, 17, <List<int>>[
          <int>[1, 2, 2, 0],
          <int>[2, 1, 1, 1],
          <int>[3, 1, 1, 1],
        ]),
        marker: kMarkerSof0,
        offset: 0,
      );
      expect(f.mcusPerLine, 2, reason: '17 像素跨两个 16 宽的 MCU');
      expect(f.mcusPerColumn, 2);

      final JpegComponent y = f.components[0];
      expect(y.sampleWidth, 17);
      expect(y.blocksPerLine, 3, reason: 'ceil(17/8) = 3');
      expect(y.blocksPerLineForMcu, 4, reason: '2 个 MCU × 每 MCU 2 块 = 4');
      expect(y.blocksPerColumn, 3);
      expect(y.blocksPerColumnForMcu, 4);

      final JpegComponent cb = f.components[1];
      expect(cb.sampleWidth, 9, reason: 'ceil(17×1/2) = 9，不是 8');
      expect(cb.blocksPerLine, 2);
      expect(cb.blocksPerLineForMcu, 2);
    });

    test('缓冲区按补齐后的块数分配，够写下边缘的 dummy block', () {
      final JpegFrame f = parseSof(
        sofPayload(17, 17, <List<int>>[<int>[1, 1, 1, 0]]),
        marker: kMarkerSof0,
        offset: 0,
      );
      final JpegComponent y = f.components[0];
      expect(y.blocksPerLineForMcu, 3);
      expect(y.coefficients.length, 3 * 3 * kBlockSize);
      expect(y.blockOffset(0, 0), 0);
      expect(y.blockOffset(0, 1), kBlockSize);
      expect(y.blockOffset(1, 0), 3 * kBlockSize, reason: '跨行要按补齐宽度走');
      expect(y.blockOffset(2, 2) + kBlockSize, y.coefficients.length);
    });

    test('系数缓冲区是 Int16List，整帧留着给渐进细化用', () {
      final JpegFrame f = parseSof(
        sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]]),
        marker: kMarkerSof2,
        offset: 0,
      );
      expect(f.isProgressive, isTrue);
      expect(f.components[0].coefficients, isA<Int16List>());
      expect(f.components[0].coefficients.every((int c) => c == 0), isTrue,
          reason: '初始应当全零：渐进模式下未被扫描覆盖的系数就该是 0');
    });

    test('采样标签认得常见几种，也认得约完公因子的写法', () {
      String label(List<List<int>> comps) => parseSof(
            sofPayload(64, 64, comps),
            marker: kMarkerSof0,
            offset: 0,
          ).samplingLabel;

      expect(
          label(<List<int>>[
            <int>[1, 1, 1, 0],
            <int>[2, 1, 1, 1],
            <int>[3, 1, 1, 1],
          ]),
          '4:4:4');
      expect(
          label(<List<int>>[
            <int>[1, 2, 1, 0],
            <int>[2, 1, 1, 1],
            <int>[3, 1, 1, 1],
          ]),
          '4:2:2');
      expect(
          label(<List<int>>[
            <int>[1, 4, 1, 0],
            <int>[2, 1, 1, 1],
            <int>[3, 1, 1, 1],
          ]),
          '4:1:1');
      expect(
          label(<List<int>>[
            <int>[1, 4, 4, 0],
            <int>[2, 2, 2, 1],
            <int>[3, 2, 2, 1],
          ]),
          '4:2:0',
          reason: '采样因子是比例，约掉公因子 2 就是 4:2:0');
      expect(label(<List<int>>[<int>[1, 1, 1, 0]]), '单分量（灰度）');
      expect(
          label(<List<int>>[
            <int>[1, 2, 2, 0],
            <int>[2, 2, 1, 1],
            <int>[3, 1, 1, 1],
          ]),
          '2x2 2x1 1x1',
          reason: '认不出的组合照实报原始因子');
    });

    test('放大同一组比例只改 MCU 尺寸，不改分量的真实尺寸', () {
      List<int> geometry(List<List<int>> comps) {
        final JpegFrame f =
            parseSof(sofPayload(32, 32, comps), marker: kMarkerSof0, offset: 0);
        return <int>[
          f.components[1].sampleWidth,
          f.components[1].sampleHeight,
          f.mcuWidth,
        ];
      }

      expect(
          geometry(<List<int>>[
            <int>[1, 2, 2, 0],
            <int>[2, 1, 1, 1],
            <int>[3, 1, 1, 1],
          ]),
          <int>[16, 16, 16]);
      expect(
          geometry(<List<int>>[
            <int>[1, 4, 4, 0],
            <int>[2, 2, 2, 1],
            <int>[3, 2, 2, 1],
          ]),
          <int>[16, 16, 32],
          reason: '色度尺寸不变，MCU 从 16 涨到 32');
    });

    test('按标识符找分量，不按下标', () {
      // 有编码器从 0 编号，有的从 1，还有用 ASCII 'R''G''B' 的。
      final JpegFrame f = parseSof(
        sofPayload(8, 8, <List<int>>[
          <int>[0x52, 1, 1, 0],
          <int>[0x47, 1, 1, 0],
          <int>[0x42, 1, 1, 0],
        ]),
        marker: kMarkerSof0,
        offset: 0,
      );
      expect(f.componentById(0x47), same(f.components[1]));
      expect(f.componentById(1), isNull);
    });

    test('SOF1 与 SOF2 的段结构和 SOF0 一样', () {
      for (final int m in <int>[kMarkerSof0, kMarkerSof1, kMarkerSof2]) {
        final JpegFrame f = parseSof(
          sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]]),
          marker: m,
          offset: 0,
        );
        expect(f.marker, m);
        expect(f.width, 8);
      }
    });

    test('无损 / 算术编码 / 层次模式要明确报不支持', () {
      // 段结构一样，熵编码完全不同 —— 硬读只会解出噪声。
      for (final int m in <int>[0xC3, 0xC5, 0xC9, 0xCD]) {
        expect(
          () => parseSof(
            sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]]),
            marker: m,
            offset: 0,
          ),
          throwsA(isA<UnsupportedImageFeature>()),
          reason: '0x${m.toRadixString(16)}',
        );
      }
    });

    test('非 SOF marker 属于内部错误', () {
      expect(
        () => parseSof(
          sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]]),
          marker: kMarkerDht,
          offset: 0,
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('12 位精度要明确报不支持，不能静默截断', () {
      expect(
        () => parseSof(
          sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]], precision: 12),
          marker: kMarkerSof0,
          offset: 0,
        ),
        throwsA(isA<UnsupportedImageFeature>()),
      );
    });

    test('宽高为 0 要报错', () {
      expect(
        () => parseSof(sofPayload(0, 8, <List<int>>[<int>[1, 1, 1, 0]]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
      // 高度 0 是规范允许的（由 DNL 补），但缓冲区要提前分配，只能报不支持。
      expect(
        () => parseSof(sofPayload(8, 0, <List<int>>[<int>[1, 1, 1, 0]]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<UnsupportedImageFeature>()),
      );
    });

    test('分量个数越界、标识符重复要报错', () {
      expect(
        () => parseSof(sofPayload(8, 8, <List<int>>[]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
      // 重复的 Ci 让 SOS 点名变成二义的，扫描会写到错误的分量上。
      expect(
        () => parseSof(
            sofPayload(8, 8, <List<int>>[
              <int>[1, 1, 1, 0],
              <int>[1, 1, 1, 0],
            ]),
            marker: kMarkerSof0,
            offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('采样因子为 0 或超过 4、量化表编号越界要报错', () {
      expect(
        () => parseSof(sofPayload(8, 8, <List<int>>[<int>[1, 0, 1, 0]]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
        reason: '因子 0 会让 ceilDiv 除零',
      );
      expect(
        () => parseSof(sofPayload(8, 8, <List<int>>[<int>[1, 5, 1, 0]]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
      expect(
        () => parseSof(sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 4]]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('段长与分量个数不符要报错', () {
      final Uint8List good =
          sofPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]]);
      // 声明 2 个分量却只跟了 1 个描述。
      final Uint8List lying = Uint8List.fromList(good)..[5] = 2;
      expect(
        () => parseSof(lying, marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
      // 多出一个尾字节。
      expect(
        () => parseSof(Uint8List.fromList(<int>[...good, 0x00]),
            marker: kMarkerSof0, offset: 0),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('toString 报得出形状，供调试和信息面板用', () {
      final JpegFrame f = parseSof(
        sofPayload(640, 480, <List<int>>[
          <int>[1, 2, 2, 0],
          <int>[2, 1, 1, 1],
          <int>[3, 1, 1, 1],
        ]),
        marker: kMarkerSof0,
        offset: 0,
      );
      expect(f.toString(), contains('640x480'));
      expect(f.toString(), contains('4:2:0'));
      expect(f.components[0].toString(), contains('2x2'));
    });
  });
}
