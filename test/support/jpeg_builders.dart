/// 手搓 JPEG 位流的工具：一个够用的最小编码器。
///
/// 为什么测试里要写编码器：熵解码没法用「几个手写字节」测明白 —— 一个块最少
/// 也是几十位，手算码字既慢又容易把测试本身写错。有了编码器就能**往返**：
/// 已知系数 → 编码 → 解码 → 比对。位流上任何一位错位都会在比对里炸出来。
///
/// 编码器和解码器共享「规范码字分配」这个算法，理论上有「一起错」的风险。
/// 这个风险已经被堵住了：解码器那侧的码字分配是拿手算结果单独钉过的
/// （单字节 `0x18` 应当产出 `00→0xA, 01→0xB, 100→0xC`），所以这里按同一套
/// 规则生成码字是安全的。
library;

import 'dart:typed_data';

/// 高位在前的位写入器，带 JPEG 的字节填充。
class JpegBitWriter {
  final BytesBuilder _out = BytesBuilder();
  int _buffer = 0;
  int _count = 0;

  /// 写 [length] 位，取 [value] 的低 [length] 位，高位先出。
  void writeBits(int value, int length) {
    for (int i = length - 1; i >= 0; i--) {
      writeBit((value >> i) & 1);
    }
  }

  void writeBit(int bit) {
    _buffer = (_buffer << 1) | (bit & 1);
    _count++;
    if (_count == 8) {
      _flushByte();
    }
  }

  void _flushByte() {
    final int b = _buffer & 0xFF;
    _out.addByte(b);
    // 数据里真出现 0xFF 时必须跟一个 0x00，否则解码器会当成 marker 前缀。
    if (b == 0xFF) {
      _out.addByte(0x00);
    }
    _buffer = 0;
    _count = 0;
  }

  /// 补齐到字节边界，用 1 位填充（规范要求的填充值）。
  ///
  /// 用 0 填充在多数情况下也能解出来，但如果填充位刚好凑成一个合法码字，
  /// 解码器会多解出一个块。填 1 是安全的：全 1 的 16 位码字是保留值。
  void alignToByte() {
    while (_count != 0) {
      writeBit(1);
    }
  }

  /// 取出结果，自动补齐到字节边界。
  Uint8List takeBytes() {
    alignToByte();
    return _out.toBytes();
  }
}

/// 一张霍夫曼表：BITS + HUFFVAL，以及编码用的「符号 → 码字」映射。
class HuffmanSpec {
  HuffmanSpec._(this.bits, this.values, this._codes, this._lengths);

  /// 从「符号 → 码长」建表，码字按规范的规则分配（码长递增、同长递增）。
  ///
  /// 只指定码长而不指定码字，是因为码字是**推导出来**的 —— 这也正是 JPEG
  /// 只在文件里存 BITS/HUFFVAL 而不存码字的原因。
  factory HuffmanSpec(Map<int, int> symbolToLength) {
    final List<int> bits = List<int>.filled(16, 0);
    final List<int> values = <int>[];
    final Map<int, int> codes = <int, int>{};
    final Map<int, int> lengths = <int, int>{};

    // 先按码长分组，同组内按符号值升序 —— 和解码器的分配顺序一致。
    for (int length = 1; length <= 16; length++) {
      final List<int> group = symbolToLength.entries
          .where((MapEntry<int, int> e) => e.value == length)
          .map((MapEntry<int, int> e) => e.key)
          .toList()
        ..sort();
      bits[length - 1] = group.length;
      values.addAll(group);
    }

    int code = 0;
    int index = 0;
    for (int length = 1; length <= 16; length++) {
      for (int i = 0; i < bits[length - 1]; i++) {
        final int symbol = values[index++];
        codes[symbol] = code;
        lengths[symbol] = length;
        code++;
      }
      code <<= 1; // 换到下一个码长：所有码字左移一位
    }
    return HuffmanSpec._(bits, values, codes, lengths);
  }

  final List<int> bits;
  final List<int> values;
  final Map<int, int> _codes;
  final Map<int, int> _lengths;

  /// 把一个符号写进位流。
  void encode(JpegBitWriter w, int symbol) {
    final int? code = _codes[symbol];
    if (code == null) {
      throw ArgumentError('符号 $symbol 不在这张表里，测试自己写错了');
    }
    w.writeBits(code, _lengths[symbol]!);
  }

