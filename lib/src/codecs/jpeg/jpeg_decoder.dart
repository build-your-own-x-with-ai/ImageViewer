/// JPEG 解码器的顶层状态机。
///
/// 前面八个文件各管一段：marker 扫描、量化表、Huffman 表、帧几何、熵解码、
/// IDCT、升采样、色彩转换。这个文件负责把它们按正确的顺序串起来。
///
/// ## 为什么是状态机而不是流水线
///
/// PNG 能写成「读完 chunk 列表 → 拼 IDAT → 解压 → 反滤波」的直线流水，JPEG
/// 不行。段与段之间有**时序依赖**：`SOS` 用的是它之前最后一次 `DHT` 装进去的
/// 码表，而同一个 marker 可以出现任意多次并覆盖之前的状态。真实文件里确实
/// 会在两个扫描之间重新定义码表（渐进模式尤其常见），所以表必须是**可变的
/// 当前状态**，不能先收集再统一处理。
///
/// 于是解码分成两个阶段：
///
/// 1. **扫描阶段** —— 逐段更新状态，遇到 `SOS` 就把熵数据解进系数缓冲区。
///    渐进模式下这一步会跑很多趟，每趟细化同一批系数。
/// 2. **出图阶段** —— 所有扫描读完后才做反量化 + IDCT + 升采样 + 色彩转换。
///
/// 这个分界是渐进模式逼出来的：一个系数的终值要等最后一趟扫描才确定，
/// 提前做 IDCT 只能得到一张糊图。基线模式本可以流式处理，但让两条路径共用
/// 同一个出口，比省那点内存值得。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/jpeg/jpeg_color.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_exif.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_frame.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_huffman.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_idct.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_markers.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_scan.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_upsample.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 每类表最多 4 张（表号 0..3）。
const int _maxTables = 4;

/// JPEG 解码器。支持基线（SOF0）、扩展顺序（SOF1）、渐进（SOF2），
/// 任意采样因子，重启间隔，EXIF 方向，以及灰阶 / YCbCr / RGB / CMYK / YCCK
/// 五种色彩空间。
class JpegDecoder extends ImageDecoder {
  const JpegDecoder();

  @override
  String get name => 'JPEG';

  @override
  List<String> get extensions => const <String>['jpg', 'jpeg', 'jpe', 'jfif'];

  @override
  bool canDecode(Uint8List bytes) {
    // 除了 SOI（`FF D8`）还要看第三个字节是不是 `0xFF`。只认两个字节的话，
    // 任何恰好以 `FF D8` 开头的二进制都会被认成 JPEG；而真实文件里 SOI
    // 之后紧跟着的一定是另一个 marker。
    return bytes.length >= 3 &&
        bytes[0] == kMarkerPrefix &&
        bytes[1] == kMarkerSoi &&
        bytes[2] == kMarkerPrefix;
  }

  @override
  RgbaImage decode(Uint8List bytes) => _JpegSession(bytes).run();
}

/// 一次解码的全部可变状态。
///
/// 单独开一个类而不是把这些做成 [JpegDecoder] 的字段，是为了让解码器本身
/// 保持无状态、可安全共享（注册表里只有一个实例，可能被多个 isolate 用）。
class _JpegSession {
  _JpegSession(this.bytes, {Idct? idct})
      : scanner = JpegSegmentScanner(bytes),
        idct = idct ?? IdctFast();

  final Uint8List bytes;
  final JpegSegmentScanner scanner;
  final Idct idct;

  /// 量化表，按 Tq 索引。可被后续 DQT 覆盖。
  final List<QuantizationTable?> quantTables =
      List<QuantizationTable?>.filled(_maxTables, null);

  /// DC / AC 码表，按 Th 索引。
  final List<JpegHuffmanTable?> dcTables =
      List<JpegHuffmanTable?>.filled(_maxTables, null);
  final List<JpegHuffmanTable?> acTables =
      List<JpegHuffmanTable?>.filled(_maxTables, null);

  /// 当前重启间隔，DRI 设定，0 表示不用重启 marker。
  int restartInterval = 0;

  JpegFrame? frame;

  // —— 只影响元数据与色彩空间判定的旁路信息 ——
  bool hasJfif = false;
  int? adobeTransform;
  JpegOrientation orientation = JpegOrientation.normal;
  String? comment;
  int scanCount = 0;

