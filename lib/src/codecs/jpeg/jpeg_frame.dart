/// SOF 段：一帧的几何。
///
/// ## 形状全写在 SOF 里
///
/// SOF（Start Of Frame）给出样本精度、宽高、分量个数，以及每个分量的采样因子
/// 和量化表编号。marker 本身就是开关：SOF0 基线、SOF1 扩展顺序、SOF2 渐进 ——
/// 三者的**段结构完全一样**，差别只在后面的扫描怎么读这些系数。
///
/// ## 采样因子是相对的，不是绝对的
///
/// 容易把 `2x2` 读成「亮度按 2×2 块采样」。实际上 Hi/Vi 是**相对于该帧最大值**
/// 的比例：Y=2x2、Cb=1x1、Cr=1x1 表示色度分辨率是亮度的一半，也就是 4:2:0。
/// 同一组比例整体放大（Y=4x4、Cb=2x2）说的是同一件事，只会让 MCU 变大、边缘
/// 填充变多。所以必须先扫一遍求出 maxH/maxV，再用它算每个分量的真实尺寸。
///
/// ## MCU：交错扫描的最小单位
///
/// 交错扫描把各分量的块按采样比例编织在一起：一个 MCU 里先是 Y 的 Hi×Vi 个块，
/// 然后 Cb 的，然后 Cr 的。顺序读错不会报错，只会让颜色整体错位 —— 这类 bug
/// 看起来像「色彩偏移」，很难从现象反推到读取顺序上。
///
/// 图像被切成 mcusPerLine × mcusPerColumn 个 MCU，**不足一个 MCU 的边缘要补齐**。
/// 补出来的块（dummy block）里是编码器随便填的数据，解码后直接丢掉 —— 但缓冲区
/// 必须为它们留出位置，否则边缘 MCU 会写越界。
///
/// 这就是这里有两套块数的原因：[JpegComponent.blocksPerLine] 是**真实**需要的
/// 块数（非交错扫描按它走），[JpegComponent.blocksPerLineForMcu] 是**补齐到 MCU
/// 边界**的块数（交错扫描按它走，也是缓冲区的实际大小）。混用这两个数是 JPEG
/// 解码器最常见的越界来源。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/jpeg/jpeg_markers.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 一帧最多 4 个分量（灰度 1、YCbCr 3、CMYK/YCCK 4）。
const int kMaxJpegComponents = 4;

/// 采样因子的合法上限，规范定在 4。
const int kMaxSamplingFactor = 4;

/// 向上取整的整数除法。
int _ceilDiv(int a, int b) => (a + b - 1) ~/ b;

/// 最大公约数，`_gcd(0, n) == n`，用来约掉采样因子的公因子。
int _gcd(int a, int b) {
  int x = a;
  int y = b;
  while (y != 0) {
    final int t = x % y;
    x = y;
    y = t;
  }
  return x;
}

/// 一个颜色分量在帧里的全部几何信息，以及它的系数缓冲区。
class JpegComponent {
  JpegComponent._({
    required this.id,
    required this.horizontalFactor,
    required this.verticalFactor,
    required this.quantTableId,
    required this.blocksPerLine,
    required this.blocksPerColumn,
    required this.blocksPerLineForMcu,
    required this.blocksPerColumnForMcu,
    required this.sampleWidth,
    required this.sampleHeight,
  }) : coefficients = Int16List(
          blocksPerLineForMcu * blocksPerColumnForMcu * kBlockSize,
        );

  /// 分量标识符（Ci）。SOS 用它点名，不是下标 —— 有文件从 0 编号，也有从 1。
  final int id;

  /// 水平采样因子 Hi，相对该帧最大值。
  final int horizontalFactor;

  /// 垂直采样因子 Vi。
  final int verticalFactor;

  /// 量化表编号 Tqi。
  final int quantTableId;

  /// 真实需要的块数（按分量自己的像素尺寸算），非交错扫描按这个走。
  final int blocksPerLine;

  /// 同上，垂直方向。
  final int blocksPerColumn;

  /// 补齐到 MCU 边界后的块数，交错扫描按这个走，也是缓冲区的宽度。
  final int blocksPerLineForMcu;

  /// 同上，垂直方向。
  final int blocksPerColumnForMcu;

  /// 该分量自己的像素宽度（上采样前）。
  final int sampleWidth;

  /// 该分量自己的像素高度（上采样前）。
  final int sampleHeight;

  /// 整帧的量化后系数，按块行优先摊平：块 (row, col) 从
  /// `(row * blocksPerLineForMcu + col) * kBlockSize` 开始。
  ///
  /// 用 [Int16List] 而不是 Int32List：量化后的系数落在 ±2047 内，16 位够用，
  /// 而这块缓冲区是整个解码器最大的一笔内存 —— 一张 4000×3000 的 4:2:0 图，
  /// 三个分量加起来约 18M 个系数，16 位存是 36MB，32 位就是 72MB。
  ///
  /// 为什么要整帧留着、不逐块解完就扔：渐进模式下同一个系数会被多趟扫描反复
  /// 细化，只有全部扫描读完才知道终值。基线模式其实可以流式处理，但让两条
  /// 路径共用一套缓冲区和一套 IDCT 出口，比省这点内存值得。
  final Int16List coefficients;

