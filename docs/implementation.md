# 实现记录

`design.md` 写的是**打算怎么做**，这份写的是**实际做成了什么**，重点在两者
不一致的地方 —— 那些地方通常不是设计错了，而是写代码时才暴露出来的约束。

> 状态：阶段 1（`v0.1.0`）。每阶段结束时追加，阶段 5 定稿。

## 1. 代码规模

`lib/` 下 32 个文件、6163 行（含注释与文档注释，本项目注释占比很高，
是刻意的）。

| 层 | 行数 | 说明 |
|---|---|---|
| `core/` | 1030 | 字节/位读取器、`RgbaImage`、注册表、异常 |
| `codecs/bmp/` | 1069 | 六个头部版本是大头（`bmp_header.dart` 429 行） |
| `codecs/pnm/` | 634 | 词法处理占一半 —— 文本格式的空白与注释规则很啰嗦 |
| `codecs/yuv/` | 766 | 九种布局压成三个循环，靠 `YuvFormat` 描述子 |
| `platform/` | 438 | 条件导入 + `dart:io` 隔离 |
| `services/` | 99 | isolate 调度与计时 |
| `ui/` | 2070 | 外壳。`viewer_page.dart` 506 行是状态机 |
| `main.dart` | 57 | 只装主题、指首页 |

解码器（`core` + `codecs`）共 3499 行，UI 2070 行。**解码逻辑比界面多** ——
对一个「自己写解码器」的项目来说这个比例是健康的。

## 2. 与 design.md 的偏离

### 2.1 YUV 逼出了第二个解码入口

`design.md` 第 1 节的数据流是「字节 → 注册表嗅探 → 解码器 → RgbaImage」，
一条路走完。裸 YUV 把这条路截断了：它**没有文件头**，`canDecode` 只能恒为
`false`，注册表永远不会把字节分派给它。

于是 `services/decode_service.dart` 里有两个入口而不是一个：

```dart
Future<DecodeResult> decodeImage(Uint8List bytes);                    // 嗅探
Future<DecodeResult> decodeYuv(Uint8List bytes, YuvOptions options);  // 显式
```

后者绕过注册表直接调 `YuvDecoder.decodeWith`。这不是妥协，而是
`ParameterizedImageDecoder` 这个接口存在的理由 —— 有些格式的参数**在数据
之外**，只能由用户提供。设计时把它当成 `ImageDecoder` 的一个变体，实现时
才看清它其实是另一条通路。

连带影响：UI 必须记住「这张图是按裸流解出来的」（`ViewerPage._yuv`），
否则翻帧和改参数都无从下手。一个恒假的 `canDecode` 一路影响到了页面状态。

### 2.2 四个阶段 5 的条目在阶段 1 就落地了

不是抢进度，是它们各自被别的东西拽了进来：

| 条目 | 为什么提前 |
|---|---|
| `Isolate.run` 后台解码 + Web 回退 | 解码器本来就是纯函数，跳 isolate 只多三行。反过来说，等到阶段 5 再补，中间三个阶段的 UI 都得先卡住一次 |
| 透明棋盘格背景 | 32bpp BMP 的 alpha 是阶段 1 的内容。没有棋盘格，「透明」和「白色」在屏幕上完全一样 —— 那这个分支就等于没法验证 |
| 适配模式（适配窗口/原始尺寸/填充） | 「原始尺寸」是看解码结果的**前提**：缩放过的图看不出行对齐有没有错 |
| 缩放平移视图 | 同上，要放大到能看见单个像素方格才谈得上验证 |

共同的原因是：这些不是「打磨」，而是**让阶段 1 的解码结果可被肉眼验证的最低
条件**。计划把它们归到阶段 5，是按「界面功能」分的类；实现时才发现该按
「验证能力」分。

### 2.3 计时放在 service 层，不在解码器里

`DecodeResult` 带一个 `duration`，但计时的 `Stopwatch` 在
`decode_service.dart` 里，不在解码器内部。解码器是纯函数，**不该知道时钟
存在** —— 一旦它自己计时，就没法在 isolate 里安全复用，也没法在测试里断言
「同样的输入必然得到同样的输出」。

代价是 `RgbaImage.metadata` 里的 `decodeDuration` 要由调用方补进去
（`DecodeResult.imageWithTiming`），多一次对象构造。值得。

## 3. 实现时才踩到的坑

这一节是本文件最有价值的部分。每一条都实际发生过，且都有「看起来像别的问题」
的特征 —— 这正是它们值得记下来的原因。

### 3.1 macOS 沙盒：看起来像解码器的 bug

现象：`file_selector` 弹出对话框、用户选中文件、返回了一个**正确的路径**，
然后 `File(path).readAsBytes()` 抛 `PathAccessException`。

排查方向很容易跑偏 —— 路径是对的，对话框也正常，于是怀疑读取逻辑。实际原因
是沙盒 entitlement 缺了一条：

```xml
<key>com.apple.security.files.user-selected.read-only</key>
<true/>
```

