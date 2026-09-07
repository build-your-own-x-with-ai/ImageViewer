import 'dart:async';
import 'dart:ui' as ui;

import 'package:image_viewer/src/core/rgba_image.dart';

/// 把解码结果交给 GPU。
///
/// ## 这是「不使用解码库」这条约束的边界
///
/// `ui.decodeImageFromPixels` 名字里带 decode，但它**不解析任何格式** ——
/// 入参已经是排好的 RGBA8888 字节，它只负责上传纹理。真正会替我们干活的
/// 是 `ui.instantiateImageCodec`（那个认识 PNG/JPEG 的魔数），本项目一处
/// 都不用。
///
/// 换句话说：像素是我们自己算出来的，这里只是把算好的结果画到屏幕上。
/// 这也正是 [RgbaImage] 统一成 RGBA8888 的回报 —— 六种格式共用这一个出口。
Future<ui.Image> toUiImage(RgbaImage image) {
  final Completer<ui.Image> completer = Completer<ui.Image>();

  ui.decodeImageFromPixels(
    image.pixels,
    image.width,
    image.height,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );

  return completer.future;
}

/// 一张已经可以直接画的图，连同渲染时需要知道的信息。
///
/// 把 `ui.Image` 和 [RgbaImage] 绑在一起是有原因的：画布需要 `ui.Image`
/// 才能画，而像素探针需要 [RgbaImage] 才能读出某点的原始通道值。两者
/// 缺一不可，分开传就得在每个 widget 的参数表里写两遍。
class DisplayImage {
  const DisplayImage({
    required this.texture,
    required this.source,
    required this.hasTransparency,
  });

  /// 上传到 GPU 的纹理，交给 `RawImage` / `Canvas.drawImage` 用。
  final ui.Image texture;

  /// 原始解码结果。像素探针与信息面板从这里取值。
  final RgbaImage source;

  /// 是否含非全不透明像素。
  ///
  /// **预先算好而不是每帧现算**：`RgbaImage.hasTransparency` 要扫一遍整个
  /// 像素缓冲，4000×3000 就是 4800 万字节。画布每帧都问一次的话，一张大图
  /// 能把帧率拖到个位数。解码完算一次就够了 —— 像素不会自己变。
  final bool hasTransparency;

  int get width => source.width;
  int get height => source.height;

  /// 建一个 [DisplayImage]，顺带把纹理上传掉。
  static Future<DisplayImage> from(RgbaImage image) async {
    return DisplayImage(
      texture: await toUiImage(image),
      source: image,
      hasTransparency: image.hasTransparency,
    );
  }

  /// 释放 GPU 纹理。
  ///
  /// `ui.Image` 持有的是 GPU 侧内存，Dart 的 GC 管不到它。换图时不 dispose
  /// 旧的就是显存泄漏 —— 连开几十张大图能把显存吃光。
  void dispose() => texture.dispose();
}
