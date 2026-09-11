import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// 单幅图像的宽高上限。
///
/// 不是技术限制，是**安全阀**。畸形文件可以声明 65535×65535，乘出来
/// 42 亿像素 ×4 字节 = 17GB，直接把进程撑死。真实图片不会这么大，
/// 所以宁可拒绝也不要 OOM。
const int kMaxImageDimension = 65535;

/// 单幅图像的总像素上限（约 1.6 亿，够 8K 图有余）。
const int kMaxImagePixels = 16384 * 10000;

/// 解码结果的统一表示：RGBA8888 直排。
///
/// ## 为什么所有格式都归一到 RGBA8888
///
/// 灰度图存成 RGBA 会浪费 4 倍内存，调色板图更浪费。但收益是上层
/// （UI、像素探针、直方图、测试断言、`ui.decodeImageFromPixels`）
/// 只需面对**一种**像素布局。
///
/// 如果保留原生布局，就得为"1 位灰度""8 位调色板""16 位 RGB"等等
/// 各写一遍取像素的逻辑，还要在每个上层组件里分派。教学项目里这个
/// 简化是值得的 —— 复杂度应该花在格式解析本身，而不是布局适配。
///
/// 原始的位深、色彩类型等信息不会丢，都保留在 [metadata] 里给信息面板
/// 和教学模式用。
class RgbaImage {
  RgbaImage({
    required this.width,
    required this.height,
    required this.pixels,
    this.metadata = const ImageMetadata(),
  }) {
    if (pixels.length != width * height * 4) {
      throw ImageDecodeException(
        '内部错误：像素缓冲长度 ${pixels.length} 与尺寸 ${width}x$height '
        '不符（应为 ${width * height * 4}）',
      );
    }
  }

  /// 按尺寸分配一张全透明黑的图（所有字节为 0）。
  factory RgbaImage.alloc(
    int width,
    int height, {
    ImageMetadata metadata = const ImageMetadata(),
  }) {
    validateDimensions(width, height);
    return RgbaImage(
      width: width,
      height: height,
      pixels: Uint8List(width * height * 4),
      metadata: metadata,
    );
  }

  final int width;
  final int height;

  /// 像素数据，长度恒为 `width * height * 4`，字节顺序 R, G, B, A。
  ///
  /// 行优先直排，无行填充 —— 各格式自己的行对齐（BMP 的 4 字节对齐、
  /// PNG 的隔行扫描）都在解码器内部消化掉了。
  final Uint8List pixels;

  /// 格式相关的附加信息，供信息面板与教学模式使用。
  final ImageMetadata metadata;

  /// 校验尺寸合法性。解码器读到宽高后应立刻调用。
  ///
  /// 这是**不信任输入**原则的关键一环：宽高来自文件，必须当作恶意值对待。
  static void validateDimensions(int width, int height, {String? format}) {
    if (width <= 0 || height <= 0) {
      throw ImageDecodeException(
        '非法尺寸 ${width}x$height：宽高必须为正数',
        format: format,
      );
    }
    if (width > kMaxImageDimension || height > kMaxImageDimension) {
      throw ImageDecodeException(
        '尺寸 ${width}x$height 超出上限 $kMaxImageDimension',
        format: format,
      );
    }
    // 先除后乘避免中间结果溢出。
    if (height > kMaxImagePixels ~/ width) {
      throw ImageDecodeException(
        '像素总数 ${width}x$height 超出上限 $kMaxImagePixels，'
        '拒绝分配以避免内存耗尽',
        format: format,
      );
    }
  }

