import 'dart:typed_data';

import 'package:image_viewer/src/codecs/yuv/yuv_color.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_format.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_options.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 裸 YUV 解码器。
///
/// ## 它和其他格式不是一类东西
///
/// 别的格式解码器回答的是「这串字节是什么」；YUV 解码器回答的是
/// 「按这套参数解释这串字节会得到什么」。因为裸 YUV 没有头部 —— 没有魔数、
/// 没有尺寸、没有格式标识，文件第一个字节就是第一个像素的亮度值。
///
/// 所以 [canDecode] 恒返回 `false`（没有魔数可嗅），[decode] 直接报错，
/// 必须走 [decodeWith] 显式传参。这不是设计缺陷，是格式本身的性质。
///
/// ## 三条路径覆盖九种格式
///
/// 九种格式的差别被 [YuvFormat] 参数化掉了，这里只需按 [YuvLayout] 分三条
/// 循环。色彩转换又被 [YuvColorConverter] 参数化掉了，三种矩阵 × 两种范围
/// 共用一条公式。加一种格式或一种矩阵都不需要改这个文件。
class YuvDecoder extends ParameterizedImageDecoder<YuvOptions> {
  const YuvDecoder();

  @override
  String get name => 'YUV';

  @override
  List<String> get extensions => const <String>[
        'yuv',
        'raw',
        'i420',
        'yv12',
        'nv12',
        'nv21',
        'yuy2',
        'uyvy',
      ];

  @override
  YuvOptions get defaultOptions => YuvOptions.empty;

  /// 恒为 `false` —— 裸 YUV 没有任何可嗅探的特征。
  ///
  /// 这里返回 `true` 会是灾难：注册表按顺序试探，YUV 会抢走所有它认不出的
  /// 文件，把「未知格式」变成一堆彩色噪点。宁可让用户显式选择。
  @override
  bool canDecode(Uint8List bytes) => false;

  @override
  RgbaImage decode(Uint8List bytes) {
    throw ImageDecodeException(
      '裸 YUV 数据没有头部，无法自动识别。'
      '请指定宽、高、像素格式、色彩矩阵与取值范围后调用 decodeWith。'
      '（文件长度 ${bytes.length} 字节）',
      format: 'YUV',
    );
  }

  @override
  RgbaImage decodeWith(Uint8List bytes, YuvOptions options) {
    if (!options.isComplete) {
      throw ImageDecodeException(
        '缺少必需参数：宽与高必须为正数（实际 ${options.width}x${options.height}）',
        format: 'YUV',
      );
    }
    RgbaImage.validateDimensions(options.width, options.height, format: 'YUV');
    options.format.validateFor(options.width, options.height);

    final int start = _resolveFrameStart(bytes, options);
    final RgbaImage img = RgbaImage.alloc(options.width, options.height);
    final YuvColorConverter conv =
        YuvColorConverter(options.matrix, options.range);

    switch (options.format.layout) {
      case YuvLayout.planar:
        _decodePlanar(bytes, start, options, conv, img);
      case YuvLayout.semiPlanar:
        _decodeSemiPlanar(bytes, start, options, conv, img);
      case YuvLayout.packed:
        _decodePacked(bytes, start, options, conv, img);
    }

    return RgbaImage(
      width: img.width,
      height: img.height,
      pixels: img.pixels,
      metadata: _buildMetadata(options, conv, bytes.length),
    );
  }

  // ———————————————————————————————————————————————————————————————
  // 路径一：三平面分离（I420 / YV12 / I422 / I444）
  // ———————————————————————————————————————————————————————————————

