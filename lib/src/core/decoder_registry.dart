import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/image_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 按魔数把字节流分派给对应的解码器。
///
/// ## 为什么不看扩展名
///
/// 扩展名会撒谎 —— 从网上下载的 `.jpg` 里装着 PNG 是很常见的事，
/// 用户手动改名更常见。而每种格式的文件头都有明确的标识字节，
/// 这是权威依据。所以本类只做魔数嗅探，扩展名仅用于 UI 展示。
///
/// ## YUV 为什么不在这里
///
/// 裸 YUV 没有魔数 —— 它就是一堆像素字节，没有任何可识别的头部。
/// 它的 `canDecode` 恒返回 false，只能由用户在 UI 上显式选择并提供
/// 尺寸与格式参数。这是 [ParameterizedImageDecoder] 存在的原因。
class DecoderRegistry {
  DecoderRegistry(List<ImageDecoder> decoders)
      : _decoders = List<ImageDecoder>.unmodifiable(decoders);

  final List<ImageDecoder> _decoders;

  /// 已注册的解码器，按注册顺序。
  List<ImageDecoder> get decoders => _decoders;

  /// 找出能处理这段字节的解码器，找不到返回 null。
  ///
  /// 按注册顺序返回第一个命中的。魔数之间不应有歧义，所以顺序理论上
  /// 无关紧要；真出现歧义说明某个 `canDecode` 写得太宽松了。
  ImageDecoder? sniff(Uint8List bytes) {
    for (final ImageDecoder d in _decoders) {
      if (d.canDecode(bytes)) {
        return d;
      }
    }
    return null;
  }

  /// 嗅探并解码。
  ///
  /// 识别不出格式时抛 [UnknownImageFormat]，异常信息里附上文件头的
  /// 十六进制转储 —— 教学场景下这比干巴巴一句"不支持"有用得多，
  /// 学生能直接拿这几个字节去查格式规范。
  RgbaImage decode(Uint8List bytes) {
    if (bytes.isEmpty) {
      throw UnknownImageFormat('文件为空');
    }
    final ImageDecoder? d = sniff(bytes);
    if (d == null) {
      throw UnknownImageFormat(
        '没有解码器认领这个文件。文件头：${hexPreview(bytes)}\n'
        '已注册：${_decoders.map((ImageDecoder e) => e.name).join(', ')}\n'
        '（裸 YUV 流没有文件头，需要在界面上手动指定格式与尺寸）',
      );
    }
    return d.decode(bytes);
  }

  /// 把开头若干字节转成 `48 65 6C 6C 6F` 形式，附可打印字符对照。
  ///
  /// 出现在无法识别格式的异常信息里。
  static String hexPreview(Uint8List bytes, {int count = 16}) {
    final int n = bytes.length < count ? bytes.length : count;
    final StringBuffer hex = StringBuffer();
    final StringBuffer ascii = StringBuffer();
    for (int i = 0; i < n; i++) {
      final int b = bytes[i];
      hex.write(b.toRadixString(16).toUpperCase().padLeft(2, '0'));
      if (i != n - 1) {
        hex.write(' ');
      }
      // 可打印 ASCII 直接显示，其余用点代替。
      ascii.write(b >= 0x20 && b < 0x7F ? String.fromCharCode(b) : '.');
    }
    return '$hex  |$ascii|';
  }
}
