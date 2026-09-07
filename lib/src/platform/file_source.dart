/// 文件系统访问的平台入口。
///
/// UI 层只 import 这个文件，永远不直接 import `file_source_io.dart` 或
/// `file_source_stub.dart` —— 那样就把平台判断泄漏到调用方去了。
///
/// ## 条件导入怎么工作
///
/// ```dart
/// export 'file_source_stub.dart' if (dart.library.io) 'file_source_io.dart';
/// ```
///
/// 编译时 `dart.library.io` 为真（桌面 / 移动端）就导出真实实现，
/// 为假（Web）就导出 stub。这是**编译期**决定的：Web 产物里根本不包含
/// `dart:io` 的代码，所以不存在「运行到那一行才崩」的问题。
///
/// 两边都导出同名的 `FileSource` 类，且都继承 [FileSourceBase]，
/// 于是调用方写 `const FileSource()` 在六个平台上都能编译。
library;

export 'package:image_viewer/src/platform/file_source_base.dart';
export 'package:image_viewer/src/platform/file_source_stub.dart'
    if (dart.library.io) 'package:image_viewer/src/platform/file_source_io.dart';
