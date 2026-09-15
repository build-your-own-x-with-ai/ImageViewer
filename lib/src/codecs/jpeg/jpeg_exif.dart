/// APP1 里的 EXIF 方向标记：解析与应用。
///
/// ## 为什么解码器必须管这件事
///
/// 手机竖着拍照时，传感器仍然按它固定的方向出像素 —— 存进文件的是一张躺倒
/// 的图，再写一个 EXIF 方向标记说「显示时请转 90°」。不理这个标记，竖拍的
/// 照片就全是横的。这是唯一一处**像素之外的信息会改变画面**的地方。
///
/// ## EXIF 是一个套在 JPEG 里的 TIFF 文件
///
/// APP1 段的载荷是 `'Exif' 00 00` 加一个完整的 TIFF 结构：字节序标记、
/// 魔数、IFD 偏移表。于是有两个陷阱：
///
///   * **字节序是运行时才知道的** —— `'II'` 小端、`'MM'` 大端，同一份代码
///     两种读法。这也是本项目里唯一需要动态字节序的地方。
///   * **所有偏移都相对 TIFF 头**（也就是载荷的第 6 字节），不是相对文件、
///     也不是相对段。算错基准会读到一堆看似合理的垃圾。
///
/// ## 坏 EXIF 不该毁掉一张好图
///
/// EXIF 是纯元数据，跟像素解码毫无关系。所以这里所有函数遇到畸形结构一律
/// **返回 null 而不抛异常** —— 相机固件写坏 EXIF 的情况不罕见，为此拒绝
/// 打开一张本来能解的图是不划算的。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// EXIF 的方向标记。
///
/// 八个取值的编排不是「四种旋转 × 是否镜像」那么直白 —— 规范的定义方式是
/// 「存储的第 0 行显示在哪一边、第 0 列显示在哪一边」，两两组合出八种。
///
/// 但这八种恰好都能拆成「先可选转置，再可选左右翻、再可选上下翻」，也就是
/// `2 × 2 × 2`。这不是巧合：这三个操作生成的正是正方形的二面体群 D4，而
/// EXIF 的八种取值就是 D4 的全部元素。拆开之后八个分支塌成一个循环，
/// 见 [applyOrientation]。
enum JpegOrientation {
  /// 1：原样。
  normal(1, false, false, false, '正常'),

  /// 2：左右镜像。
  flipHorizontal(2, false, true, false, '水平镜像'),

  /// 3：旋转 180°。
  rotate180(3, false, true, true, '旋转 180°'),

  /// 4：上下镜像。
  flipVertical(4, false, false, true, '垂直镜像'),

  /// 5：沿主对角线镜像（转置）。
  transpose(5, true, false, false, '转置'),

  /// 6：顺时针 90°。竖着拿手机拍照最常见的一个。
  rotate90(6, true, true, false, '顺时针 90°'),

  /// 7：沿副对角线镜像。
  transverse(7, true, true, true, '副对角线镜像'),

  /// 8：逆时针 90°。
  rotate270(8, true, false, true, '逆时针 90°');

  const JpegOrientation(
    this.exifValue,
    this.swapsDimensions,
    this.flipX,
    this.flipY,
    this.label,
  );

  /// EXIF 里的原始数值（1..8）。
  final int exifValue;

  /// 是否需要转置。转置同时意味着输出的宽高互换。
  final bool swapsDimensions;

  /// 转置之后是否左右翻。
  final bool flipX;

  /// 转置之后是否上下翻。
  final bool flipY;

  /// 信息面板上显示的名字。
  final String label;
}

/// 把 EXIF 里的原始数值换成枚举。越界或 0 返回 null。
JpegOrientation? orientationFromExif(int value) {
  for (final JpegOrientation o in JpegOrientation.values) {
    if (o.exifValue == value) {
      return o;
    }
  }
  return null;
}

/// EXIF 方向标记的 TIFF tag 号。
const int _tagOrientation = 0x0112;

/// APP1 载荷开头的 `'Exif' 00 00`。
const List<int> _exifTag = <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00];

/// TIFF 头相对 APP1 载荷起点的偏移。
const int _tiffBase = 6;

/// 从 APP1 段载荷里取方向标记。
///
/// [data] 是段载荷（不含长度字节）。不是 EXIF 段（比如装 XMP 的那种 APP1）、
/// 结构畸形、或者根本没写方向标记时返回 null，调用方按 [JpegOrientation.normal]
/// 处理即可。
///
/// 只走 IFD0。方向标记按规范就在这一层，IFD1 里的是缩略图的方向，跟主图无关；
/// MakerNote 那类嵌套 IFD 一概不进 —— 递归解析一份来源不可信的偏移表，风险
/// 远大于收益。
JpegOrientation? parseExifOrientation(Uint8List data) {
  if (data.length < _tiffBase + 8) {
    return null;
  }
  for (int i = 0; i < _exifTag.length; i++) {
    if (data[i] != _exifTag[i]) {
      return null;
    }
  }

  // 字节序标记：'II' 小端，'MM' 大端。这两个字母来自 Intel 和 Motorola。
  final int b0 = data[_tiffBase];
  final int b1 = data[_tiffBase + 1];
  final bool little;
  if (b0 == 0x49 && b1 == 0x49) {
    little = true;
  } else if (b0 == 0x4D && b1 == 0x4D) {
    little = false;
  } else {
    return null;
  }

  // 魔数 42。它的作用就是验证字节序判断对不对 —— 读反了会得到 0x2A00。
  if (_u16(data, _tiffBase + 2, little) != 42) {
    return null;
  }

  final int ifdOffset = _u32(data, _tiffBase + 4, little);
  return _findOrientation(data, ifdOffset, little);
}

