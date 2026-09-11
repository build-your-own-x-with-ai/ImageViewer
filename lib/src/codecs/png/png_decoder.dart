/// PNG 解码器，把前面各层串成一条流水线。
///
/// ## 六道工序
///
/// ```
/// 1. 签名     8 字节，四种行尾事故的探针        png_chunk.dart
/// 2. chunk    长度+类型+数据+CRC32，逐个校验    png_chunk.dart
/// 3. IHDR     宽高、位深、色彩类型、隔行方式    png_header.dart
/// 4. inflate  拼接所有 IDAT，zlib 解压          compress/inflate.dart
/// 5. 反滤波   逐行还原，五种滤波器             png_filters.dart
/// 6. 展开     采样 → RGBA8888                  png_pixels.dart
/// ```
///
/// 每一层都能单独测试，这是 PNG 比 JPEG 好写得多的原因 —— 它的各个
/// 环节之间只用字节数组通信，没有跨层的状态。
///
/// ## 为什么图像数据要拆成多个 IDAT
///
/// 一张图的压缩数据本来是一条连续的 zlib 流，规范却允许（并鼓励）把它
/// 切成多个 `IDAT` chunk。原因是 chunk 长度字段只有 31 位这件事根本不
/// 是瓶颈 —— 真正的考虑是**编码器可以流式输出**：压一点写一点，不必先
/// 在内存里攒出完整的压缩流再回填长度。
///
/// 于是解码方必须先把所有 `IDAT` 的数据首尾相接，再当成一条流去解压。
/// 边界不能在 chunk 处对齐 —— 一个 deflate 块完全可以跨过两个 `IDAT`。
/// 这是 PNG 解码里第二个容易想当然的地方（第一个是 Adam7 的行宽）。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/png/png_chunk.dart';
import 'package:image_viewer/src/codecs/png/png_filters.dart';
import 'package:image_viewer/src/codecs/png/png_header.dart';
import 'package:image_viewer/src/codecs/png/png_interlace.dart';
import 'package:image_viewer/src/codecs/png/png_palette.dart';
import 'package:image_viewer/src/codecs/png/png_pixels.dart';
import 'package:image_viewer/src/codecs/png/png_types.dart';
import 'package:image_viewer/src/compress/inflate.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// PNG 解码器。支持全部五种色彩类型、全部合法位深、`tRNS` 与 Adam7 隔行。
class PngDecoder extends ImageDecoder {
  const PngDecoder();

  @override
  String get name => 'PNG';

  @override
  List<String> get extensions => const <String>['png'];

  @override
  bool canDecode(Uint8List bytes) {
    if (bytes.length < kPngSignature.length) {
      return false;
    }
    for (int i = 0; i < kPngSignature.length; i++) {
      if (bytes[i] != kPngSignature[i]) {
        return false;
      }
    }
    return true;
  }

  @override
  RgbaImage decode(Uint8List bytes) {
    final _PngFile file = _PngFile.read(bytes);
    final PngHeader header = file.header;

    // 解压。上限设为「按 IHDR 算出来的确切字节数」—— 多一个字节都说明
    // 数据有问题，这同时也是对解压炸弹的防御：声称 1×1 的图无论压缩流
    // 里藏了多少数据，都会在第 (rawSize + 1) 个字节上失败。
    final int expected = expectedRawSize(header);
    final InflateResult inflated = inflateZlib(
      file.concatIdat(),
      sizeHint: expected,
      sizeLimit: expected,
      format: 'PNG',
    );
    final Uint8List raw = inflated.bytes;

    if (raw.length != expected) {
      throw ImageDecodeException(
        '解压后数据量不符：按 IHDR（${header.width}x${header.height}，'
        '${header.bitDepth} 位 ${header.colorType.description}'
        '${header.interlace == PngInterlaceMethod.adam7 ? '，Adam7 隔行' : ''}）'
        '应得 $expected 字节，实际 ${raw.length} 字节',
        format: 'PNG',
      );
    }

    final Uint8List out = Uint8List(header.width * header.height * 4);
    final PixelExpander expander = PixelExpander(
      colorType: header.colorType,
      bitDepth: header.bitDepth,
      palette: file.palette,
      colorKey: file.colorKey,
    );
    final FilterStats stats = FilterStats();

    int src = 0;
    for (final Adam7Pass pass in passesFor(header)) {
      src = _decodePass(
        pass,
        header: header,
        raw: raw,
        src: src,
        out: out,
        expander: expander,
        stats: stats,
      );
    }

    return RgbaImage(
      width: header.width,
      height: header.height,
      pixels: out,
      metadata: _buildMetadata(file, inflated, stats, expander, expected),
    );
  }

