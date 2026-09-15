import 'dart:async';
import 'dart:isolate';

// Uint8List 由 foundation 转出，不必再单独 import dart:typed_data。
import 'package:flutter/foundation.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_decoder.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_decoder.dart';
import 'package:image_viewer/src/codecs/png/png_decoder.dart';
import 'package:image_viewer/src/codecs/pnm/pnm_decoder.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_decoder.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_options.dart';
import 'package:image_viewer/src/core/decoder_registry.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 构造注册表。
///
/// 每次调用都新建 —— 解码器全是 `const` 无状态对象，构造代价可以忽略，
/// 而「不共享实例」让它能在 isolate 里安全地重新构造。
///
/// 注册顺序不影响正确性（魔数之间无歧义），但把 YUV 放最后是刻意的：
/// 它的 `canDecode` 恒为 false，永远不会命中，放最后也提醒读者这一点。
DecoderRegistry buildRegistry() => DecoderRegistry(const <ImageDecoder>[
      BmpDecoder(),
      PngDecoder(),
      JpegDecoder(),
      PnmDecoder(),
      YuvDecoder(),
    ]);

/// 解码一次的结果。
///
/// 把耗时单独带出来而不是塞回 [RgbaImage.metadata]，是因为解码器本身
/// 不计时（它是纯函数，不该关心时钟）。计时是调用方的职责。
class DecodeResult {
  const DecodeResult({required this.image, required this.duration});

  final RgbaImage image;
  final Duration duration;

  /// 把耗时并进元数据，供信息面板统一渲染。
  RgbaImage get imageWithTiming => RgbaImage(
        width: image.width,
        height: image.height,
        pixels: image.pixels,
        metadata: image.metadata.copyWith(decodeDuration: duration),
      );
}

/// 把字节解码成图像。
///
/// ## 为什么要跳 isolate
///
/// 一张 4000×3000 的 PNG 要跑 inflate + 反 filter，纯 Dart 实现可能要几百
/// 毫秒。在 UI 线程上做就是几十帧的卡顿。解码器是纯函数、入参出参都可跨
/// isolate 传输，天然适合丢出去 —— 这是分层设计的直接收益。
///
/// Web 上没有 isolate（`Isolate.run` 会抛），所以走同步路径。这也是可以
/// 接受的：Web 端本来就只能开用户手选的文件，卡一下比编译不过好。
Future<DecodeResult> decodeImage(Uint8List bytes) async {
  final Stopwatch sw = Stopwatch()..start();

  final RgbaImage image;
  if (kIsWeb) {
    // Web：没有 isolate，直接在当前线程解。
    image = buildRegistry().decode(bytes);
  } else {
    // 注意闭包里**重新构造**注册表而不是捕获外面的实例 ——
    // 捕获会把对象图一起搬过去，重建更省事也更清楚。
    image = await Isolate.run(() => buildRegistry().decode(bytes));
  }

  sw.stop();
  return DecodeResult(image: image, duration: sw.elapsed);
}

/// 用显式参数解码裸 YUV。
///
/// 单独一个函数而不是塞进 [decodeImage]，是因为 YUV 走的是
/// [ParameterizedImageDecoder]：它没有魔数，注册表嗅探不到它，
/// 只能由 UI 在用户填完参数对话框之后显式调用。
Future<DecodeResult> decodeYuv(Uint8List bytes, YuvOptions options) async {
  final Stopwatch sw = Stopwatch()..start();

  final RgbaImage image;
  if (kIsWeb) {
    image = const YuvDecoder().decodeWith(bytes, options);
  } else {
    image = await Isolate.run(
      () => const YuvDecoder().decodeWith(bytes, options),
    );
  }

  sw.stop();
  return DecodeResult(image: image, duration: sw.elapsed);
}

/// 这段字节是否有解码器认领。
///
/// UI 用它区分两种「打不开」：**没人认领**（可能是裸 YUV，值得提示用户
/// 试试手动指定参数）和**认领了但解码失败**（文件确实坏了）。
/// 两种情况给的建议完全不同，所以要分开。
bool hasDecoderFor(Uint8List bytes) => buildRegistry().sniff(bytes) != null;
