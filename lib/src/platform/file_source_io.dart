import 'dart:io';
import 'dart:typed_data';

import 'package:image_viewer/src/platform/file_source_base.dart';
import 'package:image_viewer/src/platform/image_file.dart';

/// 桌面与移动端的 [FileSourceBase] 实现：有真实文件系统。
///
/// **这是整个项目里唯一允许 import `dart:io` 的地方之一**（另一处是
/// 命令行参数处理）。`lib/src/codecs/` 下一律禁止，见 `docs/design.md` 分层约定。
/// 只有这个文件被条件导入挡在 Web 之外，其他文件都要在六个平台上编译。
class FileSource extends FileSourceBase {
  const FileSource();

  @override
  bool get canBrowse => true;

  @override
  String get platformLabel {
    if (Platform.isMacOS) {
      return 'macOS';
    }
    if (Platform.isWindows) {
      return 'Windows';
    }
    if (Platform.isLinux) {
      return 'Linux';
    }
    if (Platform.isIOS) {
      return 'iOS';
    }
    if (Platform.isAndroid) {
      return 'Android';
    }
    return Platform.operatingSystem;
  }

  @override
  Future<List<DirectoryEntry>> listDirectory(String path) async {
    final Directory dir = Directory(path);
    final List<DirectoryEntry> out = <DirectoryEntry>[];

    // followLinks: false —— 符号链接可以指回上层目录，跟着走会绕圈。
    await for (final FileSystemEntity entity
        in dir.list(followLinks: false)) {
      final String name = basenameOf(entity.path);

      // 隐藏文件不显示。点开一个目录先看到几十个 .DS_Store / .git 没有意义。
      if (name.startsWith('.')) {
        continue;
      }

      // 单个条目的 stat 可能因权限失败（macOS 的受保护目录很常见）。
      // 跳过它，不要让整个目录列不出来 —— 用户想看的是能看的那些文件。
      final FileStat stat;
      try {
        stat = entity.statSync();
      } on FileSystemException {
        continue;
      }

      final bool isDir = stat.type == FileSystemEntityType.directory;
      if (!isDir && !isBrowsableExtension(_extensionOf(name))) {
        continue;
      }
      out.add(DirectoryEntry(
        name: name,
        path: entity.path,
        isDirectory: isDir,
        sizeBytes: isDir ? null : stat.size,
      ));
    }

    out.sort(compareDirectoryEntries);
    return out;
  }

  @override
  Future<Uint8List> readFile(String path) => File(path).readAsBytes();

  @override
  String? get homeDirectory {
    // Windows 用 USERPROFILE，POSIX 用 HOME。
    final Map<String, String> env = Platform.environment;
    return env['HOME'] ?? env['USERPROFILE'];
  }

  @override
  String get pathSeparator => Platform.pathSeparator;

  @override
  String? parentOf(String path) {
    final String sep = Platform.pathSeparator;
    final String normalized = _stripTrailingSeparator(path, sep);
    final int idx = normalized.lastIndexOf(sep);
    if (idx < 0) {
      // 没有分隔符：已经是 Windows 盘符根（`C:`）或相对路径。
      return null;
    }
    if (idx == 0) {
      // POSIX 根目录本身没有父目录，它的子目录的父目录是 `/`。
      return normalized.length == 1 ? null : sep;
    }
    final String parent = normalized.substring(0, idx);
    // `C:\Users` 的父目录是 `C:\` 而不是 `C:`。
    return parent.endsWith(':') ? '$parent$sep' : parent;
  }

  @override
  String basenameOf(String path) {
    final String sep = Platform.pathSeparator;
    final String normalized = _stripTrailingSeparator(path, sep);
    final int idx = normalized.lastIndexOf(sep);
    return idx < 0 ? normalized : normalized.substring(idx + 1);
  }

  @override
  String join(String dir, String name) {
    final String sep = Platform.pathSeparator;
    return dir.endsWith(sep) ? '$dir$name' : '$dir$sep$name';
  }

  /// 去掉末尾分隔符，但保留根目录的那一个（`/` 不能变成空串）。
  static String _stripTrailingSeparator(String path, String sep) {
    if (path.length > 1 && path.endsWith(sep)) {
      return path.substring(0, path.length - 1);
    }
    return path;
  }

  static String _extensionOf(String name) {
    final int dot = name.lastIndexOf('.');
    if (dot < 0 || dot == name.length - 1) {
      return '';
    }
    return name.substring(dot + 1).toLowerCase();
  }
}
