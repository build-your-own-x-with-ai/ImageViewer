/// 解码过程中的异常类型。
///
/// 设计原则：**任何畸形输入都必须抛出带明确信息的异常**，绝不允许
/// 崩溃（RangeError 之类的底层错误）或静默产出一张错图。前者对用户
/// 不友好，后者更糟 —— 会让 bug 一直藏着。
///
/// 所以解码器里每一处读取都要先做边界检查，而不是依赖 Dart 数组越界。
library;

/// 图像解码失败。
class ImageDecodeException implements Exception {
  ImageDecodeException(this.message, {this.format, this.offset});

  /// 人类可读的失败原因。
  final String message;

  /// 出错时正在解析的格式名，如 `'BMP'`。可能为空（格式尚未识别时）。
  final String? format;

  /// 出错的字节偏移，便于用 hex 编辑器直接跳过去看。
  final int? offset;

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('图像解码失败');
    if (format != null && format!.isNotEmpty) {
      sb.write('[$format]');
    }
    sb.write('：$message');
    if (offset != null) {
      sb.write('（偏移 $offset / 0x${offset!.toRadixString(16)}）');
    }
    return sb.toString();
  }
}

/// 文件格式合法，但用到了本项目尚未实现的特性。
///
/// 与 [ImageDecodeException] 区分开是有意的：这个异常说明"文件没问题，
/// 是我们不支持"，UI 上应该给出不同的提示文案。
class UnsupportedImageFeature extends ImageDecodeException {
  UnsupportedImageFeature(super.message, {super.format, super.offset});

  @override
  String toString() {
    final StringBuffer sb = StringBuffer('暂不支持的特性');
    if (format != null && format!.isNotEmpty) {
      sb.write('[$format]');
    }
    sb.write('：$message');
    if (offset != null) {
      sb.write('（偏移 $offset）');
    }
    return sb.toString();
  }
}

/// 无法识别的文件格式（所有解码器的魔数嗅探都没命中）。
class UnknownImageFormat extends ImageDecodeException {
  UnknownImageFormat(super.message);

  @override
  String toString() => '无法识别的图像格式：$message';
}