  /// 解一遍扫描，返回消耗到的新位置。
  ///
  /// 非隔行图走的是 `kSinglePass`（偏移 0、步长 1），与隔行共用这段代码。
  int _decodePass(
    Adam7Pass pass, {
    required PngHeader header,
    required Uint8List raw,
    required int src,
    required Uint8List out,
    required PixelExpander expander,
    required FilterStats stats,
  }) {
    final int passWidth = pass.widthFor(header.width);
    final int passHeight = pass.heightFor(header.height);

    // 关键：按本遍宽度重算每行字节数，不能沿用整图的。
    // 见 Adam7Pass.widthFor 的注释。
    final int bytesPerRow =
        pass.bytesPerRowFor(header.width, header.bitsPerPixel);
    final int bpp = header.bytesPerPixel;

    // 两个行缓冲轮换：反滤波需要上一行，展开完就可以丢。
    // 比留着整幅未展开的数据省一份内存。
    Uint8List current = Uint8List(bytesPerRow);
    Uint8List previous = Uint8List(bytesPerRow);
    bool hasPrevious = false;
    int offset = src;

    for (int y = 0; y < passHeight; y++) {
      final PngFilterType filter = PngFilterType.fromValue(
        raw[offset],
        offset: offset,
        row: y,
      );
      offset++;
      stats.record(filter);

      current.setRange(0, bytesPerRow, raw, offset);
      offset += bytesPerRow;

      unfilterRow(current, hasPrevious ? previous : null, bpp, filter);

      expander.expandRow(
        current,
        out,
        count: passWidth,
        dstIndex: (pass.yOffset + y * pass.yStep) * header.width + pass.xOffset,
        dstStep: pass.xStep,
      );

      final Uint8List swap = previous;
      previous = current;
      current = swap;
      hasPrevious = true;
    }

    return offset;
  }
  ImageMetadata _buildMetadata(
    _PngFile file,
    InflateResult inflated,
    FilterStats stats,
    PixelExpander expander,
    int rawSize,
  ) {
    final PngHeader h = file.header;
    final Map<String, Object> extra = <String, Object>{
      '隔行方式': h.interlace.description,
      '滤波器用量': stats.summary,
      'deflate 块': inflated.blockSummary,
      '压缩数据': '${file.idatBytes} 字节（${file.idatCount} 个 IDAT）',
      '解压后': '$rawSize 字节',
      '压缩率': _ratio(file.idatBytes, rawSize),
    };
    if (expander.sawTransparency) {
      extra['透明像素'] = '有';
    }
    if (file.palette != null) {
      extra['调色板'] = '${file.palette!.entryCount} 项';
    }
    if (file.colorKey != null) {
      extra['关键色透明'] = file.colorKey!.toString();
    }
    extra['chunk 数'] = file.chunkCount;
    extra.addAll(file.textInfo);

    return ImageMetadata(
      format: 'PNG',
      variant: '${h.colorType.description}'
          '${h.interlace == PngInterlaceMethod.adam7 ? ' + Adam7 隔行' : ''}',
      bitDepth: h.bitDepth,
      channels: h.colorType.channels,
      colorSpace: h.colorType.isIndexed ? '调色板（sRGB）' : 'sRGB',
      compression: 'deflate',
      isLossless: true,
      extra: extra,
    );
  }

  static String _ratio(int compressed, int raw) {
    if (compressed <= 0) {
      return '—';
    }
    final double times = raw / compressed;
    return '${times.toStringAsFixed(2)}:1';
  }
}

/// 已完成 chunk 层解析、尚未解压的 PNG 文件。
class _PngFile {
  _PngFile._(this.header);

  final PngHeader header;

  PngPalette? palette;
  PngColorKey? colorKey;

  final List<Uint8List> _idat = <Uint8List>[];
  int idatBytes = 0;
  int idatCount = 0;
  int chunkCount = 0;

  /// IDAT 序列是否已经结束（后面再出现 IDAT 就是错的）。
  bool _idatDone = false;

  /// 辅助 chunk 里读到的可显示信息。
  final Map<String, Object> textInfo = <String, Object>{};

