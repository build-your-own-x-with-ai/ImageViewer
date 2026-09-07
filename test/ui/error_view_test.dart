import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/ui/error_view.dart';

/// 错误分类的测试。
///
/// ## 为什么这件事值得单独测
///
/// `errors.dart` 里三个异常是继承关系：
///
/// ```
/// ImageDecodeException
///   ├─ UnsupportedImageFeature
///   └─ UnknownImageFormat
/// ```
///
/// 所以 `ErrorView._classify` 里那串 `is` 判断**顺序错了不会有任何报错** ——
/// 分析器不管，运行也不崩，只是三种情况全都退化成最笼统的那条「解码失败」。
/// 用户看到的信息量悄悄少了一大半，而没有任何东西红掉。
///
/// 这正是最该写测试的一类 bug：静默、且只在文案层面表现出来。
void main() {
  group('错误分类', () {
    testWidgets('没人认领：提示可能是裸流，并给出参数入口', (WidgetTester tester) async {
      await _pump(
        tester,
        UnknownImageFormat('前 16 字节没有匹配任何已注册的魔数'),
        onTryYuv: () {},
      );

      expect(find.text('没有解码器认领这个文件'), findsOneWidget);
      // 这就是那个顺序陷阱：判到父类就会显示成「解码失败」。
      expect(find.text('解码失败'), findsNothing);

      expect(find.text('按裸 YUV 解码…'), findsOneWidget);
      expect(find.textContaining('前 16 字节没有匹配任何已注册的魔数'),
          findsOneWidget);
    });

    testWidgets('特性未实现：说清是我们没做，不是文件坏了', (WidgetTester tester) async {
      await _pump(
        tester,
        UnsupportedImageFeature('尚不支持 JPEG 压缩的 BMP', format: 'BMP'),
        onTryYuv: () {},
      );

      expect(find.text('文件没问题，是这里还没实现'), findsOneWidget);
      expect(find.text('解码失败'), findsNothing);

      // **不推荐 YUV**：文件格式已经认出来了（是 BMP），
      // 建议用户「按裸流解」等于把他往错的方向推。
      expect(find.text('按裸 YUV 解码…'), findsNothing);
      expect(find.textContaining('[BMP] 尚不支持 JPEG 压缩的 BMP'), findsOneWidget);
    });

    testWidgets('数据损坏：显示偏移，且不推荐 YUV', (WidgetTester tester) async {
      await _pump(
        tester,
        ImageDecodeException('像素数据被截断', format: 'BMP', offset: 4660),
        fileName: 'broken.bmp',
        onTryYuv: () {},
        onRetry: () {},
      );

      expect(find.text('解码失败'), findsOneWidget);
      expect(find.text('broken.bmp'), findsOneWidget);
      // 认出格式了就不该推荐裸流 —— 那是一张坏了的 BMP，不是 YUV。
      expect(find.text('按裸 YUV 解码…'), findsNothing);
      expect(find.text('重试'), findsOneWidget);

      // 偏移必须同时给十进制和十六进制：前者用来算「还差多少字节」，
      // 后者用来在 hex 编辑器里直接跳过去。
      expect(find.textContaining('偏移 4660'), findsOneWidget);
      expect(find.textContaining('0x1234'), findsOneWidget);
    });

    testWidgets('非解码异常：归到读取失败，不谈格式', (WidgetTester tester) async {
      await _pump(
        tester,
        // 沙盒拒绝访问时 dart:io 抛的就是这一类。
        const _FakeFileSystemException('Operation not permitted'),
        fileName: 'photo.bmp',
        onRetry: () {},
      );

      expect(find.text('读取文件失败'), findsOneWidget);
      // 连解码都没开始，不该出现任何跟格式有关的措辞。
      expect(find.text('解码失败'), findsNothing);
      expect(find.text('没有解码器认领这个文件'), findsNothing);
      expect(find.text('按裸 YUV 解码…'), findsNothing);
    });

    testWidgets('没给回调时不画按钮', (WidgetTester tester) async {
      await _pump(tester, UnknownImageFormat('无法识别'));

      // suggestYuv 为真，但 onTryYuv 为 null —— 画一个点了没反应的按钮
      // 比不画更糟。
      expect(find.text('按裸 YUV 解码…'), findsNothing);
      expect(find.text('重试'), findsNothing);
      // 文案本身还得在。
      expect(find.text('没有解码器认领这个文件'), findsOneWidget);
    });
  });
}

/// 冒充 `dart:io` 的 `FileSystemException`。
///
/// 不直接 import `dart:io`：这个测试文件本身没有平台依赖的必要，而
/// [ErrorView] 只看 `toString()`，用什么类型无关紧要 —— 它收 [Object]
/// 正是为了这一点。
class _FakeFileSystemException implements Exception {
  const _FakeFileSystemException(this.message);

  final String message;

  @override
  String toString() => 'FileSystemException: $message';
}

/// 把 [ErrorView] 挂到一棵最小的树上。
///
/// 需要 [MaterialApp] 是因为 [ErrorView] 要读 `Theme` 和 `colorScheme.error`。
Future<void> _pump(
  WidgetTester tester,
  Object error, {
  String? fileName,
  VoidCallback? onTryYuv,
  VoidCallback? onRetry,
}) async {
  await tester.pumpWidget(MaterialApp(
    home: Scaffold(
      body: ErrorView(
        error: error,
        fileName: fileName,
        onTryYuv: onTryYuv,
        onRetry: onRetry,
      ),
    ),
  ));
}
