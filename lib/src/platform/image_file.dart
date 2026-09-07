import 'dart:typed_data';

/// 一份待解码的图像数据及其来源信息。
///
/// ## 为什么不直接传路径
///
/// Web 上**没有路径**。`file_selector` 在 Web 端返回的是内存里的字节，
/// 浏览器出于安全考虑不会把真实路径交给页面。如果 UI 层以路径为核心，
/// Web 就得单独走一条分支。
///
/// 所以这里反过来：字节是必需的，路径是可选的。六个平台共用同一条
/// 加载 → 解码 → 显示的链路，路径退化成「有就显示，没有就只显示文件名」
/// 的展示字段。这也跟解码器的入口签名（`Uint8List → RgbaImage`）对齐。
class ImageFile {
  const ImageFile({
    required this.name,
    required this.bytes,
    this.path,
    this.source = ImageFileSource.picker,
  });

  /// 文件名（含扩展名），用于标题栏显示。各平台都拿得到。
  final String name;

  /// 文件内容。这是解码器唯一需要的东西。
  final Uint8List bytes;

  /// 完整路径。Web 上恒为 null，其余平台通常有。
  ///
  /// 仅用于展示与「在文件夹中显示」一类操作，**不参与解码**。
  final String? path;

  /// 从哪来的。UI 据此决定是否显示「重新加载」之类的操作。
  final ImageFileSource source;

  /// 扩展名（小写，不含点）。取不到时返回空串。
  ///
  /// 只用于 UI 展示与选择器的过滤条件 —— 格式判断一律靠魔数嗅探。
  String get extension {
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  /// 人类可读的大小，如 `1.2 MB`。
  String get sizeLabel => formatByteSize(bytes.length);

  /// 把字节数格式化成人类可读的形式。
  ///
  /// 用 1024 进制并标 KB/MB —— 跟各家文件管理器的显示习惯一致。
  static String formatByteSize(int bytes) {
    if (bytes < 1024) {
      return '$bytes B';
    }
    if (bytes < 1024 * 1024) {
      return '${(bytes / 1024).toStringAsFixed(1)} KB';
    }
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  @override
  String toString() => 'ImageFile($name, ${bytes.length} 字节, $source)';
}

/// 图像数据的来源。
enum ImageFileSource {
  /// 系统文件选择对话框。各平台通用。
  picker('文件选择器'),

  /// 自写的目录浏览侧栏。只有能访问文件系统的平台有。
  directory('目录浏览'),

  /// 打包进 App 的内置样图。各平台都有，保证空手启动也有东西看。
  asset('内置样图'),

  /// 命令行参数传入。只有桌面端有。
  commandLine('命令行参数');

  const ImageFileSource(this.label);

  final String label;
}

/// 目录里的一个条目。
///
/// 用一个类同时表示文件和子目录，靠 [isDirectory] 区分 —— 侧栏要把两者
/// 混在一个列表里显示，分成两个类反而要在 UI 层再合并一次。
class DirectoryEntry {
  const DirectoryEntry({
    required this.name,
    required this.path,
    required this.isDirectory,
    this.sizeBytes,
  });

  final String name;
  final String path;
  final bool isDirectory;

  /// 文件大小。目录为 null。
  final int? sizeBytes;

  /// 扩展名（小写，不含点）。
  String get extension {
    if (isDirectory) {
      return '';
    }
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }

  @override
  String toString() =>
      'DirectoryEntry($name, ${isDirectory ? "目录" : "$sizeBytes 字节"})';
}
