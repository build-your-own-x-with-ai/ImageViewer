import 'package:flutter/material.dart';
import 'package:image_viewer/src/ui/viewer_page.dart';

void main() {
  runApp(const ImageViewerApp());
}

/// 应用根节点。
///
/// 这里只做三件事：装主题、指定首页、关掉调试横幅。真正的逻辑都在
/// [ViewerPage] 里 —— `main.dart` 不该知道解码器、文件来源这些事情的存在。
class ImageViewerApp extends StatelessWidget {
  const ImageViewerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'ImageViewer',
      // 跟随系统亮暗。看图这件事对背景明暗很敏感 —— 白底看深色图和黑底看
      // 浅色图是两种体验，交给系统设置比替用户决定好。
      themeMode: ThemeMode.system,
      theme: _theme(Brightness.light),
      darkTheme: _theme(Brightness.dark),
      debugShowCheckedModeBanner: false,
      home: const ViewerPage(),
    );
  }

  /// 两套主题共用的构造。
  ///
  /// 种子色挑了青灰：界面上大片区域是图像本身，UI 的颜色越安静越好 ——
  /// 一个饱和度很高的强调色会干扰对图像色彩的判断，而「判断色彩对不对」
  /// 正是这个项目要干的事（YUV 矩阵选错了就是整体色偏）。
  static ThemeData _theme(Brightness brightness) {
    final ColorScheme scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF4A6B75),
      brightness: brightness,
    );
    return ThemeData(
      colorScheme: scheme,
      useMaterial3: true,
      appBarTheme: AppBarTheme(
        backgroundColor: scheme.surface,
        surfaceTintColor: scheme.surfaceTint,
        elevation: 0,
        scrolledUnderElevation: 0,
      ),
      dividerTheme: DividerThemeData(
        color: scheme.outlineVariant,
        space: 1,
        thickness: 1,
      ),
      // 桌面端默认的点击区域偏大，侧栏一屏能显示的行数会少三分之一。
      visualDensity: VisualDensity.compact,
    );
  }
}