  void _decodePlanar(
    Uint8List bytes,
    int start,
    YuvOptions options,
    YuvColorConverter conv,
    RgbaImage img,
  ) {
    final YuvFormat f = options.format;
    final int width = options.width;
    final int height = options.height;
    final int chromaW = f.chromaWidth(width);
    final int chromaSize = chromaW * f.chromaHeight(height);

    // I420 与 YV12 的唯一差别就是这两个偏移谁大谁小。
    final int uPlane = start + width * height + (f.uFirst ? 0 : chromaSize);
    final int vPlane = start + width * height + (f.uFirst ? chromaSize : 0);

    for (int y = 0; y < height; y++) {
      final int lumaRow = start + y * width;
      // 色度上采样用最近邻：整除即可，不必插值。这是解码器的常规做法 ——
      // 双线性插值更平滑，但会让「色度分辨率更低」这件事变得不易观察。
      final int chromaRow = (y ~/ f.subY) * chromaW;
      int out = y * width * 4;

      for (int x = 0; x < width; x++) {
        final int cx = x ~/ f.subX;
        conv.convert(
          bytes[lumaRow + x],
          bytes[uPlane + chromaRow + cx],
          bytes[vPlane + chromaRow + cx],
          img.pixels,
          out,
        );
        out += 4;
      }
    }
  }

  // ———————————————————————————————————————————————————————————————
  // 路径二：双平面，色度交织（NV12 / NV21）
  // ———————————————————————————————————————————————————————————————

  void _decodeSemiPlanar(
    Uint8List bytes,
    int start,
    YuvOptions options,
    YuvColorConverter conv,
    RgbaImage img,
  ) {
    final YuvFormat f = options.format;
    final int width = options.width;
    final int height = options.height;
    final int chromaW = f.chromaWidth(width);
    final int chromaPlane = start + width * height;

    // NV12 是 UVUV…，NV21 是 VUVU… —— 差别只有这两个字节内偏移。
    final int uOff = f.uFirst ? 0 : 1;
    final int vOff = f.uFirst ? 1 : 0;

    for (int y = 0; y < height; y++) {
      final int lumaRow = start + y * width;
      // 交织平面里每个色度采样占两字节，所以行距是 chromaW * 2。
      final int chromaRow = chromaPlane + (y ~/ f.subY) * chromaW * 2;
      int out = y * width * 4;

      for (int x = 0; x < width; x++) {
        final int pair = chromaRow + (x ~/ f.subX) * 2;
        conv.convert(
          bytes[lumaRow + x],
          bytes[pair + uOff],
          bytes[pair + vOff],
          img.pixels,
          out,
        );
        out += 4;
      }
    }
  }

  // ———————————————————————————————————————————————————————————————
  // 路径三：单平面打包（YUY2 / YVYU / UYVY）
  // ———————————————————————————————————————————————————————————————

  void _decodePacked(
    Uint8List bytes,
    int start,
    YuvOptions options,
    YuvColorConverter conv,
    RgbaImage img,
  ) {
    final YuvFormat f = options.format;
    final int width = options.width;
    final int height = options.height;

    // 一个宏像素四字节表示两个像素。两个布尔值定出四个字节的含义：
    //   lumaFirst=true,  uFirst=true  → Y0 U  Y1 V   (YUY2)
    //   lumaFirst=true,  uFirst=false → Y0 V  Y1 U   (YVYU)
    //   lumaFirst=false, uFirst=true  → U  Y0 V  Y1  (UYVY)
    final int y0Off = f.lumaFirst ? 0 : 1;
    final int y1Off = f.lumaFirst ? 2 : 3;
    final int c0Off = f.lumaFirst ? 1 : 0;
    final int c1Off = f.lumaFirst ? 3 : 2;
    final int uOff = f.uFirst ? c0Off : c1Off;
    final int vOff = f.uFirst ? c1Off : c0Off;

    final int rowStride = width * 2;

    for (int y = 0; y < height; y++) {
      final int row = start + y * rowStride;
      int out = y * width * 4;

      // 每次前进两个像素 —— 它们共用一对色度。宽度为偶数已由
      // YuvFormat.validateFor 保证，所以不必处理落单的像素。
      for (int x = 0; x < width; x += 2) {
        final int p = row + x * 2;
        final int u = bytes[p + uOff];
        final int v = bytes[p + vOff];
        conv.convert(bytes[p + y0Off], u, v, img.pixels, out);
        conv.convert(bytes[p + y1Off], u, v, img.pixels, out + 4);
        out += 8;
      }
    }
  }