  /// 这张表的 DHT 段载荷：`[Tc|Th]` + BITS(16) + HUFFVAL。
  Uint8List dhtPayload({required int tableClass, required int id}) =>
      Uint8List.fromList(<int>[(tableClass << 4) | id, ...bits, ...values]);
}

/// 幅值类别：表示 [value] 需要几位幅值位。
int magnitudeCategory(int value) {
  int v = value.abs();
  int category = 0;
  while (v > 0) {
    category++;
    v >>= 1;
  }
  return category;
}

/// 写一个系数的幅值位（EXTEND 的逆过程）。
///
/// 负数存的是 `value - 1` 的低 category 位 —— 于是同一类别里负数落在前半段、
/// 正数落在后半段，解码器只看最高位就能分辨。
void writeMagnitude(JpegBitWriter w, int value, int category) {
  if (category == 0) {
    return;
  }
  final int encoded = value >= 0 ? value : value - 1;
  w.writeBits(encoded & ((1 << category) - 1), category);
}

/// 编码一个基线块（zigzag 序的 64 个系数），返回新的 DC 预测值。
int encodeBaselineBlock(
  JpegBitWriter w,
  List<int> zigzag, {
  required HuffmanSpec dc,
  required HuffmanSpec ac,
  required int prediction,
}) {
  // DC 存的是差分 —— 这是重启间隔存在的理由，也是失步会毁掉一整条带子的原因。
  final int diff = zigzag[0] - prediction;
  final int dcCategory = magnitudeCategory(diff);
  dc.encode(w, dcCategory);
  writeMagnitude(w, diff, dcCategory);

  // AC：找出最后一个非零系数，它之后一律用 EOB 带过。
  int last = 0;
  for (int i = 1; i < 64; i++) {
    if (zigzag[i] != 0) {
      last = i;
    }
  }

  int run = 0;
  for (int k = 1; k <= last; k++) {
    if (zigzag[k] == 0) {
      run++;
      continue;
    }
    while (run >= 16) {
      ac.encode(w, 0xF0); // ZRL：一次跳 16 个零
      run -= 16;
    }
    final int category = magnitudeCategory(zigzag[k]);
    ac.encode(w, (run << 4) | category);
    writeMagnitude(w, zigzag[k], category);
    run = 0;
  }
  if (last < 63) {
    ac.encode(w, 0x00); // EOB
  }
  return zigzag[0];
}

/// 一个带长度字段的段：`FF marker len_hi len_lo payload`。
Uint8List segment(int marker, List<int> payload) {
  final int length = payload.length + 2;
  return Uint8List.fromList(<int>[
    0xFF,
    marker,
    (length >> 8) & 0xFF,
    length & 0xFF,
    ...payload,
  ]);
}

/// DQT 载荷：8 位精度的一张表，全部填同一个值。
Uint8List dqtAllOnes({int id = 0, int fill = 1}) =>
    Uint8List.fromList(<int>[id, ...List<int>.filled(64, fill)]);

/// SOF 载荷。分量按 `[id, h, v, tq]` 给。
Uint8List sofSegmentPayload(int width, int height, List<List<int>> comps) {
  final List<int> d = <int>[
    8,
    (height >> 8) & 0xFF, height & 0xFF,
    (width >> 8) & 0xFF, width & 0xFF,
    comps.length,
  ];
  for (final List<int> c in comps) {
    d.addAll(<int>[c[0], (c[1] << 4) | c[2], c[3]]);
  }
  return Uint8List.fromList(d);
}

int ceilDiv(int a, int b) => (a + b - 1) ~/ b;

/// 一个纯色分量：整个平面渲染成同一个样本值。
///
/// 端到端测试要的是「管线接对了没有」，不是「DCT 算得准不准」—— 后者已经被
/// IDCT、升采样、色彩转换各自的单测钉住了。纯色是最好的载荷：只需要 DC 一个
/// 系数，期望值能闭式算出来，而且**每个环节出错都会改变结果**（量化表错了
/// 亮度就偏，MCU 顺序错了分量就串，升采样错了边缘就花）。
class FlatComponent {
  const FlatComponent({
    required this.id,
    required this.sample,
    this.h = 1,
    this.v = 1,
    this.quantTable = 0,
  });

  /// 分量标识符 Ci。
  final int id;

  /// 期望渲染出来的样本值（0..255）。
  final int sample;

  /// 水平采样因子。
  final int h;

  /// 垂直采样因子。
  final int v;

  /// 量化表编号。
  final int quantTable;

