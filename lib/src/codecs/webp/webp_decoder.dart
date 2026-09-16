/// WebP 解码器：从 RIFF 容器分派到两个互不相干的编解码器。
///
/// ## 一个容器，两个格式
///
/// WebP 名下其实住着两个几乎没有共同点的编解码器：
///
/// | | VP8L（无损） | VP8（有损） |
/// |---|---|---|
/// | 亲戚 | PNG | JPEG |
/// | 熵编码 | Huffman | 布尔算术编码 |
/// | 变换 | 预测器 / 颜色 / 减绿 / 调色板 | DCT |
/// | 色彩 | ARGB 直存 | YUV 4:2:0 |
/// | 透明 | 自带 alpha 通道 | 没有，要靠单独的 `ALPH` chunk |
///
/// 它们共享的只有两样东西：外面这层 RIFF 容器，和最后吐出来的 RGBA。所以这个
/// 文件很薄 —— 它只负责认出「这是哪一种」，然后把活交出去。
///
/// ## 为什么有损图要透明就必须用扩展布局
///
/// VP8 是从视频编码器来的，视频没有透明度的概念，所以 VP8 的码流里根本没有
/// alpha 的位置。WebP 的解法是把透明通道拆出来单独存成一个 `ALPH` chunk ——
/// 而顶层要放得下多个 chunk，就必须是 `VP8X` 扩展布局。
///
/// VP8L 不需要这一套，它的 ARGB 里本来就有 A。所以「透明的无损 WebP」可以是
/// 最简单的三 chunk 布局，「透明的有损 WebP」至少五个 chunk。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/webp/webp_riff.dart';
import 'package:image_viewer/src/codecs/webp/webp_types.dart';
import 'package:image_viewer/src/codecs/webp/webp_vp8l.dart';
import 'package:image_viewer/src/codecs/webp/webp_vp8l_transform.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// WebP 解码器。
class WebpDecoder extends ImageDecoder {
  const WebpDecoder();

  @override
  String get name => kWebpFormat;

  @override
  List<String> get extensions => const <String>['webp'];

  @override
  bool canDecode(Uint8List bytes) => WebpContainer.looksLikeWebp(bytes);

  @override
  RgbaImage decode(Uint8List bytes) {
    final WebpContainer container = WebpContainer.parse(bytes);

    // 动画的第一帧藏在 ANMF 里，不在顶层 —— 顶层只有 ANIM 参数。
    // 先明确拒掉，比让 imageChunk 返回 null 再报「没有图像数据」清楚。
    if (container.vp8x?.hasAnimation ?? false) {
      throw UnsupportedImageFeature(
        '这是一张 WebP 动画（含 ANIM/ANMF），暂只支持静态图',
        format: kWebpFormat,
      );
    }

    final WebpChunk? image = container.imageChunk;
    if (image == null) {
      throw ImageDecodeException(
        '容器里没有 VP8L 或 VP8 图像数据，只有 '
        '${container.chunks.map((WebpChunk c) => c.tag.trim()).join('、')}',
        format: kWebpFormat,
      );
    }

    if (image.tag == kChunkVp8l) {
      return _decodeLossless(container, image);
    }
    throw UnsupportedImageFeature(
      'VP8 有损解码尚未实现（阶段 4 进行中）',
      format: kWebpFormat,
      offset: image.payloadOffset,
    );
  }

  RgbaImage _decodeLossless(WebpContainer container, WebpChunk chunk) {
    final Vp8lResult out = decodeVp8l(chunk.payload);

    // VP8X 的画布尺寸和码流自己的尺寸是**两个数**。静态图它们必须相等；
    // 不校验的话，一个畸形文件可以在 VP8X 里声明 1×1、在 VP8L 里声明
    // 16384×16384，上层照着 VP8X 分配缓冲、照着 VP8L 写像素。
    final Vp8xInfo? vp8x = container.vp8x;
    if (vp8x != null &&
        (vp8x.canvasWidth != out.width || vp8x.canvasHeight != out.height)) {
      throw ImageDecodeException(
        'VP8X 画布 ${vp8x.canvasWidth}x${vp8x.canvasHeight} 与 VP8L 码流 '
        '${out.width}x${out.height} 不一致',
        format: kWebpFormat,
        offset: chunk.payloadOffset,
      );
    }

    return RgbaImage(
      width: out.width,
      height: out.height,
      pixels: argbToRgba(out.pixels),
      metadata: ImageMetadata(
        format: kWebpFormat,
        variant: 'VP8L 无损',
        bitDepth: 8,
        channels: 4,
        colorSpace: 'sRGB',
        compression: 'LZ77 + Huffman',
        isLossless: true,
        extra: <String, Object>{
          '布局': container.isExtended ? 'VP8X 扩展' : '简单',
          'alpha 提示位': out.hasAlpha ? '置位' : '未置位',
          '变换': out.features.transforms.isEmpty
              ? '无'
              : out.features.transforms
                  .map((Vp8lTransformType t) => t.label)
                  .join(' → '),
          if (out.features.predictorModes.isNotEmpty)
            '预测器模式': out.features.predictorModes.join(', '),
          '颜色缓存': out.features.usesColorCache
              ? '${1 << out.features.colorCacheBits} 槽'
                  '（${out.features.colorCacheBits} 位）'
              : '未启用',
          '码表组': out.features.usesMetaHuffman
              ? '${out.features.huffmanGroups} 组（meta-Huffman 熵图像）'
              : '1 组',
          'chunk': container.chunks
              .map((WebpChunk c) => c.tag.trim())
              .join('、'),
          if (container.declaredSize + 8 != container.actualSize)
            'RIFF 长度': '声明 ${container.declaredSize + 8}，'
                '实际 ${container.actualSize}',
        },
      ),
    );
  }
}

/// `0xAARRGGBB` → RGBA 字节直排。
///
/// 通道顺序在这里换向：VP8L 内部按规范用 ARGB（A 在高位），`RgbaImage` 要的是
/// R、G、B、A 四个字节挨着放。用除法和取模而不是移位 —— `Uint32List` 的值能
/// 到 0xFFFFFFFF，超过 32 位**有符号**范围，而 Dart 编到 JS 时位运算是 32 位
/// 有符号的。这个坑项目已经踩过一次（见实现记录 3.11 节的 `pixelAt`）。
Uint8List argbToRgba(Uint32List argb) {
  final Uint8List out = Uint8List(argb.length * 4);
  for (int i = 0; i < argb.length; i++) {
    final int v = argb[i];
    final int j = i * 4;
    out[j] = argbR(v);
    out[j + 1] = argbG(v);
    out[j + 2] = argbB(v);
    out[j + 3] = argbA(v);
  }
  return out;
}

/// 供注册表使用的单例。
const WebpDecoder webpDecoder = WebpDecoder();