  /// 取 (x, y) 处的像素，返回 `0xRRGGBBAA` 打包值。
  ///
  /// 供像素探针与测试断言使用，不用于解码热路径。
  int pixelAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('坐标 ($x, $y) 超出图像范围 ${width}x$height');
    }
    final int i = (y * width + x) * 4;
    // 用乘法而不是 `<< 24`：Web 上位运算是 32 位**有符号**的，红色分量
    // ≥ 0x80 时左移 24 位会得到负数，`pixelAt(...) == 0xFF0000FF` 这样的
    // 断言在桌面上通过、在 Web 上失败。见 implementation.md 第 3.11 节。
    return pixels[i] * 16777216 +
        pixels[i + 1] * 65536 +
        pixels[i + 2] * 256 +
        pixels[i + 3];
  }

  /// 取 (x, y) 处的四个通道，返回 `[r, g, b, a]`。
  List<int> channelsAt(int x, int y) {
    if (x < 0 || x >= width || y < 0 || y >= height) {
      throw RangeError('坐标 ($x, $y) 超出图像范围 ${width}x$height');
    }
    final int i = (y * width + x) * 4;
    return <int>[pixels[i], pixels[i + 1], pixels[i + 2], pixels[i + 3]];
  }

  /// 写入 (x, y) 处的像素。解码器组装图像时用。
  void setPixel(int x, int y, int r, int g, int b, int a) {
    final int i = (y * width + x) * 4;
    pixels[i] = r;
    pixels[i + 1] = g;
    pixels[i + 2] = b;
    pixels[i + 3] = a;
  }

  /// 是否存在半透明或全透明像素。
  ///
  /// UI 据此决定是否画棋盘格背景。
  bool get hasTransparency {
    for (int i = 3; i < pixels.length; i += 4) {
      if (pixels[i] != 255) {
        return true;
      }
    }
    return false;
  }

  @override
  String toString() => 'RgbaImage(${width}x$height, ${metadata.format})';
}

/// 格式相关的元数据。
///
/// 用具名字段 + 自由 [extra] 的组合，而不是为六种格式各造一个元数据类：
/// 具名字段覆盖所有格式都有的共性（尺寸、位深），[extra] 装格式特有的
/// 东西（JPEG 的采样因子、PNG 的 filter 用量统计、WebP 的编码类型）。
///
/// 信息面板直接遍历 [extra] 渲染，加新字段不需要改 UI。
class ImageMetadata {
  const ImageMetadata({
    this.format = '未知',
    this.variant,
    this.bitDepth,
    this.channels,
    this.colorSpace,
    this.compression,
    this.isLossless,
    this.decodeDuration,
    this.extra = const <String, Object>{},
  });

  /// 格式名，如 `'BMP'`、`'PNG'`。
  final String format;

  /// 子类型，如 `'BITMAPINFOHEADER'`、`'渐进式'`、`'VP8L 无损'`。
  final String? variant;

  /// 原始位深（每通道），归一到 RGBA8888 之前的值。
  final int? bitDepth;

  /// 原始通道数。
  final int? channels;

  /// 色彩空间，如 `'sRGB'`、`'YCbCr (BT.601)'`、`'调色板'`。
  final String? colorSpace;

  /// 压缩方式，如 `'无'`、`'RLE8'`、`'deflate'`、`'DCT'`。
  final String? compression;

  /// 是否无损。
  final bool? isLossless;

  /// 解码耗时。由上层调用方填入，解码器自己不计时。
  final Duration? decodeDuration;

  /// 格式特有的键值对，按插入顺序显示在信息面板上。
  final Map<String, Object> extra;

  /// 复制并覆盖部分字段。上层加解码耗时时用。
  ImageMetadata copyWith({
    String? format,
    String? variant,
    int? bitDepth,
    int? channels,
    String? colorSpace,
    String? compression,
    bool? isLossless,
    Duration? decodeDuration,
    Map<String, Object>? extra,
  }) {
    return ImageMetadata(
      format: format ?? this.format,
      variant: variant ?? this.variant,
      bitDepth: bitDepth ?? this.bitDepth,
      channels: channels ?? this.channels,
      colorSpace: colorSpace ?? this.colorSpace,
      compression: compression ?? this.compression,
      isLossless: isLossless ?? this.isLossless,
      decodeDuration: decodeDuration ?? this.decodeDuration,
      extra: extra ?? this.extra,
    );
  }

  /// 摊平成有序键值对，供信息面板直接渲染。
  Map<String, String> toDisplayMap() {
    final Map<String, String> m = <String, String>{'格式': format};
    if (variant != null) {
      m['子类型'] = variant!;
    }
    if (bitDepth != null) {
      m['原始位深'] = '$bitDepth 位/通道';
    }
    if (channels != null) {
      m['通道数'] = '$channels';
    }
    if (colorSpace != null) {
      m['色彩空间'] = colorSpace!;
    }
    if (compression != null) {
      m['压缩'] = compression!;
    }
    if (isLossless != null) {
      m['有损/无损'] = isLossless! ? '无损' : '有损';
    }
    if (decodeDuration != null) {
      m['解码耗时'] = '${decodeDuration!.inMicroseconds / 1000} ms';
    }
    for (final MapEntry<String, Object> e in extra.entries) {
      m[e.key] = '${e.value}';
    }
    return m;
  }
}