  /// 让这个分量渲染成 [sample] 所需的 DC 系数（量化表全填 1 时）。
  ///
  /// 只有 DC 非零的块，IDCT 出来是常数 `DC/8`，再加 128 的电平位移。所以
  /// 反推是 `(sample - 128) * 8`，取值范围 -1024..1016，稳稳落在 ±2047 内。
  int get dcCoefficient => (sample - 128) * 8;
}

/// 纯色文件用的 DC 码表：类别 0..11 各 4 位。
final HuffmanSpec flatDcSpec = HuffmanSpec(<int, int>{
  for (int c = 0; c <= 11; c++) c: 4,
});

/// 纯色文件用的 AC 码表。
///
/// 只有 DC 的块其实只需要 EOB 一个符号，但单符号表是**不完备**的（一位码字
/// 只用掉一半的码空间）。JPEG 允许不完备的表，这里仍然凑第二个符号 ——
/// 端到端测试不该顺带去挑战解码器对不完备表的容忍度，那是 jpeg_huffman
/// 单测的事。
final HuffmanSpec flatAcSpec = HuffmanSpec(<int, int>{
  0x00: 1, // EOB
  0xF0: 1, // ZRL，用不到
});

/// 拼一个整张都是纯色的 JPEG 文件。
///
/// [sofMarker] 传 `0xC2` 会生成渐进文件：此时扫描是一趟 DC 首趟（Ss=Se=0、
/// Al=0），AC 全零所以不需要后续趟 —— 纯色图恰好只用 DC 一个系数。
Uint8List buildFlatJpeg({
  required int width,
  required int height,
  required List<FlatComponent> components,
  int sofMarker = 0xC0,
  int restartInterval = 0,
  List<Uint8List> extraSegments = const <Uint8List>[],
}) {
  final bool progressive = sofMarker == 0xC2;
  final BytesBuilder out = BytesBuilder();
  out.add(<int>[0xFF, 0xD8]); // SOI
  for (final Uint8List s in extraSegments) {
    out.add(s);
  }

  // 量化表全填 1，[FlatComponent.dcCoefficient] 的反推公式才成立。
  final List<int> quantIds =
      <int>{for (final FlatComponent c in components) c.quantTable}.toList()
        ..sort();
  for (final int id in quantIds) {
    out.add(segment(0xDB, dqtAllOnes(id: id)));
  }
  out.add(segment(0xC4, flatDcSpec.dhtPayload(tableClass: 0, id: 0)));
  out.add(segment(0xC4, flatAcSpec.dhtPayload(tableClass: 1, id: 0)));
  if (restartInterval > 0) {
    out.add(segment(0xDD, <int>[
      (restartInterval >> 8) & 0xFF,
      restartInterval & 0xFF,
    ]));
  }
  out.add(segment(
    sofMarker,
    sofSegmentPayload(width, height, <List<int>>[
      for (final FlatComponent c in components)
        <int>[c.id, c.h, c.v, c.quantTable],
    ]),
  ));
  out.add(segment(
    0xDA,
    sosSegmentPayload(
      <List<int>>[for (final FlatComponent c in components) <int>[c.id, 0, 0]],
      se: progressive ? 0 : 63,
    ),
  ));
  out.add(encodeFlatScan(
    width,
    height,
    components,
    restartInterval: restartInterval,
    dcOnly: progressive,
  ));
  out.add(<int>[0xFF, 0xD9]); // EOI
  return out.toBytes();
}