没有它，App 拿得到路径但读不了内容。要加在
`macos/Runner/DebugProfile.entitlements` **和** `Release.entitlements` 两个
文件里 —— 只加 Debug 的话，Release 构建会以完全相同的方式失败一次。

推论（影响了侧栏的设计）：沙盒只放行**用户经由系统对话框明确选中**的路径。
所以目录浏览不能提供「输入路径跳转」，也不能默认列 `~/Pictures`
—— 那在沙盒下必然失败。只能用 `getDirectoryPath()` 让用户授权。
这是 macOS 的设计，不是要绕过去的东西。

### 3.2 `String.codeUnits` 是 UTF-16，不是 UTF-8

`tool/gen_samples.dart` 给 PNM 样图写文本头部时用了 `String.codeUnits`。
纯 ASCII 时它和 UTF-8 结果完全一致，所以这个 bug 藏了很久 —— 直到给样图
加中文注释：

```
期望：# ASCII PPM：可以直接用文本编辑器打开
实际：# ASCII PPM����(�,�hS
```

`codeUnits` 给的是 UTF-16 码元，`'由'` 是 U+7531 = 30001，塞进 `Uint8List`
只保留低 8 位，30001 就变成了 0x31。改用 `utf8.encode`。

值得记下来是因为：**「能用文本编辑器打开」正是 ASCII 版 PNM 作为教学起点的
全部意义**。头部乱码的话，这几张样图存在的理由就没了 —— 而所有像素测试
依然全绿。

### 3.3 异步解码需要请求号，而丢弃结果时要还显存

解码是异步的（还跳了 isolate），用户完全可能在大图解完之前又点了一张小图。
小图先解完上屏，紧接着大图解完，**把新的覆盖成旧的**：屏幕上显示的图和侧栏
高亮的那一行对不上。

`ViewerPage._token` 每次请求自增一次，回来时号不对就丢弃。这部分是常规做法。
不那么显然的是丢弃时必须 `display.dispose()`：

```dart
if (token != _token || !mounted) {
  display.dispose();  // 少这一行，每次抢跑漏一张图的显存
  return;
}
```

`ui.Image` 是 GPU 纹理，**不受 Dart GC 管**。一张 4000×3000 的图是 48MB，
连点几下侧栏就能漏掉几百兆。同理 `State.dispose` 里要还掉当前那张。

### 3.4 `ByteData.buffer.asUint8List()` 会读到别的资源

`rootBundle.load()` 返回的 `ByteData` 是**整个 asset 缓冲区上的一个视图**。
直接 `data.buffer.asUint8List()` 拿到的是整块缓冲区，前后连着别的资源的
字节 —— 解码器于是从一个错误的偏移开始读。必须带上视图边界：

```dart
data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes)
```

### 3.5 异常继承关系让 `is` 判断的顺序变得关键

`errors.dart` 里三个异常是继承的：

```
ImageDecodeException
  ├─ UnsupportedImageFeature
  └─ UnknownImageFormat
```

`ErrorView._classify` 里若先判父类，两个子类分支就永远走不到。**分析器不报
错，运行也不崩**，只是三种情况全都退化成最笼统的那条「解码失败」，用户能拿到
的信息悄悄少了一大半。窄的必须在前。

这类 bug（静默、只在文案层面表现）正是最该写测试的，所以有
`test/ui/error_view_test.dart`。

### 3.6 `pumpAndSettle` 和真 isolate 合不来

widget 测试里点一张样图然后 `pumpAndSettle()`，2 秒后抛 `timed out`。
两件事撞在一起，缺一个都不会出问题：

1. **解码在真 isolate 里跑**，要真实挂钟时间；而 `pumpAndSettle` 推的是
   flutter_test 的**假时钟**。假时钟走完一万年，真 isolate 一个字节都没算完。
2. **忙的时候有个转圈进度条**，动画永不停止，于是永远有待处理帧，
   `pumpAndSettle` 的退出条件永远不成立。

解法是 `runAsync` 放行一小段真实时间、`pump` 一帧、检查、再来一轮，见
`test/widget_test.dart` 的 `_pumpUntilFound`。

### 3.7 期望值要从文件里读，不能照公式推

`samples_test.dart` 里断言 P3 样图某个像素是 `[255, 26, 26, 255]`，实际是
25。原因不在解码器：生成脚本算的是 `1.0 - 0.9`，IEEE754 下这等于
`0.09999999999999998`，乘 255 得 25.4999… → 25。手推的时候用的是理想值 0.1，
乘 255 得 25.5 → 26。

所以样图测试的期望值一律**从生成出来的文件里读**，不重新推导一遍 ——
重新推导只会把同一个理想化错误再犯一次。ASCII 格式在这里格外好用：
`ramp_16x8_ascii.pgm` 直接打开就能看到每个采样值。

### 3.8 读盘失败时没有 `ImageFile` 可用

`ImageFile` 的构造需要字节，而读盘失败时字节正是没拿到的东西。可错误提示里
最该有的恰恰是「哪个文件出的错」。所以 `ViewerPage` 上另有两个字段
`_errorName` / `_errorPath`，专门服务于「连文件都没读到」这条路径 ——
后者还让「重试」能真的重读一次（macOS 沙盒下重新授权后重试就成了）。

