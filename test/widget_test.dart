import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/main.dart';
import 'package:image_viewer/src/ui/browser_sidebar.dart';
import 'package:image_viewer/src/ui/image_canvas.dart';
import 'package:image_viewer/src/ui/info_panel.dart';

/// 应用外壳的冒烟测试。
///
/// 这里**不测解码正确性** —— 那是 `test/codecs/` 和 `test/assets/` 的活，
/// 在 widget 测试里重复一遍只会跑得更慢。这里只测三件 widget 层的事：
/// 布局阈值切换、样图列表真的被打包进来了、点一下能走完
/// 「读 asset → 解码 → 上屏」这条链路。
void main() {
  group('应用外壳', () {
    testWidgets('空手启动：显示引导文案而不是空白', (WidgetTester tester) async {
      await tester.pumpWidget(const ImageViewerApp());
      await tester.pumpAndSettle();

      expect(find.text('打开一张图看看'), findsOneWidget);
      expect(find.text('打开文件…'), findsOneWidget);
      // 还没打开文件，标题退化成 App 名。
      expect(find.text('ImageViewer'), findsOneWidget);
      // 没有图，就不该有画布，也不该有信息面板。
      expect(find.byType(ImageCanvas), findsNothing);
      expect(find.byType(InfoPanel), findsNothing);
    });

    testWidgets('窄窗口：侧栏收进抽屉', (WidgetTester tester) async {
      // 默认测试视口 800×600，低于 900 的内联阈值。
      await tester.pumpWidget(const ImageViewerApp());
      await tester.pumpAndSettle();

      // 抽屉没打开，所以侧栏根本不在树里。
      expect(find.byType(BrowserSidebar), findsNothing);
      expect(find.byType(DrawerButton), findsOneWidget);
    });

    testWidgets('宽窗口：侧栏内联，样图列表非空', (WidgetTester tester) async {
      await _setSurface(tester, const Size(1400, 900));
      await tester.pumpWidget(const ImageViewerApp());
      await tester.pumpAndSettle();

      expect(find.byType(BrowserSidebar), findsOneWidget);
      expect(find.text('内置样图'), findsOneWidget);
      // 样图列表为空说明 pubspec 里没声明 assets/samples/，
      // 或者没跑生成脚本 —— 两种情况都该让测试红掉。
      expect(find.text('bands_80x32_rle8.bmp'), findsOneWidget);
    });

    testWidgets('点一张样图：走完读 asset → 解码 → 上屏', (WidgetTester tester) async {
      await _setSurface(tester, const Size(1400, 900));
      await tester.pumpWidget(const ImageViewerApp());
      await tester.pumpAndSettle();

      await tester.tap(find.text('bands_80x32_rle8.bmp'));
      await _pumpUntilFound(tester, find.byType(ImageCanvas));

      // 画布出来了 = 字节解开了、RGBA 传上 GPU 了。
      expect(find.byType(ImageCanvas), findsOneWidget);
      // 宽窗口下信息面板默认展开。
      expect(find.byType(InfoPanel), findsOneWidget);

      // 尺寸取自 BMP 头部，写死在样图文件名里，两边对上才算真解对了。
      //
      // 必须限定在各自的子树里找：标题栏和信息面板都会显示尺寸，
      // 直接 `find.text` 会命中两个然后报 "is too many"。
      // （信息面板那个是 SelectableText，`find.text` 也认。）
      expect(
        find.descendant(of: find.byType(AppBar), matching: find.text('80 × 32')),
        findsOneWidget,
      );
      expect(
        find.descendant(
          of: find.byType(InfoPanel),
          matching: find.text('80 × 32'),
        ),
        findsOneWidget,
      );
      // 空状态的引导文案该让位了。
      expect(find.text('打开一张图看看'), findsNothing);
    });
  });
}

/// 设定测试视口尺寸，并在测试结束时还原。
///
/// 不还原会污染同一文件里后面的测试 —— `tester.view` 是进程级的。
Future<void> _setSurface(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);
}

/// 反复泵帧直到 [finder] 命中，超时则让测试失败。
///
/// ## 为什么不能用 `pumpAndSettle`
///
/// 两件事撞在一起，缺一个都不会出问题：
///
/// 1. **解码跑在真 isolate 里。** `Isolate.run` 要真实的挂钟时间才能出结果，
///    而 `pumpAndSettle` 推的是 flutter_test 的**假时钟** —— 假时钟走完
///    一万年，真 isolate 那边一个字节都没算完。
/// 2. **忙的时候有个转圈进度条。** `CircularProgressIndicator` 的动画永不
///    停止，于是永远有待处理帧，`pumpAndSettle` 的退出条件永远不成立。
///
/// 结果就是 2 秒后抛 `pumpAndSettle timed out`。所以改成：用 `runAsync`
/// 放行一小段真实时间让 isolate 干活，再 `pump` 一帧把结果画出来，看一眼
/// 到没到，没到就再来一轮。
Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration timeout = const Duration(seconds: 15),
}) async {
  final Stopwatch sw = Stopwatch()..start();
  while (sw.elapsed < timeout) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
    if (finder.evaluate().isNotEmpty) {
      return;
    }
  }
  fail('等了 ${timeout.inSeconds} 秒仍未出现：$finder');
}
