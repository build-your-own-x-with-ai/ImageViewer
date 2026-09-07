import 'dart:typed_data';

import 'package:image_viewer/src/platform/image_file.dart';

/// 文件系统访问能力的抽象。
///
/// ## 为什么需要这一层
///
/// `dart:io` 在 Web 上根本不存在 —— 不是「调用失败」，是 import 就编译不过。
/// 而需求要求六个平台都能编译运行，所以必须把 `dart:io` 隔离在条件导入后面。
///
/// 具体做法见 `file_source.dart`：
///
/// ```dart
/// export 'file_source_stub.dart' if (dart.library.io) 'file_source_io.dart';
/// ```
///
/// 编译 Web 时 `dart.library.io` 为假，拿到 stub；其余平台拿到真实实现。
/// UI 层只 import `file_source.dart`，完全不知道自己跑在哪个平台。
///
/// ## 为什么不用 try-catch 兜住 dart:io
///
/// 试过的人都知道行不通 —— 条件导入是**编译期**机制，运行期的 try-catch
/// 救不了一个编译不过的 import。这是 Flutter 跨平台代码的标准做法。
abstract class FileSourceBase {
  const FileSourceBase();

  /// 本平台能否浏览文件系统目录。
  ///
  /// Web 上为 false。UI 据此决定是否显示目录浏览侧栏 —— 与其显示一个
  /// 点了没反应的按钮，不如干脆不显示。
  bool get canBrowse;

  /// 平台名，用于「本平台不支持」一类提示信息。
  String get platformLabel;

  /// 列出目录内容，只保留子目录与可能的图像文件。
  ///
  /// 过滤条件是扩展名 —— 这是**唯一**允许按扩展名判断的地方，因为列目录时
  /// 不可能把每个文件都读进来嗅探魔数。真正打开时仍然只认魔数，所以扩展名
  /// 撒谎最多导致「该显示的没显示」，不会导致误判格式。
  ///
  /// 不可浏览的平台抛 [UnsupportedError]。调用前先查 [canBrowse]。
  Future<List<DirectoryEntry>> listDirectory(String path);

  /// 读取整个文件。
  ///
  /// 不可浏览的平台抛 [UnsupportedError]。
  Future<Uint8List> readFile(String path);

  /// 用户主目录，作为目录浏览的默认起点。取不到返回 null。
  String? get homeDirectory;

  /// 路径分隔符。Windows 是 `\`，其余是 `/`。
  String get pathSeparator;

  /// 取父目录路径。已在根目录时返回 null。
  String? parentOf(String path);

  /// 取路径最后一段（文件名或目录名）。
  String basenameOf(String path);

  /// 拼接路径。
  String join(String dir, String name);
}

/// 目录列表里允许显示的扩展名。
///
/// 这份清单只影响**侧栏显示哪些文件**，不影响格式判断。
/// 比六个解码器声明的扩展名并集略宽 —— 宁可多显示一个让用户点开看看，
/// 也不要把一个改错扩展名的合法图片藏起来。
const Set<String> kBrowsableExtensions = <String>{
  // BMP
  'bmp', 'dib',
  // PNM
  'pnm', 'pbm', 'pgm', 'ppm', 'pam',
  // YUV（裸流，需要用户给参数）
  'yuv', 'raw', 'i420', 'yv12', 'nv12', 'nv21', 'yuy2', 'uyvy',
  // 后续阶段
  'png', 'apng', 'jpg', 'jpeg', 'jpe', 'jfif', 'webp',
};

/// 判断一个扩展名是否值得在侧栏里显示。
bool isBrowsableExtension(String extension) =>
    kBrowsableExtensions.contains(extension.toLowerCase());

/// 目录条目的排序：目录在前，然后各自按名字不区分大小写排。
///
/// 抽成独立函数是为了能单测 —— 排序逻辑跟 `dart:io` 无关，
/// 不该只能在桌面端验证。
int compareDirectoryEntries(DirectoryEntry a, DirectoryEntry b) {
  if (a.isDirectory != b.isDirectory) {
    return a.isDirectory ? -1 : 1;
  }
  return a.name.toLowerCase().compareTo(b.name.toLowerCase());
}
