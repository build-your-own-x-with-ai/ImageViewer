import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_frame.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_huffman.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_idct.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_markers.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_scan.dart';
import 'package:image_viewer/src/core/errors.dart';

import '../support/jpeg_builders.dart';

/// DC 表：覆盖 0..11 全部幅值类别，等长 4 位。
final HuffmanSpec dcSpec = HuffmanSpec(<int, int>{
  for (int c = 0; c <= 11; c++) c: 4,
});

/// AC 表：EOB、ZRL、EOB1/EOB2，以及 size 1..4 的全部 run。
///
/// 故意排了 2/4/5/6/7/9 六种码长 —— 等长表会让「码字按码长递增分配」退化成
/// 「按顺序编号」，测不出换码长时那一次左移。
final HuffmanSpec acSpec = HuffmanSpec(<int, int>{
  0x00: 2, // EOB
  0xF0: 4, // ZRL
  for (int n = 1; n <= 2; n++) (n << 4): 5, // EOB1 / EOB2
  for (int r = 0; r <= 15; r++) (r << 4) | 1: 6,
  for (int r = 0; r <= 15; r++) (r << 4) | 2: 7,
  for (int r = 0; r <= 15; r++) (r << 4) | 3: 9,
  for (int r = 0; r <= 15; r++) (r << 4) | 4: 9,
});

List<JpegHuffmanTable?> dcTables() => <JpegHuffmanTable?>[
      parseDht(dcSpec.dhtPayload(tableClass: 0, id: 0), offset: 0).first,
      null,
      null,
      null,
    ];

List<JpegHuffmanTable?> acTables() => <JpegHuffmanTable?>[
      parseDht(acSpec.dhtPayload(tableClass: 1, id: 0), offset: 0).first,
      null,
      null,
      null,
    ];

/// 造一个帧。分量按 `[id, h, v, tq]` 给。
JpegFrame buildFrame(
  int width,
  int height,
  List<List<int>> comps, {
  int marker = kMarkerSof0,
}) =>
    parseSof(
      sofSegmentPayload(width, height, comps),
      marker: marker,
      offset: 0,
    );

/// 解一趟扫描，结果落在 [frame] 的系数缓冲里。分量按 `[id, td, ta]` 给。
///
/// 和 [buildFrame] 分开是故意的：渐进的细化趟要往**同一个** frame 里叠第二趟，
/// 合成一个 helper 就没法表达了。
int runScan(
  JpegFrame frame,
  Uint8List entropy,
  List<List<int>> comps, {
  int ss = 0,
  int se = 63,
  int ah = 0,
  int al = 0,
  int restartInterval = 0,
}) {
  final JpegScanHeader scan = parseSos(
    sosSegmentPayload(comps, ss: ss, se: se, ah: ah, al: al),
    frame: frame,
    offset: 0,
  );
  return decodeScan(
    entropy,
    start: 0,
    frame: frame,
    scan: scan,
    dcTables: dcTables(),
    acTables: acTables(),
    restartInterval: restartInterval,
  );
}

/// 稀疏写法造一个 zigzag 序的块：`{0: 42, 3: -2}`。
List<int> zigzagBlock(Map<int, int> coefficients) {
  final List<int> block = List<int>.filled(kBlockSize, 0);
  for (final MapEntry<int, int> e in coefficients.entries) {
    block[e.key] = e.value;
  }
  return block;
}

/// 把若干个块编成一段基线熵数据，DC 预测在块之间连着传。
Uint8List encodeBlocks(List<List<int>> blocks) {
  final JpegBitWriter w = JpegBitWriter();
  int prediction = 0;
  for (final List<int> block in blocks) {
    prediction = encodeBaselineBlock(
      w,
      block,
      dc: dcSpec,
      ac: acSpec,
      prediction: prediction,
    );
  }
  w.alignToByte();
  return w.takeBytes();
}

/// 断言某个 SOS 载荷会被拒。
void expectSosRejects(JpegFrame frame, Uint8List payload) {
  expect(
    () => parseSos(payload, frame: frame, offset: 0),
    throwsA(isA<ImageDecodeException>()),
  );
}