  /// 一个 MCU 里该分量占几个块。
  int get blocksPerMcu => horizontalFactor * verticalFactor;

  /// 块 (blockRow, blockCol) 在 [coefficients] 里的起始下标。
  int blockOffset(int blockRow, int blockCol) =>
      (blockRow * blocksPerLineForMcu + blockCol) * kBlockSize;

  @override
  String toString() => 'JpegComponent(id: $id, '
      '${horizontalFactor}x$verticalFactor, quant: $quantTableId, '
      '${sampleWidth}x$sampleHeight, '
      '${blocksPerLine}x$blocksPerColumn 块)';
}

/// 一帧的完整几何，[parseSof] 的产物。
class JpegFrame {
  JpegFrame._({
    required this.marker,
    required this.precision,
    required this.width,
    required this.height,
    required this.components,
    required this.maxHorizontalFactor,
    required this.maxVerticalFactor,
    required this.mcusPerLine,
    required this.mcusPerColumn,
  });

  /// 产生这一帧的 SOF marker，决定后面的扫描怎么读。
  final int marker;

  /// 样本精度，位。基线只允许 8。
  final int precision;

  /// 图像宽度，像素。
  final int width;

  /// 图像高度，像素。
  final int height;

  /// 各分量，按 SOF 里出现的顺序 —— 交错扫描的块顺序就是这个顺序。
  final List<JpegComponent> components;

  /// 全帧最大水平采样因子，采样比例的分母。
  final int maxHorizontalFactor;

  /// 全帧最大垂直采样因子。
  final int maxVerticalFactor;

  /// 一行有几个 MCU。
  final int mcusPerLine;

  /// 一列有几个 MCU。
  final int mcusPerColumn;

  /// 是否渐进模式（SOF2）。
  bool get isProgressive => marker == kMarkerSof2;

  /// MCU 的像素宽度。
  int get mcuWidth => maxHorizontalFactor * kBlockDim;

  /// MCU 的像素高度。
  int get mcuHeight => maxVerticalFactor * kBlockDim;

  /// 按 Ci 找分量。SOS 点名用的是标识符，不是下标。
  JpegComponent? componentById(int id) {
    for (final JpegComponent c in components) {
      if (c.id == id) {
        return c;
      }
    }
    return null;
  }

  /// 采样模式的可读名字，给信息面板用。
  ///
  /// 认名字之前先约掉公因子：采样因子是比例，Y=4x4/色度 2x2 和 Y=2x2/色度 1x1
  /// 说的是同一件事（只是 MCU 更大、边缘填充更多）。认不出的组合照实报**原始**
  /// 因子 —— 能走到那一支的文件本来就少见，这时原始数字比化简后的更有诊断价值。
  String get samplingLabel {
    if (components.length == 1) {
      return '单分量（灰度）';
    }
    int divisor = 0;
    for (final JpegComponent c in components) {
      divisor = _gcd(divisor, _gcd(c.horizontalFactor, c.verticalFactor));
    }
    if (components.length == 3) {
      final int yh = components[0].horizontalFactor ~/ divisor;
      final int yv = components[0].verticalFactor ~/ divisor;
      final bool chromaMinimal = components.skip(1).every((JpegComponent c) =>
          c.horizontalFactor == divisor && c.verticalFactor == divisor);
      if (chromaMinimal) {
        if (yh == 1 && yv == 1) {
          return '4:4:4';
        }
        if (yh == 2 && yv == 1) {
          return '4:2:2';
        }
        if (yh == 2 && yv == 2) {
          return '4:2:0';
        }
        if (yh == 4 && yv == 1) {
          return '4:1:1';
        }
      }
    }
    return components
        .map((JpegComponent c) => '${c.horizontalFactor}x${c.verticalFactor}')
        .join(' ');
  }

  @override
  String toString() => 'JpegFrame(${markerName(marker)}, ${width}x$height, '
      '$precision 位, ${components.length} 分量, $samplingLabel, '
      '$mcusPerLine×$mcusPerColumn MCU)';
}