/// 在 IFD0 里找方向标记。
///
/// 目录布局是「2 字节条目数 + N × 12 字节条目 + 4 字节下一个 IFD 的偏移」，
/// 每个条目是 `tag(2) type(2) count(4) value/offset(4)`。
JpegOrientation? _findOrientation(Uint8List data, int ifdOffset, bool little) {
  // IFD 不可能落在 TIFF 头（8 字节）之内 —— 这种偏移只能是坏数据。
  if (ifdOffset < 8) {
    return null;
  }
  final int base = _tiffBase + ifdOffset;
  if (base < 0 || base + 2 > data.length) {
    return null;
  }
  final int count = _u16(data, base, little);
  for (int i = 0; i < count; i++) {
    final int entry = base + 2 + i * 12;
    if (entry + 12 > data.length) {
      // 条目数声明得比实际字节多。已经扫过的条目仍然有效，所以不是抛异常
      // 而是就此收手。
      return null;
    }
    if (_u16(data, entry, little) != _tagOrientation) {
      continue;
    }
    final int type = _u16(data, entry + 2, little);
    if (_u32(data, entry + 4, little) != 1) {
      return null;
    }
    // 值不超过 4 字节时直接放在条目里，而且是**左对齐**的 —— count=1 的
    // SHORT 占前两个字节，后两个是填充。所以这里必须按 2 字节读：整个
    // 读成 u32 再取低位，在大端文件上会拿到左移 16 位后的值。
    final int at = entry + 8;
    switch (type) {
      case 3: // SHORT，规范规定的类型
        return orientationFromExif(_u16(data, at, little));
      case 1: // BYTE
        return orientationFromExif(data[at]);
      case 4: // LONG
        return orientationFromExif(_u32(data, at, little));
      default:
        // 见过写成 UNDEFINED 或 RATIONAL 的，一律当没写。
        return null;
    }
  }
  return null;
}

int _u16(Uint8List d, int at, bool little) =>
    little ? d[at] | (d[at + 1] << 8) : (d[at] << 8) | d[at + 1];

/// 读 32 位。用乘法而不是 `<<` —— Web 上 `d[at] << 24` 会溢出成负数。
int _u32(Uint8List d, int at, bool little) => little
    ? d[at] +
        d[at + 1] * 0x100 +
        d[at + 2] * 0x10000 +
        d[at + 3] * 0x1000000
    : d[at] * 0x1000000 +
        d[at + 1] * 0x10000 +
        d[at + 2] * 0x100 +
        d[at + 3];

/// 按 [orientation] 重排 RGBA 像素。
///
/// [pixels] 长度须为 `width * height * 4`。返回的新缓冲区尺寸是
/// `swapsDimensions ? height × width : width × height` —— 调用方要自己按
/// [JpegOrientation.swapsDimensions] 把宽高换过来。
///
/// [JpegOrientation.normal] 时原样返回同一个对象，不复制。
///
/// ## 八种取值的目标→源映射
///
/// 记源尺寸 `sw × sh`，目标坐标 `(dx, dy)`：
///
/// | 值 | 源坐标 |
/// |----|--------|
/// | 1  | `(dx, dy)` |
/// | 2  | `(sw-1-dx, dy)` |
/// | 3  | `(sw-1-dx, sh-1-dy)` |
/// | 4  | `(dx, sh-1-dy)` |
/// | 5  | `(dy, dx)` |
/// | 6  | `(dy, sh-1-dx)` |
/// | 7  | `(sw-1-dy, sh-1-dx)` |
/// | 8  | `(sw-1-dy, dx)` |
///
/// 下面那个循环就是这张表的合并写法：先按 `flipX`/`flipY` 在目标空间里翻，
/// 再按 `swapsDimensions` 决定要不要把两个下标对调。
Uint8List applyOrientation(
  Uint8List pixels,
  int width,
  int height,
  JpegOrientation orientation,
) {
  if (pixels.length != width * height * 4) {
    throw ImageDecodeException(
      '像素缓冲 ${pixels.length} 字节，与 $width×$height 不符',
      format: 'JPEG',
    );
  }
  if (orientation == JpegOrientation.normal) {
    return pixels;
  }

  final bool swap = orientation.swapsDimensions;
  final int dw = swap ? height : width;
  final int dh = swap ? width : height;
  final Uint8List out = Uint8List(pixels.length);
  int o = 0;
  for (int dy = 0; dy < dh; dy++) {
    final int iy = orientation.flipY ? dh - 1 - dy : dy;
    for (int dx = 0; dx < dw; dx++) {
      final int ix = orientation.flipX ? dw - 1 - dx : dx;
      final int sx = swap ? iy : ix;
      final int sy = swap ? ix : iy;
      final int s = (sy * width + sx) * 4;
      out[o] = pixels[s];
      out[o + 1] = pixels[s + 1];
      out[o + 2] = pixels[s + 2];
      out[o + 3] = pixels[s + 3];
      o += 4;
    }
  }
  return out;
}