  RgbaImage run() {
    scanner.readSoi();
    while (scanner.hasMore) {
      final JpegSegment? segment = scanner.next();
      if (segment == null || segment.marker == kMarkerEoi) {
        break;
      }
      _handle(segment);
    }

    final JpegFrame? f = frame;
    if (f == null) {
      throw ImageDecodeException('文件里没有 SOF 段，不知道图像尺寸',
          format: 'JPEG');
    }
    if (scanCount == 0) {
      throw ImageDecodeException('文件里没有 SOS 段，没有任何图像数据',
          format: 'JPEG');
    }
    return _render(f);
  }

  void _handle(JpegSegment segment) {
    final int marker = segment.marker;
    if (isSof(marker)) {
      _readSof(segment);
      return;
    }
    switch (marker) {
      case kMarkerDqt:
        for (final QuantizationTable t
            in parseDqt(scanner.dataOf(segment), offset: segment.dataOffset)) {
          quantTables[t.id] = t;
        }
      case kMarkerDht:
        for (final JpegHuffmanTable t
            in parseDht(scanner.dataOf(segment), offset: segment.dataOffset)) {
          final List<JpegHuffmanTable?> into =
              t.tableClass == HuffmanTableClass.dc ? dcTables : acTables;
          into[t.id] = t;
        }
      case kMarkerDri:
        _readDri(segment);
      case kMarkerSos:
        _readSos(segment);
      case kMarkerApp0:
        if (isJfifApp0(scanner.dataOf(segment))) {
          hasJfif = true;
        }
      case kMarkerApp1:
        // 坏 EXIF 返回 null，方向就保持 normal —— 不影响像素解码。
        final JpegOrientation? o =
            parseExifOrientation(scanner.dataOf(segment));
        if (o != null) {
          orientation = o;
        }
      case kMarkerApp14:
        final int? t = parseAdobeTransform(scanner.dataOf(segment));
        if (t != null) {
          adobeTransform = t;
        }
      case kMarkerCom:
        comment ??= _readComment(scanner.dataOf(segment));
      default:
        // 其余段一律跳过：APP2..APP13（ICC、Ducky、Photoshop 资源）、DNL、
        // 以及零散落在段边界上的 RSTn。它们要么与像素无关，要么已经在
        // 熵解码里消化掉了。扫描器读长度时已经把偏移推过去了。
        break;
    }
  }

  void _readSof(JpegSegment segment) {
    if (frame != null) {
      // 一个文件里出现第二个 SOF 只有两种可能：层次模式（DHP + 多帧），
      // 或者文件被拼接了。两种都不是简单覆盖能对付的。
      throw UnsupportedImageFeature('多帧 / 层次模式 JPEG',
          format: 'JPEG', offset: segment.offset);
    }
    final JpegFrame f = parseSof(
      scanner.dataOf(segment),
      marker: segment.marker,
      offset: segment.dataOffset,
    );
    // parseSof 只保证宽高非 0。这里再过一遍全局上限 —— SOF 的宽高各占两字节，
    // 65535×65535 是合法编码，但那是 43 亿像素、17GB 的 RGBA 缓冲区。
    RgbaImage.validateDimensions(f.width, f.height, format: 'JPEG');
    frame = f;
  }

  void _readDri(JpegSegment segment) {
    final Uint8List data = scanner.dataOf(segment);
    if (data.length < 2) {
      throw ImageDecodeException('DRI 段只有 ${data.length} 字节，应为 2',
          format: 'JPEG', offset: segment.dataOffset);
    }
    restartInterval = (data[0] << 8) | data[1];
  }

  void _readSos(JpegSegment segment) {
    final JpegFrame? f = frame;
    if (f == null) {
      throw ImageDecodeException('SOS 出现在 SOF 之前，没有帧几何可用',
          format: 'JPEG', offset: segment.offset);
    }
    final JpegScanHeader scan = parseSos(
      scanner.dataOf(segment),
      frame: f,
      offset: segment.dataOffset,
    );
    // 熵数据没有长度字段，只有熵解码器自己知道它停在哪 —— 扫描器从那里继续。
    final int end = decodeScan(
      bytes,
      start: segment.dataOffset + segment.length,
      frame: f,
      scan: scan,
      dcTables: dcTables,
      acTables: acTables,
      restartInterval: restartInterval,
    );
    scanner.offset = end;
    scanCount++;
  }