/// 解析一个 SOF 段的载荷，算出全帧几何并分配系数缓冲区。
///
/// [data] 是段载荷（不含 marker 和长度字段），[marker] 是 SOF 的第二字节，
/// [offset] 是载荷在原文件中的位置，只用于报错定位。
JpegFrame parseSof(Uint8List data, {required int marker, required int offset}) {
  if (!isSof(marker)) {
    throw ImageDecodeException(
      '0x${marker.toRadixString(16).toUpperCase()} 不是 SOF marker',
      format: 'JPEG',
      offset: offset,
    );
  }
  if (marker != kMarkerSof0 && marker != kMarkerSof1 && marker != kMarkerSof2) {
    // SOF3/5/6/7/9/…：无损、算术编码、层次编码。段结构一样，熵编码完全不同，
    // 硬着头皮读只会解出噪声，不如在这里说清楚。
    throw UnsupportedImageFeature(
      '${markerName(marker)}（无损 / 算术编码 / 层次模式）',
      format: 'JPEG',
      offset: offset,
    );
  }

  final ByteReader r = ByteReader(data, format: 'JPEG');
  final int precision = r.u8('样本精度');
  if (precision != 8) {
    // 12 位见于医学影像，读法上只差一个电平位移的中点，但整条像素管线都按
    // 8 位写的，放进来会静默截断。
    throw UnsupportedImageFeature(
      '$precision 位样本精度（只支持 8 位）',
      format: 'JPEG',
      offset: offset,
    );
  }

  final int height = r.u16be('图像高度');
  final int width = r.u16be('图像宽度');
  if (width == 0) {
    throw ImageDecodeException('图像宽度为 0', format: 'JPEG', offset: offset);
  }
  if (height == 0) {
    // 规范允许 SOF 写 0、由扫描后的 DNL 段补上真实高度。缓冲区要提前按尺寸
    // 分配，等到 DNL 才知道就得推迟整个 setup —— 这种文件极少见。
    throw UnsupportedImageFeature(
      '高度为 0 的帧（需要 DNL 段补高度）',
      format: 'JPEG',
      offset: offset,
    );
  }

  final int componentCount = r.u8('分量个数');
  if (componentCount == 0 || componentCount > kMaxJpegComponents) {
    throw ImageDecodeException(
      '分量个数 $componentCount 越界（1..$kMaxJpegComponents）',
      format: 'JPEG',
      offset: offset,
    );
  }
  // 段长必须正好装下 Nf 个三字节描述，多一字节少一字节都说明长度字段不可信。
  final int expected = 6 + 3 * componentCount;
  if (data.length != expected) {
    throw ImageDecodeException(
      'SOF 段长 ${data.length} 与 $componentCount 个分量不符（应为 $expected）',
      format: 'JPEG',
      offset: offset,
    );
  }

  final List<int> ids = <int>[];
  final List<int> hs = <int>[];
  final List<int> vs = <int>[];
  final List<int> quantIds = <int>[];
  int maxH = 1;
  int maxV = 1;
  for (int i = 0; i < componentCount; i++) {
    final int id = r.u8('分量 $i 标识符');
    if (ids.contains(id)) {
      // 重复的 Ci 让 SOS 的点名变成二义的，后面的扫描会写到错误的分量上。
      throw ImageDecodeException(
        '分量标识符 $id 重复',
        format: 'JPEG',
        offset: offset,
      );
    }
    final int factors = r.u8('分量 $i 采样因子');
    final int h = (factors >> 4) & 0x0F;
    final int v = factors & 0x0F;
    if (h < 1 || h > kMaxSamplingFactor || v < 1 || v > kMaxSamplingFactor) {
      throw ImageDecodeException(
        '分量 $id 采样因子 ${h}x$v 越界（1..$kMaxSamplingFactor）',
        format: 'JPEG',
        offset: offset,
      );
    }
    final int quantId = r.u8('分量 $i 量化表编号');
    if (quantId > 3) {
      throw ImageDecodeException(
        '分量 $id 量化表编号 $quantId 越界（0..3）',
        format: 'JPEG',
        offset: offset,
      );
    }
    ids.add(id);
    hs.add(h);
    vs.add(v);
    quantIds.add(quantId);
    if (h > maxH) {
      maxH = h;
    }
    if (v > maxV) {
      maxV = v;
    }
  }

  // 先有 maxH/maxV 才能算每个分量的真实尺寸 —— 采样因子是比例，不是绝对值。
  final int mcusPerLine = _ceilDiv(width, maxH * kBlockDim);
  final int mcusPerColumn = _ceilDiv(height, maxV * kBlockDim);

  final List<JpegComponent> components = <JpegComponent>[];
  for (int i = 0; i < componentCount; i++) {
    final int h = hs[i];
    final int v = vs[i];
    components.add(JpegComponent._(
      id: ids[i],
      horizontalFactor: h,
      verticalFactor: v,
      quantTableId: quantIds[i],
      sampleWidth: _ceilDiv(width * h, maxH),
      sampleHeight: _ceilDiv(height * v, maxV),
      blocksPerLine: _ceilDiv(_ceilDiv(width * h, maxH), kBlockDim),
      blocksPerColumn: _ceilDiv(_ceilDiv(height * v, maxV), kBlockDim),
      blocksPerLineForMcu: mcusPerLine * h,
      blocksPerColumnForMcu: mcusPerColumn * v,
    ));
  }

  return JpegFrame._(
    marker: marker,
    precision: precision,
    width: width,
    height: height,
    components: List<JpegComponent>.unmodifiable(components),
    maxHorizontalFactor: maxH,
    maxVerticalFactor: maxV,
    mcusPerLine: mcusPerLine,
    mcusPerColumn: mcusPerColumn,
  );
}