  /// 把所有 IDAT 的数据接成一条 zlib 流。
  ///
  /// 不能逐个 chunk 分别解压 —— 一个 deflate 块可以跨越 IDAT 边界，
  /// chunk 的切分位置和压缩流的结构完全无关。
  Uint8List concatIdat() {
    if (_idat.length == 1) {
      return _idat.first; // 绝大多数文件只有一个 IDAT，省一次拷贝
    }
    final Uint8List all = Uint8List(idatBytes);
    int at = 0;
    for (final Uint8List part in _idat) {
      all.setRange(at, at + part.length, part);
      at += part.length;
    }
    return all;
  }

  static int _be32(Uint8List d, int i) =>
      d[i] * 16777216 + d[i + 1] * 65536 + d[i + 2] * 256 + d[i + 3];

  /// 读完整个 chunk 序列。
  ///
  /// `IHDR` 必须是第一个 chunk —— 不然解码器连宽高都不知道，无从判断
  /// 后面的数据是否合理。这是规范里少数几条硬性的顺序要求之一。
  static _PngFile read(Uint8List bytes) {
    final PngChunkReader reader = PngChunkReader(bytes);

    final PngChunk first = reader.next();
    if (first.type != 'IHDR') {
      throw ImageDecodeException(
        '第一个 chunk 应为 IHDR，实际是 ${first.type}',
        format: 'PNG',
        offset: first.offset,
      );
    }
    final _PngFile file =
        _PngFile._(PngHeader.parse(first.data, chunkOffset: first.offset + 8));
    file.chunkCount = 1;

    bool sawEnd = false;
    while (reader.hasMore) {
      final PngChunk chunk = reader.next();
      file.chunkCount++;
      if (chunk.type == 'IEND') {
        sawEnd = true;
        break;
      }
      file._accept(chunk);
    }

    if (!sawEnd) {
      throw ImageDecodeException(
        '文件缺少 IEND chunk，多半是被截断了',
        format: 'PNG',
        offset: reader.offset,
      );
    }
    if (file._idat.isEmpty) {
      throw ImageDecodeException('文件没有 IDAT chunk，不含任何图像数据',
          format: 'PNG');
    }
    if (file.header.colorType.isIndexed && file.palette == null) {
      throw ImageDecodeException(
        '调色板图缺少 PLTE chunk',
        format: 'PNG',
      );
    }
    return file;
  }
  /// 处理一个非 IHDR、非 IEND 的 chunk。
  void _accept(PngChunk chunk) {
    final int dataOffset = chunk.offset + 8;
    switch (chunk.type) {
      case 'IHDR':
        throw ImageDecodeException('出现了第二个 IHDR chunk',
            format: 'PNG', offset: chunk.offset);

      case 'PLTE':
        _acceptPlte(chunk, dataOffset);

      case 'tRNS':
        _acceptTrns(chunk, dataOffset);

      case 'IDAT':
        // IDAT 必须连续。中间插了别的 chunk 又出现 IDAT，说明文件
        // 结构被破坏了 —— 若不检查就会把两段本不相邻的压缩数据
        // 接在一起，得到一堆无意义的字节。
        if (_idatDone) {
          throw ImageDecodeException(
            'IDAT chunk 不连续：中间插入了其他 chunk',
            format: 'PNG',
            offset: chunk.offset,
          );
        }
        _idat.add(chunk.data);
        idatBytes += chunk.data.length;
        idatCount++;

      default:
        if (_idat.isNotEmpty) {
          _idatDone = true;
        }
        _acceptAncillary(chunk, dataOffset);
    }
  }
  void _acceptPlte(PngChunk chunk, int dataOffset) {
    if (_idat.isNotEmpty) {
      throw ImageDecodeException('PLTE 必须出现在 IDAT 之前',
          format: 'PNG', offset: chunk.offset);
    }
    if (palette != null) {
      throw ImageDecodeException('出现了第二个 PLTE chunk',
          format: 'PNG', offset: chunk.offset);
    }

    // 灰度类型不允许有调色板 —— 索引一个灰度值毫无意义。
    if (header.colorType.isGrayscale) {
      throw ImageDecodeException(
        '${header.colorType.description}图不能带 PLTE chunk',
        format: 'PNG',
        offset: chunk.offset,
      );
    }

    final PngPalette parsed = PngPalette.parse(chunk.data, offset: dataOffset);

    if (header.colorType.isIndexed) {
      // 索引不能超出调色板范围，而位深决定了索引的取值上限。
      // 提前查出来，比解到一半才发现越界要好。
      final int maxIndex = header.maxSampleValue;
      if (parsed.entryCount <= maxIndex) {
        textInfo['调色板说明'] =
            '${parsed.entryCount} 项，${header.bitDepth} 位索引最大可到 $maxIndex';
      }
      palette = parsed;
    } else {
      // 真彩色图里的 PLTE 是「建议调色板」，供只能显示 256 色的设备
      // 降色用。我们直接输出真彩色，所以只在信息面板里提一句。
      textInfo['建议调色板'] = '${parsed.entryCount} 项（真彩色图，解码时未使用）';
    }
  }
  void _acceptTrns(PngChunk chunk, int dataOffset) {
    if (_idat.isNotEmpty) {
      throw ImageDecodeException('tRNS 必须出现在 IDAT 之前',
          format: 'PNG', offset: chunk.offset);
    }
    if (header.colorType.hasAlpha) {
      throw ImageDecodeException(
        '${header.colorType.description}已有 alpha 通道，不允许再带 tRNS',
        format: 'PNG',
        offset: chunk.offset,
      );
    }

    if (header.colorType.isIndexed) {
      // 顺序要求：tRNS 里的 alpha 是按调色板下标排的，PLTE 还没读到
      // 就无从对应。规范因此规定 tRNS 必须在 PLTE 之后。
      final PngPalette? p = palette;
      if (p == null) {
        throw ImageDecodeException(
          '调色板图的 tRNS 必须出现在 PLTE 之后',
          format: 'PNG',
          offset: chunk.offset,
        );
      }
      p.applyTransparency(chunk.data, offset: dataOffset);
    } else {
      colorKey = PngColorKey.parse(
        chunk.data,
        header.colorType,
        offset: dataOffset,
      );
    }
  }
  /// 处理辅助 chunk。认识的取出信息，不认识的按大小写决定跳过还是报错。
  void _acceptAncillary(PngChunk chunk, int dataOffset) {
    switch (chunk.type) {
      case 'gAMA':
        // 4 字节定点数，值是 gamma × 100000。
        if (chunk.data.length == 4) {
          final int g = _be32(chunk.data, 0);
          textInfo['gAMA'] = (g / 100000).toStringAsFixed(5);
        }

      case 'pHYs':
        // 每单位的像素数 + 单位标识（1 = 米）。除以 39.37 得 DPI。
        if (chunk.data.length == 9) {
          final int x = _be32(chunk.data, 0);
          final int y = _be32(chunk.data, 4);
          final bool meters = chunk.data[8] == 1;
          textInfo['pHYs'] = meters
              ? '$x×$y 像素/米（约 ${(x / 39.3701).round()}×'
                  '${(y / 39.3701).round()} DPI）'
              : '$x×$y（单位未指定，仅表示宽高比）';
        }

      case 'tEXt':
        _acceptText(chunk);

      default:
        // 这一条是 PNG 向前兼容的核心：不认识的**辅助** chunk 跳过就好，
        // 不认识的**关键** chunk 必须报错 —— 它可能改变了像素的含义，
        // 硬解出来的图会是错的。判断依据就是类型名首字母的大小写。
        if (chunk.isCritical) {
          throw UnsupportedImageFeature(
            '遇到未知的关键 chunk "${chunk.type}"。'
            '关键 chunk 会影响像素解释，跳过它会解出错误的图像',
            format: 'PNG',
            offset: chunk.offset,
          );
        }
        // 辅助 chunk：记一笔类型名，不解析内容。
        final Object? seen = textInfo['其他 chunk'];
        final String prefix = seen is String ? '$seen, ' : '';
        textInfo['其他 chunk'] = '$prefix${chunk.type}'
            '${chunk.isPrivate ? '（私有）' : ''}';
    }
  }

  /// `tEXt`：`关键字\0文本`，两段都是 Latin-1。
  void _acceptText(PngChunk chunk) {
    final int nul = chunk.data.indexOf(0);
    if (nul <= 0) {
      return; // 没有分隔符，格式不对，静默忽略（辅助 chunk 不值得中断解码）
    }
    final String keyword = String.fromCharCodes(chunk.data, 0, nul);
    final String value = String.fromCharCodes(chunk.data, nul + 1);
    textInfo['tEXt:$keyword'] = value.length > 120
        ? '${value.substring(0, 120)}…'
        : value;
  }
}