/// 编码纯色图的熵数据。
///
/// [dcOnly] 对应渐进 DC 首趟：只写 DC 符号和幅值，不写 AC 也不写 EOB。
///
/// 「单元」是重启间隔的计数单位：交错扫描里是一个 MCU，非交错扫描里是一个块。
/// 这个区分不是学术性的 —— 数错单位会让 RSTn 落在错误的位置，解码器随即失步。
Uint8List encodeFlatScan(
  int width,
  int height,
  List<FlatComponent> components, {
  int restartInterval = 0,
  bool dcOnly = false,
}) {
  int maxH = 1;
  int maxV = 1;
  for (final FlatComponent c in components) {
    if (c.h > maxH) {
      maxH = c.h;
    }
    if (c.v > maxV) {
      maxV = c.v;
    }
  }

  final int unitCount;
  // 一个单元里各个块归谁：交错扫描每个 MCU 都是同一套顺序。
  final List<int> blockOwners;
  if (components.length > 1) {
    unitCount = ceilDiv(width, maxH * 8) * ceilDiv(height, maxV * 8);
    blockOwners = <int>[
      for (int ci = 0; ci < components.length; ci++)
        for (int k = 0; k < components[ci].h * components[ci].v; k++) ci,
    ];
  } else {
    // 非交错走**真实**块网格，不补齐到 MCU。
    final FlatComponent c = components[0];
    unitCount = ceilDiv(ceilDiv(width * c.h, maxH), 8) *
        ceilDiv(ceilDiv(height * c.v, maxV), 8);
    blockOwners = const <int>[0];
  }

  final BytesBuilder out = BytesBuilder();
  final List<int> predictions = List<int>.filled(components.length, 0);
  JpegBitWriter w = JpegBitWriter();
  int nextRestart = 0;

  for (int unit = 0; unit < unitCount; unit++) {
    // 解码器的倒数是「每个单元前先减一」，所以 marker 落在第 R、2R… 个单元
    // **之前**，第一个单元之前没有。
    if (restartInterval > 0 && unit > 0 && unit % restartInterval == 0) {
      out.add(w.takeBytes());
      out.add(<int>[0xFF, 0xD0 + nextRestart]);
      nextRestart = (nextRestart + 1) & 7;
      w = JpegBitWriter();
      predictions.fillRange(0, predictions.length, 0);
    }
    for (final int ci in blockOwners) {
      final FlatComponent c = components[ci];
      if (dcOnly) {
        final int diff = c.dcCoefficient - predictions[ci];
        final int category = magnitudeCategory(diff);
        flatDcSpec.encode(w, category);
        writeMagnitude(w, diff, category);
        predictions[ci] = c.dcCoefficient;
      } else {
        final List<int> zigzag = List<int>.filled(64, 0);
        zigzag[0] = c.dcCoefficient;
        predictions[ci] = encodeBaselineBlock(
          w,
          zigzag,
          dc: flatDcSpec,
          ac: flatAcSpec,
          prediction: predictions[ci],
        );
      }
    }
  }
  out.add(w.takeBytes());
  return out.toBytes();
}

/// APP0 JFIF 段。有它在，三分量文件就被判定为 YCbCr。
Uint8List jfifSegment() => segment(0xE0, <int>[
      0x4A, 0x46, 0x49, 0x46, 0x00, // 'JFIF\0'
      1, 1, // 版本 1.1
      0, // 密度单位：无
      0, 1, 0, 1, // X/Y 密度
      0, 0, // 无缩略图
    ]);

/// APP14 Adobe 段，[transform] 是色彩变换标志（0 无 / 1 YCbCr / 2 YCCK）。
Uint8List adobeSegment(int transform) => segment(0xEE, <int>[
      0x41, 0x64, 0x6F, 0x62, 0x65, // 'Adobe'
      0x00, 0x64, // 版本
      0, 0, // flags0
      0, 0, // flags1
      transform, // 第 11 字节 —— flags 各占 2 字节，多一字节 transform 就跑偏
    ]);

/// COM 注释段。
Uint8List commentSegment(String text) =>
    segment(0xFE, <int>[...text.codeUnits]);

/// APP1 EXIF 段，只装一个方向标签（小端 TIFF）。
Uint8List exifOrientationSegment(int orientation) => segment(0xE1, <int>[
      0x45, 0x78, 0x69, 0x66, 0x00, 0x00, // 'Exif\0\0'
      0x49, 0x49, 0x2A, 0x00, // 'II' + 42
      0x08, 0x00, 0x00, 0x00, // IFD0 偏移
      0x01, 0x00, // 1 个条目
      0x12, 0x01, // 标签 0x0112 = Orientation
      0x03, 0x00, // 类型 SHORT
      0x01, 0x00, 0x00, 0x00, // count = 1
      orientation & 0xFF, 0x00, 0x00, 0x00, // 值（左对齐）
      0x00, 0x00, 0x00, 0x00, // 下一个 IFD：无
    ]);

/// SOS 载荷。分量按 `[id, td, ta]` 给。
Uint8List sosSegmentPayload(
  List<List<int>> comps, {
  int ss = 0,
  int se = 63,
  int ah = 0,
  int al = 0,
}) {
  final List<int> d = <int>[comps.length];
  for (final List<int> c in comps) {
    d.addAll(<int>[c[0], (c[1] << 4) | c[2]]);
  }
  d.addAll(<int>[ss, se, (ah << 4) | al]);
  return Uint8List.fromList(d);
}