  // ———————————————————————————————————————————————————————————————
  // 边界检查
  // ———————————————————————————————————————————————————————————————

  /// 算出本帧在文件里的起始偏移，并确认这一帧的数据是完整的。
  int _resolveFrameStart(Uint8List bytes, YuvOptions options) {
    final int frameSize = options.frameSize;
    final int available = bytes.length;

    if (options.frameIndex < 0) {
      throw ImageDecodeException(
        '帧号不能为负（实际 ${options.frameIndex}）',
        format: 'YUV',
      );
    }

    final int start = options.byteOffset;
    if (start + frameSize > available) {
      // 参数错配是裸 YUV 最常见的问题，而且**不会**表现为报错 ——
      // 尺寸猜错但字节数够的话会解出一张斜纹图。所以这里要把话说透，
      // 顺便告诉用户什么尺寸才对得上。
      final int frames = options.frameCountIn(available);
      final String hint = frames > 0
          ? '文件里只有 $frames 帧完整数据，取不到第 ${options.frameIndex} 帧'
          : _describeMismatch(options, available);
      throw ImageDecodeException(
        '${options.width}x${options.height} 的 ${options.format.label} '
        '每帧需 $frameSize 字节，文件共 $available 字节：$hint',
        format: 'YUV',
        offset: start,
      );
    }
    return start;
  }

  /// 字节数对不上时给一条有用的提示。
  ///
  /// 只在报错路径上调用，所以这里的线性扫描不影响正常解码性能。
  String _describeMismatch(YuvOptions options, int available) {
    final int guessed = _guessHeight(options, available);
    if (guessed > 0 && guessed != options.height) {
      return '按宽 ${options.width} 与 ${options.format.label} 推算，'
          '这份数据的高度应是 $guessed';
    }
    return '数据不足，还差 ${options.frameSize - available} 字节';
  }

  /// 固定宽度与格式，反推能让帧大小刚好等于 [available] 的高度。
  ///
  /// 找不到就返回 0。帧大小随高度单调递增，所以从小到大扫到超过即可停。
  int _guessHeight(YuvOptions options, int available) {
    for (int h = 1; h <= kMaxImageDimension; h++) {
      final int size = options.format.frameSize(options.width, h);
      if (size == available) {
        return h;
      }
      if (size > available) {
        return 0;
      }
    }
    return 0;
  }

  // ———————————————————————————————————————————————————————————————
  // 元数据
  // ———————————————————————————————————————————————————————————————

  ImageMetadata _buildMetadata(
    YuvOptions options,
    YuvColorConverter conv,
    int byteLength,
  ) {
    final YuvFormat f = options.format;
    final int frames = options.frameCountIn(byteLength);

    final Map<String, Object> extra = <String, Object>{
      '平面布局': f.layout.description,
      '色度抽样': f.samplingLabel,
      '色彩矩阵': conv.matrix.description,
      '取值范围': conv.range.description,
      '每帧字节数': options.frameSize,
      '色度平面尺寸':
          '${f.chromaWidth(options.width)}x${f.chromaHeight(options.height)}',
      '色度上采样': '最近邻',
    };
    if (frames > 1) {
      extra['帧'] = '第 ${options.frameIndex + 1} / $frames 帧';
    }
    if (f.aka.isNotEmpty) {
      extra['别名'] = f.aka;
    }
    // 转换系数摊平成一行，方便信息面板显示，也方便教学时对照公式。
    extra['转换系数'] = conv
        .describeCoefficients()
        .entries
        .map((MapEntry<String, String> e) => '${e.key}=${e.value}')
        .join('  ');

    return ImageMetadata(
      format: 'YUV',
      variant: f.label,
      bitDepth: 8,
      channels: 3,
      colorSpace: '${conv.matrix.name.toUpperCase()} YCbCr',
      compression: '无（裸采样数据）',
      // 只有 4:4:4 没有抽样损失。其余格式的色度分辨率低于亮度，
      // 上采样补不回丢掉的信息 —— 这是抽样造成的，不是编码造成的。
      isLossless: f.subX == 1 && f.subY == 1,
      extra: extra,
    );
  }
}
