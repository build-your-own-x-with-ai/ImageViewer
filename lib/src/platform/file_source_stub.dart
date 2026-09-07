import 'dart:typed_data';

import 'package:image_viewer/src/platform/file_source_base.dart';
import 'package:image_viewer/src/platform/image_file.dart';

/// Web 平台的 [FileSourceBase] 实现：没有文件系统。
///
/// 浏览器不给页面访问本地文件系统的权限 —— 这是安全模型的一部分，
/// 不是能绕过去的限制。所以这个实现的每个方法都拒绝执行。
///
/// Web 上仍然能打开任意本地文件，走的是 `file_selector`：用户在系统对话框
/// 里挑一个文件，浏览器把**字节**交给页面，但不给路径。这就是为什么
/// [ImageFile.path] 是可空的，也是为什么解码器的入口只吃 `Uint8List`。
///
/// 换句话说：Web 少的不是「打开文件」的能力，是「按路径遍历目录」的能力。
class FileSource extends FileSourceBase {
  const FileSource();

  @override
  bool get canBrowse => false;

  @override
  String get platformLabel => 'Web';

  @override
  Future<List<DirectoryEntry>> listDirectory(String path) {
    throw UnsupportedError(
      'Web 上无法遍历本地目录（浏览器安全限制）。'
      '请用「打开文件」按钮从系统对话框选择，或从内置样图里挑一张。',
    );
  }

  @override
  Future<Uint8List> readFile(String path) {
    throw UnsupportedError(
      'Web 上无法按路径读取文件（浏览器安全限制）。'
      '文件选择器返回的字节已经在内存里，不需要再读一次。',
    );
  }

  @override
  String? get homeDirectory => null;

  /// Web 上没有真实文件系统，但仍返回 `/` —— 上层格式化路径字符串时
  /// 不必为「分隔符可能为空」写特例。
  @override
  String get pathSeparator => '/';

  @override
  String? parentOf(String path) => null;

  @override
  String basenameOf(String path) {
    // 即使不能读文件，仍可能需要从 URL 或选择器返回的名字里取最后一段。
    final int slash = path.lastIndexOf('/');
    return slash < 0 ? path : path.substring(slash + 1);
  }

  @override
  String join(String dir, String name) =>
      dir.endsWith('/') ? '$dir$name' : '$dir/$name';
}