### 3.9 SMB 盘上 `flutter build macos` 会在构建**成功之后**崩

现象：`flutter build macos --debug` 打出一大段 `Oops; flutter has exited
unexpectedly`，还生成了一份 crash report。看起来像构建失败了。

实际上 `.app` 已经完整产出（可执行文件、framework、assets 全在）。崩的是
构建**之后**那一步 —— flutter_tools 要报告产物体积：

```
OperatingSystemUtils.getDirectorySize → lengthSync
  → FileSystemException: Cannot retrieve length of file,
    path = '…/App.framework/Resources' (OS Error: Is a directory, errno = 21)
```

`App.framework/Resources` 是个指向 `Versions/Current/Resources` 的符号链接
（macOS framework 的标准布局）。在 APFS 上 `lengthSync` 返回链接本身的大小；
在 `smbfs` 上它跟随链接、落到目录上，于是 `errno = 21`。

这是环境问题，跟本项目代码无关，但值得记一笔：

- **判断构建到底成没成，要去看 `.app` 里有没有东西**，别看有没有 crash
  report。验证自己改的那部分最直接：
  ```bash
  codesign -d --entitlements - <app> | grep user-selected   # entitlement 进去了吗
  ls <app>/Contents/Frameworks/ | grep selector             # 插件链进去了吗
  ls <app>/…/flutter_assets/assets/samples/                 # 样图打包了吗
  ```
- `flutter test` / `flutter analyze` 不受影响，只有 `build` 的体积统计会踩到。
- 这也正是本仓库需要两个工作目录的原因：SMB 挂载的那份用来写代码和跑测试，
  本地盘上另一份 clone 用来真正构建和运行。两边靠 git 同步。

## 4. 渲染上的两个决定

### 4.1 放大用最近邻，缩小用线性

```dart
filterQuality: scale >= 1.0 ? FilterQuality.none : FilterQuality.medium
```

放大时若插值，相邻像素被抹成渐变 —— 而「像素的边界在哪」正是要看的东西：
解码错位表现为一道斜纹，插值之后就成了一片模糊。所以 `scale >= 1` 一律
`none`，保证一个图像像素是一个实心方块。

缩小时反过来：不插值会走样，一张 4000 宽的图缩到 800 会出现摩尔纹 ——
那是采样假象，不是解码结果。误把它当成解码 bug 会白排查很久。

最大缩放定为 64 倍，就是为了让单个像素能占满一格看清楚。

### 4.2 `hasTransparency` 预先算好

判断有没有透明像素是 O(n) 全图扫描，而 `build()` 每帧都跑。所以
`DisplayImage.from()` 构造时算一次存起来，用来决定要不要画棋盘格。

## 5. 实际的分层

```
main.dart
  └─ ui/viewer_page.dart          状态机：文件 → 解码 → 显示
       ├─ ui/browser_sidebar.dart   来源：assets + 目录
       ├─ ui/image_canvas.dart      缩放平移 + 棋盘格 + 摆放模式
       ├─ ui/info_panel.dart        元数据（遍历 toDisplayMap）
       ├─ ui/yuv_dialog.dart        裸流参数
       ├─ ui/error_view.dart        四类错误分开给建议
       └─ ui/image_bridge.dart      RgbaImage → ui.Image
            │
            ├─ services/decode_service.dart   isolate + 计时
            │    └─ core/decoder_registry.dart  魔数嗅探
            │         └─ codecs/{bmp,pnm,yuv}/
            └─ platform/file_source.dart      条件导入隔离 dart:io
```

`ui/` 依赖 `services/` 和 `platform/`，`codecs/` 谁也不依赖（连 `dart:io`
都不许 import）。反向依赖一次都没有出现 —— 这条约定在阶段 1 守住了，
后面三个格式会验证它是否还站得住。

`info_panel.dart` 遍历 `metadata.toDisplayMap()` 渲染，所以加 PNG/JPEG/WebP
时**不需要改任何 UI 代码**。这是阶段 1 就该验证的设计假设，目前三种格式
（其中 YUV 的元数据结构和另两种差别很大）都成立。

## 6. 阶段 1 的遗留

- 窄窗口下侧栏收进抽屉，抽屉一关就丢掉当前浏览的目录（`BrowserSidebar` 的
  `State` 随抽屉销毁）。要保住得把目录状态提到 `ViewerPage`。暂不处理：
  真正窄的平台是手机，那儿 `canBrowse` 常常为假，目录浏览本来就不是主来源。
- 文件选择器的扩展名白名单只列已实现的格式。**不能**照抄侧栏的
  `kBrowsableExtensions`（那份含 png/jpeg）—— 否则用户选中一张正常的 PNG，
  会得到「没有解码器认领」+「试试按裸 YUV 解码」，而这个建议是错的。
  每加一个解码器要同时更新这两处，方向相反：选择器收紧，侧栏放宽。
- 命令行参数打开文件（`ImageFileSource.commandLine` 已经定义但没接线）。
- 像素探针、直方图、旋转翻转仍在阶段 5。