void main() {
  group('JPEG SOS 解析', () {
    final JpegFrame baseline = buildFrame(16, 16, <List<int>>[
      <int>[1, 2, 2, 0],
      <int>[2, 1, 1, 1],
      <int>[3, 1, 1, 1],
    ]);
    final JpegFrame progressive = buildFrame(
      16,
      16,
      <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 1],
        <int>[3, 1, 1, 1],
      ],
      marker: kMarkerSof2,
    );

    test('单分量扫描不算交错', () {
      final JpegScanHeader scan = parseSos(
        sosSegmentPayload(<List<int>>[
          <int>[1, 0, 0],
        ]),
        frame: baseline,
        offset: 0,
      );
      expect(scan.components, hasLength(1));
      expect(scan.isInterleaved, isFalse);
      expect(scan.isDcScan, isTrue);
      expect(scan.isRefinement, isFalse);
      expect(scan.components[0].component.id, 1);
    });

    test('三分量扫描是交错的，Td/Ta 各自拆出来', () {
      final JpegScanHeader scan = parseSos(
        sosSegmentPayload(<List<int>>[
          <int>[1, 0, 0],
          <int>[2, 1, 1],
          <int>[3, 1, 2],
        ]),
        frame: baseline,
        offset: 0,
      );
      expect(scan.isInterleaved, isTrue);
      expect(scan.components[1].dcTableId, 1);
      expect(scan.components[2].acTableId, 2);
    });
    test('渐进 AC 细化趟带出谱选择和逐次逼近', () {
      final JpegScanHeader scan = parseSos(
        sosSegmentPayload(
          <List<int>>[
            <int>[1, 0, 0],
          ],
          ss: 1,
          se: 5,
          ah: 2,
          al: 1,
        ),
        frame: progressive,
        offset: 0,
      );
      expect(scan.spectralStart, 1);
      expect(scan.spectralEnd, 5);
      expect(scan.approxHigh, 2);
      expect(scan.approxLow, 1);
      expect(scan.isDcScan, isFalse);
      expect(scan.isRefinement, isTrue);
      expect(scan.toString(), isNotEmpty);
    });

    test('点名不存在的分量报错', () {
      expectSosRejects(
        baseline,
        sosSegmentPayload(<List<int>>[
          <int>[9, 0, 0],
        ]),
      );
    });

    test('同一个分量出现两次报错', () {
      expectSosRejects(
        baseline,
        sosSegmentPayload(<List<int>>[
          <int>[1, 0, 0],
          <int>[1, 0, 0],
        ]),
      );
    });

    test('霍夫曼表号越界报错', () {
      expectSosRejects(
        baseline,
        sosSegmentPayload(<List<int>>[
          <int>[1, 4, 0],
        ]),
      );
    });

    test('顺序模式的谱选择必须是 0..63', () {
      expectSosRejects(
        baseline,
        sosSegmentPayload(
          <List<int>>[
            <int>[1, 0, 0],
          ],
          ss: 1,
        ),
      );
    });

    test('顺序模式不能用逐次逼近', () {
      expectSosRejects(
        baseline,
        sosSegmentPayload(
          <List<int>>[
            <int>[1, 0, 0],
          ],
          al: 1,
        ),
      );
    });

    test('渐进里 DC 不能和 AC 合并一趟', () {
      expectSosRejects(
        progressive,
        sosSegmentPayload(<List<int>>[
          <int>[1, 0, 0],
        ]),
      );
    });

    test('渐进 AC 扫描只能单分量', () {
      expectSosRejects(
        progressive,
        sosSegmentPayload(
          <List<int>>[
            <int>[1, 0, 0],
            <int>[2, 0, 0],
            <int>[3, 0, 0],
          ],
          ss: 1,
          se: 5,
        ),
      );
    });

    test('细化趟的 Ah 必须等于 Al+1', () {
      expectSosRejects(
        progressive,
        sosSegmentPayload(
          <List<int>>[
            <int>[1, 0, 0],
          ],
          ss: 1,
          se: 5,
          ah: 3,
          al: 1,
        ),
      );
    });

    test('Ss > Se 报错', () {
      expectSosRejects(
        progressive,
        sosSegmentPayload(
          <List<int>>[
            <int>[1, 0, 0],
          ],
          ss: 5,
          se: 2,
        ),
      );
    });

    test('段长与分量个数不符报错', () {
      final Uint8List payload = sosSegmentPayload(<List<int>>[
        <int>[1, 0, 0],
      ]);
      expectSosRejects(baseline, Uint8List.fromList(<int>[...payload, 0]));
    });

    test('分量个数为 0 报错', () {
      expectSosRejects(baseline, Uint8List.fromList(<int>[0, 0, 63, 0]));
    });

    test('空段报错', () {
      expectSosRejects(baseline, Uint8List(0));
    });
  });

  group('JPEG 基线熵解码', () {
    test('单块只有 DC', () {
      final JpegFrame frame = buildFrame(8, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      final Uint8List entropy = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 42}),
      ]);
      runScan(frame, entropy, <List<int>>[
        <int>[1, 0, 0],
      ]);
      expect(frame.components[0].coefficients[0], 42);
    });

    test('DC 是差分的：第二个块的值要加上第一个', () {
      final JpegFrame frame = buildFrame(16, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      final JpegComponent y = frame.components[0];
      expect(y.blocksPerLine, 2);

      final Uint8List entropy = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 10}),
        zigzagBlock(<int, int>{0: 30}),
      ]);
      runScan(frame, entropy, <List<int>>[
        <int>[1, 0, 0],
      ]);
      expect(y.coefficients[y.blockOffset(0, 0)], 10);
      expect(y.coefficients[y.blockOffset(0, 1)], 30);
      expect(y.blockOffset(0, 1), kBlockSize);
    });
    test('AC 游程与 ZRL', () {
      final JpegFrame frame = buildFrame(8, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      // k=3 到 k=20 之间正好 16 个零，编码时会走一次 ZRL。
      final Uint8List entropy = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 5, 3: -2, 20: 1}),
      ]);
      runScan(frame, entropy, <List<int>>[
        <int>[1, 0, 0],
      ]);
      final Int16List c = frame.components[0].coefficients;
      expect(c[0], 5);
      expect(c[3], -2);
      expect(c[20], 1);
      expect(c[1], 0);
      expect(c[19], 0);
      expect(c[21], 0);
    });

    test('负系数经 EXTEND 原样还原', () {
      final JpegFrame frame = buildFrame(8, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      final Uint8List entropy = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: -100, 1: -7, 2: 8, 5: -1}),
      ]);
      runScan(frame, entropy, <List<int>>[
        <int>[1, 0, 0],
      ]);
      final Int16List c = frame.components[0].coefficients;
      expect(c[0], -100);
      expect(c[1], -7);
      expect(c[2], 8);
      expect(c[5], -1);
    });
    test('4:2:0 交错扫描：一个 MCU 里是 Y0 Y1 Y2 Y3 Cb Cr', () {
      final JpegFrame frame = buildFrame(16, 16, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      expect(frame.mcusPerLine, 1);
      expect(frame.mcusPerColumn, 1);

      // DC 预测每个分量各自一条链，所以 Cb / Cr 都从 0 起算。
      final JpegBitWriter w = JpegBitWriter();
      int prediction = 0;
      for (final int dc in <int>[11, 22, 33, 44]) {
        prediction = encodeBaselineBlock(
          w,
          zigzagBlock(<int, int>{0: dc}),
          dc: dcSpec,
          ac: acSpec,
          prediction: prediction,
        );
      }
      for (final int dc in <int>[55, 66]) {
        encodeBaselineBlock(
          w,
          zigzagBlock(<int, int>{0: dc}),
          dc: dcSpec,
          ac: acSpec,
          prediction: 0,
        );
      }
      w.alignToByte();

      runScan(frame, w.takeBytes(), <List<int>>[
        <int>[1, 0, 0],
        <int>[2, 0, 0],
        <int>[3, 0, 0],
      ]);

      final JpegComponent y = frame.components[0];
      expect(y.coefficients[y.blockOffset(0, 0)], 11);
      expect(y.coefficients[y.blockOffset(0, 1)], 22);
      expect(y.coefficients[y.blockOffset(1, 0)], 33);
      expect(y.coefficients[y.blockOffset(1, 1)], 44);
      expect(frame.components[1].coefficients[0], 55);
      expect(frame.components[2].coefficients[0], 66);
    });
    test('单分量扫描走真实块网格，不碰补齐出来的列', () {
      final JpegFrame frame = buildFrame(17, 17, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent y = frame.components[0];
      expect(y.blocksPerLine, 3);
      expect(y.blocksPerLineForMcu, 4);
      expect(y.blocksPerColumn, 3);

      final List<List<int>> blocks = <List<int>>[];
      for (int i = 1; i <= 9; i++) {
        blocks.add(zigzagBlock(<int, int>{0: i}));
      }
      runScan(frame, encodeBlocks(blocks), <List<int>>[
        <int>[1, 0, 0],
      ]);

      for (int row = 0; row < 3; row++) {
        for (int col = 0; col < 3; col++) {
          expect(y.coefficients[y.blockOffset(row, col)], row * 3 + col + 1);
        }
        // 第 4 列只为凑 MCU 而存在，单分量扫描不该碰它。
        expect(y.coefficients[y.blockOffset(row, 3)], 0);
      }
    });

    test('重启间隔把 DC 预测清零', () {
      final JpegFrame frame = buildFrame(32, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      final JpegComponent y = frame.components[0];
      expect(y.blocksPerLine, 4);

      // 间隔 2 → RST0 落在块 1 和块 2 之间，两段各自从预测值 0 起算。
      final Uint8List a = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 10}),
        zigzagBlock(<int, int>{0: 20}),
      ]);
      final Uint8List b = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 30}),
        zigzagBlock(<int, int>{0: 35}),
      ]);
      final Uint8List entropy = Uint8List.fromList(<int>[
        ...a,
        0xFF,
        kMarkerRst0,
        ...b,
      ]);

      runScan(
        frame,
        entropy,
        <List<int>>[
          <int>[1, 0, 0],
        ],
        restartInterval: 2,
      );

      // 没清零的话块 2 会解成 20 + 30 = 50。
      expect(y.coefficients[y.blockOffset(0, 0)], 10);
      expect(y.coefficients[y.blockOffset(0, 1)], 20);
      expect(y.coefficients[y.blockOffset(0, 2)], 30);
      expect(y.coefficients[y.blockOffset(0, 3)], 35);
    });

    test('位流截断只是补零位，不抛异常', () {
      final JpegFrame frame = buildFrame(32, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      final JpegComponent y = frame.components[0];
      final Uint8List full = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 10}),
        zigzagBlock(<int, int>{0: 20}),
        zigzagBlock(<int, int>{0: 30}),
        zigzagBlock(<int, int>{0: 40}),
      ]);
      // 只留 1 个字节：块 0 的 DC 正好读完（4 位码字 + 4 位幅值），
      // 之后一律靠补零位维持。
      final Uint8List truncated = Uint8List.sublistView(full, 0, 1);

      runScan(frame, truncated, <List<int>>[
        <int>[1, 0, 0],
      ]);

      expect(y.coefficients[y.blockOffset(0, 0)], 10);
      expect(y.coefficients[y.blockOffset(0, 1)], 0);
      expect(y.coefficients[y.blockOffset(0, 3)], 0);
    });

    test('引用未定义的霍夫曼表报错', () {
      final JpegFrame frame = buildFrame(8, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      final Uint8List entropy = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 1}),
      ]);
      // 表 2 是空位 —— parseSos 放它过，解扫描时才发现。
      expect(
        () => runScan(frame, entropy, <List<int>>[
          <int>[1, 2, 0],
        ]),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('数据里的 0xFF 被填充成 FF 00，解码时吞掉填充物', () {
      final JpegFrame frame = buildFrame(8, 8, <List<int>>[
        <int>[1, 1, 1, 0],
      ]);
      // 挑的这组系数会让位流里正好凑出一个 0xFF 字节：
      // DC 类别 11（码字 1011）+ 11 位全 1 的幅值 → 0xBF，余 7 个 1 位；
      // 接上 AC 符号 0x02 的 7 位码字 1010000，第 2 个字节就是 0xFF。
      final Uint8List entropy = encodeBlocks(<List<int>>[
        zigzagBlock(<int, int>{0: 2047, 1: 3}),
      ]);
      expect(entropy, <int>[0xBF, 0xFF, 0x00, 0x43, 0x3F]);

      runScan(frame, entropy, <List<int>>[
        <int>[1, 0, 0],
      ]);
      final Int16List c = frame.components[0].coefficients;
      expect(c[0], 2047);
      expect(c[1], 3);
    });
  });

  group('JPEG 渐进熵解码', () {
    test('DC 首趟落在 Al 位平面上，细化趟只补一个裸位', () {
      final JpegFrame frame = buildFrame(
        8,
        8,
        <List<int>>[
          <int>[1, 1, 1, 0],
        ],
        marker: kMarkerSof2,
      );
      final Int16List c = frame.components[0].coefficients;

      // 首趟：差分 21，Al=1，所以系数是 21 << 1。
      final JpegBitWriter w1 = JpegBitWriter();
      dcSpec.encode(w1, magnitudeCategory(21));
      writeMagnitude(w1, 21, magnitudeCategory(21));
      w1.alignToByte();
      runScan(
        frame,
        w1.takeBytes(),
        <List<int>>[
          <int>[1, 0, 0],
        ],
        se: 0,
        al: 1,
      );
      expect(c[0], 42);

      // 细化趟：一个裸位，不过霍夫曼表。
      final JpegBitWriter w2 = JpegBitWriter();
      w2.writeBit(1);
      w2.alignToByte();
      runScan(
        frame,
        w2.takeBytes(),
        <List<int>>[
          <int>[1, 0, 0],
        ],
        se: 0,
        ah: 1,
      );
      expect(c[0], 43);
    });
    test('AC 首趟的 EOB 游程跨块生效', () {
      final JpegFrame frame = buildFrame(
        24,
        8,
        <List<int>>[
          <int>[1, 1, 1, 0],
        ],
        marker: kMarkerSof2,
      );
      final JpegComponent y = frame.components[0];
      expect(y.blocksPerLine, 3);

      final JpegBitWriter w = JpegBitWriter();
      // 块 0：k=1 写 3，然后 EOB1（附加位 0），游程正好覆盖块 1。
      acSpec.encode(w, 0x02);
      writeMagnitude(w, 3, 2);
      acSpec.encode(w, 0x10);
      w.writeBits(0, 1);
      // 块 1 一位都不该读。
      // 块 2：k=1 写 -2，正常 EOB 收尾。
      acSpec.encode(w, 0x02);
      writeMagnitude(w, -2, 2);
      acSpec.encode(w, 0x00);
      w.alignToByte();

      runScan(
        frame,
        w.takeBytes(),
        <List<int>>[
          <int>[1, 0, 0],
        ],
        ss: 1,
        se: 5,
      );

      expect(y.coefficients[y.blockOffset(0, 0) + 1], 3);
      expect(y.coefficients[y.blockOffset(0, 1) + 1], 0);
      expect(y.coefficients[y.blockOffset(0, 2) + 1], -2);
    });

    test('AC 细化趟：校正位和新非零系数混在同一条位流里', () {
      final JpegFrame frame = buildFrame(
        8,
        8,
        <List<int>>[
          <int>[1, 1, 1, 0],
        ],
        marker: kMarkerSof2,
      );
      final Int16List c = frame.components[0].coefficients;

      // 首趟（Al=1）：k=1 上写 1，落到位平面 1 → 系数 2。
      final JpegBitWriter w1 = JpegBitWriter();
      acSpec.encode(w1, 0x01);
      writeMagnitude(w1, 1, 1);
      acSpec.encode(w1, 0x00);
      runScan(
        frame,
        w1.takeBytes(),
        <List<int>>[
          <int>[1, 0, 0],
        ],
        ss: 1,
        se: 2,
        al: 1,
      );
      expect(c[1], 2);
      expect(c[2], 0);

      // 细化趟（Ah=1, Al=0）。三个位依次是：
      //   符号 0x01     —— 游程 0、size 1，宣告有一个新非零系数
      //   值位 0        —— 新系数取 -1（不是 +1，好把读序钉死）
      //   校正位 1      —— 给 k=1 上已有的 2 补一格 → 3
      final JpegBitWriter w2 = JpegBitWriter();
      acSpec.encode(w2, 0x01);
      w2.writeBit(0);
      w2.writeBit(1);
      runScan(
        frame,
        w2.takeBytes(),
        <List<int>>[
          <int>[1, 0, 0],
        ],
        ss: 1,
        se: 2,
        ah: 1,
      );
      expect(c[1], 3);
      expect(c[2], -1);
    });
  });

  group('JPEG 分量渲染', () {
    test('平面按补齐后的块数铺开，DC-only 块渲染成一片平色', () {
      final JpegFrame frame = buildFrame(17, 17, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent y = frame.components[0];
      final QuantizationTable quant =
          parseDqt(dqtAllOnes(fill: 8), offset: 0).first;

      // 只给 (0,0) 块一个 DC：8 × 量化值 8 = 64，IDCT 后是 64/8 + 128 = 136。
      y.coefficients[y.blockOffset(0, 0)] = 8;

      final Uint8List plane = renderComponent(y, quant, const IdctNaive());
      final int stride = y.blocksPerLineForMcu * kBlockDim;
      expect(stride, 32);
      expect(plane, hasLength(stride * y.blocksPerColumnForMcu * kBlockDim));

      // 第一个块整片 136。
      for (int row = 0; row < kBlockDim; row++) {
        for (int col = 0; col < kBlockDim; col++) {
          expect(plane[row * stride + col], 136);
        }
      }
      // 相邻块全零 → 只剩电平搬移的 128。
      expect(plane[kBlockDim], 128);
      // 补齐出来的第 4 列同样是 128，不是越界也不是垃圾。
      expect(plane[3 * kBlockDim], 128);
      expect(plane[(stride - 1)], 128);
    });
  });
}
