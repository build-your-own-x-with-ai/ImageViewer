import 'package:image_viewer/src/codecs/yuv/yuv_color.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_format.dart';

/// 解码一份裸 YUV 数据所需的全部参数。
///
/// ## 为什么 YUV 需要这个而其他格式不需要
///
/// 别的格式都自带头部：BMP 有 `BITMAPFILEHEADER`，PNG 有 `IHDR`，
/// 连最简单的 PNM 也有一行 `P6 2 2 255`。裸 YUV **什么都没有** ——
/// 文件里就是采样值本身，第一个字节就是第一个像素的亮度。
///
/// 所以宽、高、格式、矩阵、范围这五个参数只能由外部告知。猜是猜不出来的：
/// 同一份 6912 字节的数据既可以是 96x48 的 I420，也可以是 48x48 的 YUY2，
/// 两种解释都完全合法。
///
/// UI 上对应一个参数对话框，本类就是那个对话框的模型。
class YuvOptions {
  const YuvOptions({
    required this.width,
    required this.height,
    this.format = YuvFormat.i420,
    this.matrix = YuvMatrix.bt601,
    this.range = YuvRange.limited,
    this.frameIndex = 0,
  });

  /// 空参数，用于给 UI 预填 —— 尺寸为 0 表示「还没填」。
  ///
  /// 默认值挑的是最常见的组合：I420 + BT.601 + limited range，这也是
  /// FFmpeg `-pix_fmt yuv420p` 的默认输出。
  static const YuvOptions empty = YuvOptions(width: 0, height: 0);

  final int width;
  final int height;
  final YuvFormat format;
  final YuvMatrix matrix;
  final YuvRange range;

  /// 要解第几帧，从 0 开始。
  ///
  /// 裸 YUV 文件常常是多帧视频转出来的（`ffmpeg -i in.mp4 out.yuv` 就会
  /// 把所有帧首尾相接写成一个文件）。帧与帧之间没有任何分隔标记，只能靠
  /// 「帧大小 × 帧号」算偏移 —— 支持这件事的成本几乎为零，不支持反而奇怪。
  final int frameIndex;

  /// 参数是否已填完整。
  bool get isComplete => width > 0 && height > 0;

  /// 一帧占多少字节。
  int get frameSize => format.frameSize(width, height);

  /// 本帧数据在文件里的起始偏移。
  int get byteOffset => frameSize * frameIndex;

  /// 给定文件长度，里面有多少帧完整数据。
  int frameCountIn(int byteLength) {
    final int size = frameSize;
    if (size <= 0) {
      return 0;
    }
    return byteLength ~/ size;
  }

  YuvOptions copyWith({
    int? width,
    int? height,
    YuvFormat? format,
    YuvMatrix? matrix,
    YuvRange? range,
    int? frameIndex,
  }) =>
      YuvOptions(
        width: width ?? this.width,
        height: height ?? this.height,
        format: format ?? this.format,
        matrix: matrix ?? this.matrix,
        range: range ?? this.range,
        frameIndex: frameIndex ?? this.frameIndex,
      );

  @override
  String toString() => 'YuvOptions(${width}x$height, ${format.label}, '
      '${matrix.name}, ${range.name}, 第 $frameIndex 帧)';

  @override
  bool operator ==(Object other) =>
      other is YuvOptions &&
      other.width == width &&
      other.height == height &&
      other.format == format &&
      other.matrix == matrix &&
      other.range == range &&
      other.frameIndex == frameIndex;

  @override
  int get hashCode =>
      Object.hash(width, height, format, matrix, range, frameIndex);
}