  /// COM 段的内容。规范没规定编码，实践中是 ASCII 或 UTF-8。
  ///
  /// 截到 200 字符：注释段可以有 64KB，信息面板放不下，而且这只是展示用。
  String? _readComment(Uint8List data) {
    if (data.isEmpty) {
      return null;
    }
    final StringBuffer sb = StringBuffer();
    final int limit = data.length < 200 ? data.length : 200;
    for (int i = 0; i < limit; i++) {
      final int c = data[i];
      // 控制字符换成空格，免得把信息面板的排版搞乱。
      sb.writeCharCode(c >= 0x20 && c != 0x7F ? c : 0x20);
    }
    final String text = sb.toString().trim();
    return text.isEmpty ? null : text;
  }

  /// 出图阶段：反量化 + IDCT + 升采样 + 色彩转换 + 方向。
  RgbaImage _render(JpegFrame f) {
    final JpegColorSpace space = chooseColorSpace(
      componentIds: <int>[for (final JpegComponent c in f.components) c.id],
      hasJfif: hasJfif,
      adobeTransform: adobeTransform,
    );

    final List<Uint8List> planes = <Uint8List>[];
    for (final JpegComponent c in f.components) {
      final QuantizationTable? q = quantTables[c.quantTableId];
      if (q == null) {
        throw ImageDecodeException(
          '分量 ${c.id} 用的量化表 #${c.quantTableId} 没有定义过',
          format: 'JPEG',
        );
      }
      planes.add(upsampleComponent(renderComponent(c, q, idct), c, f));
    }

    Uint8List pixels = convertToRgba(
      planes: planes,
      colorSpace: space,
      pixelCount: f.width * f.height,
      // 有 Adobe 段就意味着样本是反存的（见 jpeg_color.dart 里的说明）。
      adobeInverted: adobeTransform != null,
    );

    int width = f.width;
    int height = f.height;
    if (orientation != JpegOrientation.normal) {
      pixels = applyOrientation(pixels, width, height, orientation);
      if (orientation.swapsDimensions) {
        width = f.height;
        height = f.width;
      }
    }

    return RgbaImage(
      width: width,
      height: height,
      pixels: pixels,
      metadata: _buildMetadata(f, space),
    );
  }

  ImageMetadata _buildMetadata(JpegFrame f, JpegColorSpace space) {
    final Map<String, Object> extra = <String, Object>{
      '采样': f.samplingLabel,
      '采样因子': <String>[
        for (final JpegComponent c in f.components)
          '${c.horizontalFactor}x${c.verticalFactor}',
      ].join(' '),
      'MCU': '${f.mcuWidth}x${f.mcuHeight}'
          '（${f.mcusPerLine}x${f.mcusPerColumn} 个）',
      '扫描趟数': scanCount,
      '量化表': quantTables.where((QuantizationTable? t) => t != null).length,
      '码表': dcTables.where((JpegHuffmanTable? t) => t != null).length +
          acTables.where((JpegHuffmanTable? t) => t != null).length,
      'IDCT': idct.name,
    };
    if (restartInterval > 0) {
      extra['重启间隔'] = '$restartInterval 个 MCU';
    }
    if (orientation != JpegOrientation.normal) {
      extra['EXIF 方向'] = '${orientation.exifValue}（${orientation.label}）';
    }
    if (adobeTransform != null) {
      extra['Adobe 变换'] = adobeTransform!;
    }
    if (hasJfif) {
      extra['JFIF'] = '有';
    }
    if (comment != null) {
      extra['注释'] = comment!;
    }

    return ImageMetadata(
      format: 'JPEG',
      variant: _variantLabel(f),
      bitDepth: f.precision,
      channels: f.components.length,
      colorSpace: colorSpaceLabel(space),
      compression: 'DCT + Huffman',
      isLossless: false,
      extra: extra,
    );
  }

  String _variantLabel(JpegFrame f) {
    switch (f.marker) {
      case kMarkerSof0:
        return '基线（SOF0）';
      case kMarkerSof1:
        return '扩展顺序（SOF1）';
      case kMarkerSof2:
        return '渐进（SOF2）';
      default:
        return markerName(f.marker);
    }
  }
}
