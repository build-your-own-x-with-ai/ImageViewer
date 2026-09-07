import 'dart:typed_data';

import 'package:image_viewer/src/core/rgba_image.dart';

/// 所有格式解码器的统一接口。
///
/// ## 刻意保持成纯函数
///
/// `Uint8List → RgbaImage`，不碰文件 IO，不碰 UI，不持有状态。
/// 这一条约束带来三个直接收益：
///
/// 1. **可单测** —— 测试里手写几十字节就能构造输入，不需要临时文件
/// 2. **可跨 isolate** —— 入参出参都是可传输类型，`Isolate.run` 直接能用
/// 3. **可复用** —— 同一个解码器在桌面读文件、在 Web 读 assets，自己不用知道
///
/// 所以 `lib/src/codecs/` 下的任何文件都**不允许** import `dart:io` 或
/// `package:flutter/*`。这条规则由 `docs/design.md` 的分层约定保证。
abstract class ImageDecoder {
  const ImageDecoder();

  /// 格式名，如 `'BMP'`。用于异常信息与信息面板。
  String get name;

  /// 常见扩展名，仅用于 UI 上的文件过滤与展示。
  ///
  /// **不用于格式判断** —— 那是 [canDecode] 的活。扩展名会撒谎。
  List<String> get extensions;

  /// 嗅探魔数，判断这段字节是否属于本格式。
  ///
  /// 必须只看文件头的若干字节，不做完整解析 —— 注册表会对每个解码器
  /// 依次调用它，代价要足够低。
  ///
  /// 实现时注意字节数不足的情况（空文件、只有两三个字节），
  /// 应返回 false 而不是抛异常。
  bool canDecode(Uint8List bytes);

  /// 解码为 RGBA8888。
  ///
  /// 失败时抛 [ImageDecodeException]（畸形输入）或
  /// [UnsupportedImageFeature]（格式合法但本项目未实现该特性）。
  /// 绝不允许返回一张"尽力而为"的错图。
  RgbaImage decode(Uint8List bytes);
}

/// 需要额外参数才能解码的格式。
///
/// 目前只有 YUV 属于此类：裸 YUV 流没有任何头部，宽高、平面布局、
/// 色彩空间全都无从得知，必须由用户指定。
///
/// 单独抽一个接口而不是给 [ImageDecoder.decode] 加个可选参数，
/// 是为了让"这个格式需要用户输入"这件事在类型上就是显式的 —— UI 看到
/// 它就知道要先弹参数对话框。
abstract class ParameterizedImageDecoder<TOptions> extends ImageDecoder {
  const ParameterizedImageDecoder();

  /// 用指定参数解码。
  RgbaImage decodeWith(Uint8List bytes, TOptions options);

  /// 默认参数。UI 用它初始化参数对话框。
  TOptions get defaultOptions;
}
