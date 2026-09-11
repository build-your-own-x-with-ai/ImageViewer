/// PNG 的 `PLTE` 调色板与 `tRNS` 透明信息。
///
/// ## tRNS 是同一个 chunk 名下的三种完全不同的格式
///
/// 这是 PNG 里最容易读错的一块 —— `tRNS` 的内容取决于色彩类型：
///
/// ```
/// 类型 3（调色板）  N 个字节，第 i 个是第 i 号调色板项的 alpha
/// 类型 0（灰度）    2 个字节，一个 16 位灰度值；等于它的像素全透明
/// 类型 2（RGB）     6 个字节，三个 16 位值；完全等于它的像素全透明
/// 类型 4 / 6        禁止出现 —— 已经有 alpha 通道了
/// ```
///
/// 后两种是「关键色」式透明：**整个颜色**被判为透明，而不是逐像素带
/// alpha。GIF 的透明就是这个思路，PNG 保留它是为了让从 GIF 转过来的图
/// 不必升级成带 alpha 通道的类型 6（那会让文件大一截）。
///
/// 关键色比较有个坑：必须拿**原始位深下的采样值**去比，不能先缩放到
/// 8 位再比。16 位图里 0x1234 和 0x1256 缩放后都是 0x12，先缩放就会把
/// 不该透明的像素也判成透明。所以这里保留原值，缩放留到最后一步。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/png/png_types.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 调色板，已展开成便于直查的 RGBA 表。
class PngPalette {
  PngPalette._(this._rgba, this.entryCount);

  /// 长度 `entryCount * 4` 的 RGBA 表。alpha 默认 255，由 `tRNS` 覆盖。
  final Uint8List _rgba;

  /// 调色板项数。
  final int entryCount;

  /// 是否有任何一项不是全不透明。
  bool hasAlpha = false;

  int red(int i) => _rgba[i * 4];
  int green(int i) => _rgba[i * 4 + 1];
  int blue(int i) => _rgba[i * 4 + 2];
  int alpha(int i) => _rgba[i * 4 + 3];

  /// 解析 `PLTE`：每项 3 字节 RGB。
  factory PngPalette.parse(Uint8List data, {int offset = 0}) {
    if (data.length % 3 != 0) {
      throw ImageDecodeException(
        'PLTE 长度 ${data.length} 不是 3 的倍数，无法按 RGB 三元组切分',
        format: 'PNG',
        offset: offset,
      );
    }
    final int count = data.length ~/ 3;
    if (count == 0 || count > 256) {
      throw ImageDecodeException(
        'PLTE 项数 $count 非法，应在 1..256 之间',
        format: 'PNG',
        offset: offset,
      );
    }

    final Uint8List rgba = Uint8List(count * 4);
    for (int i = 0; i < count; i++) {
      rgba[i * 4] = data[i * 3];
      rgba[i * 4 + 1] = data[i * 3 + 1];
      rgba[i * 4 + 2] = data[i * 3 + 2];
      rgba[i * 4 + 3] = 255;
    }
    return PngPalette._(rgba, count);
  }

  /// 用 `tRNS` 覆盖各项的 alpha。
  ///
  /// `tRNS` 允许比调色板短 —— 未覆盖的项保持不透明。这让「只有前几项
  /// 需要透明」的常见情况不必写满 256 字节。反过来长于调色板则是错误。
  void applyTransparency(Uint8List data, {int offset = 0}) {
    if (data.length > entryCount) {
      throw ImageDecodeException(
        'tRNS 有 ${data.length} 项，超过调色板的 $entryCount 项',
        format: 'PNG',
        offset: offset,
      );
    }
    for (int i = 0; i < data.length; i++) {
      _rgba[i * 4 + 3] = data[i];
      if (data[i] != 255) {
        hasAlpha = true;
      }
    }
  }

  /// 校验索引在范围内。
  ///
  /// 越界索引是畸形 PNG 的常见形态，直接查表会读到别的项或抛
  /// RangeError，两者都不好排查。
  void checkIndex(int index) {
    if (index >= entryCount) {
      throw ImageDecodeException(
        '调色板索引 $index 越界：调色板只有 $entryCount 项',
        format: 'PNG',
      );
    }
  }
}

/// 灰度或 RGB 的关键色透明。
class PngColorKey {
  const PngColorKey({required this.gray, required this.red, required this.green, required this.blue});

  /// 灰度关键色的原始采样值；RGB 类型时为 `null`。
  final int? gray;

  /// RGB 关键色的原始采样值；灰度类型时为 `null`。
  final int? red;
  final int? green;
  final int? blue;

  /// 解析非调色板类型的 `tRNS`。
  factory PngColorKey.parse(
    Uint8List data,
    PngColorType colorType, {
    int offset = 0,
  }) {
    int read16(int i) => data[i] * 256 + data[i + 1];

    switch (colorType) {
      case PngColorType.grayscale:
        if (data.length != 2) {
          throw ImageDecodeException(
            '灰度图的 tRNS 应为 2 字节，实际 ${data.length}',
            format: 'PNG',
            offset: offset,
          );
        }
        return PngColorKey(
          gray: read16(0),
          red: null,
          green: null,
          blue: null,
        );

      case PngColorType.rgb:
        if (data.length != 6) {
          throw ImageDecodeException(
            'RGB 图的 tRNS 应为 6 字节，实际 ${data.length}',
            format: 'PNG',
            offset: offset,
          );
        }
        return PngColorKey(
          gray: null,
          red: read16(0),
          green: read16(2),
          blue: read16(4),
        );

      case PngColorType.palette:
      case PngColorType.grayscaleAlpha:
      case PngColorType.rgba:
        throw ImageDecodeException(
          '色彩类型 ${colorType.value}（${colorType.description}）'
          '不能用关键色式的 tRNS',
          format: 'PNG',
          offset: offset,
        );
    }
  }

  @override
  String toString() => gray != null
      ? 'PngColorKey(灰度 $gray)'
      : 'PngColorKey(RGB $red,$green,$blue)';
}
