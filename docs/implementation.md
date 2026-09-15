# 实现记录

`design.md` 写的是**打算怎么做**，这份写的是**实际做成了什么**，重点在两者
不一致的地方 —— 那些地方通常不是设计错了，而是写代码时才暴露出来的约束。

> 状态：阶段 3（`v0.3.0`）。每阶段结束时追加，阶段 5 定稿。

## 1. 代码规模

`lib/` 下 55 个文件、12399 行（含注释与文档注释，本项目注释占比很高，
是刻意的）。

| 层 | 行数 | 说明 |
|---|---|---|
| `core/` | 1069 | 字节/位读取器、`RgbaImage`、注册表、异常 |
| `compress/` | 1069 | inflate 一家：`inflate.dart` 647 行 + Huffman 218 + 码表 130 + Adler 74 |
| `codecs/bmp/` | 1069 | 六个头部版本是大头（`bmp_header.dart` 429 行） |
| `codecs/png/` | 1771 | 九个文件，最大的 `png_decoder.dart` 也只 482 行 |
| `codecs/jpeg/` | 3351（新） | 十个文件，`jpeg_scan.dart` 678 行占五分之一 |
| `codecs/pnm/` | 634 | 词法处理占一半 —— 文本格式的空白与注释规则很啰嗦 |
| `codecs/yuv/` | 766 | 九种布局压成三个循环，靠 `YuvFormat` 描述子 |
| `platform/` | 438 | 条件导入 + `dart:io` 隔离 |
| `services/` | 103 | isolate 调度与计时 |
| `ui/` | 2072 | 外壳。`viewer_page.dart` 506 行是状态机 |
| `main.dart` | 57 | 只装主题、指首页 |

解码器（`core` + `compress` + `codecs`）共 9729 行（阶段 1 是 3499，
阶段 2 是 6334），UI 2072 行三个阶段几乎没动。**解码逻辑是界面的 4.7 倍**，
而且差距每个阶段都在拉大 —— 对一个「自己写解码器」的项目来说这是健康的。

阶段 3 加了 3390 行，其中 **3351 行在 `codecs/jpeg/` 里面**，落在外面的
只有 39 行：`bit_reader_msb.dart` 的 `skipRestartMarker()` 36 行，加上
注册表和扩展名白名单各一两行。和阶段 2 恰好相反 —— 那次 38% 的成本花在了
`compress/`。JPEG 不外包，它自己就是那个复杂的东西，见第 5 节。

`codecs/jpeg/` 也是目前最大的一层，比 `compress/` 和 `codecs/png/` 加起来
还多。十个文件里没有一个超过 700 行，但**十个文件谁也不能少**。

测试 731 个（阶段 1 是 305，阶段 2 是 496）：core 68、compress 67、
BMP 76、PNG 97、JPEG 223、PNM 38、YUV 64、样图 89、UI 9。

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

### 2.4 inflate 没有用环形窗口

`design.md` 第 5 节写的是「LZ77 回溯用 32KB 环形窗口」。实现时没有用环形
窗口 —— **输出缓冲本身就是窗口**。

原因是环形窗口解决的是一个我们没有的问题。它是**流式**解压器才需要的结构：
边解边把结果吐给下游、不保留全量输出，所以必须单独留一份最近 32KB 的历史。
我们的 `inflate` 一次性返回完整的 `Uint8List`，反向引用要往回读的字节全都
还在输出缓冲里，直接按下标索引即可：

```dart
void copyBack(int distance, int length) {
  if (distance <= 0 || distance > kMaxDistance) { … }   // 约束照旧检查
  int from = _length - distance;
  for (int i = 0; i < length; i++) {
    writeByte(_bytes[from + i]);   // 逐字节，因为可能重叠
  }
}
```

省掉的不只是一份 32KB 缓冲，还有环形结构里最容易写错的那部分：**下标回绕**。
环形窗口下「往回 distance 个字节」要写成 `(pos - distance + 32768) % 32768`，
少一个模、模错一次都会读到 32KB 之前的陈旧数据 —— 而这种 bug 的表现是
「大图偶尔花屏、小图永远正常」，因为小图根本绕不满一圈。

要强调的是**规范的约束一条都没放松**：`kMaxDistance = 32768` 照样检查，
距离超界照样报错。放弃的只是一个实现手段，不是一项校验。真要做流式解压
（比如为了给超大 PNG 报进度），这里得改回环形 —— 那时 `copyBack` 是唯一
需要动的函数，这也是把它单独拆出来的原因。

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

### 3.10 建 Huffman 表时的下标差一：解出来的符号「错得很有规律」

`huffman.dart` 里把符号按码长分档写进 `_symbols`，游标一开始写成了
`offsets[len + 1]++`，正确的是 `offsets[len]++`：

```dart
for (int len = 1; len <= kMaxCodeBits; len++) {
  offsets[len + 1] = offsets[len] + counts[len];   // 建表：下一档的起始
}
…
symbols[offsets[len]++] = symbol;   // 填表：本档的起始。用 len + 1 就全错了
```

`offsets[len]` 是码长 `len` 的**起始**下标，`offsets[len + 1]` 是下一档的
起始。用后者，每个符号都被写进相邻的错误区间，最后一档还会越界。

值得记下来的是它的**症状**：解压不报错，Adler-32 报错。因为码表结构本身
合法（长度对、Kraft 检查过得去），只是每个码字映射到了错的符号 —— 于是
inflate 顺利跑完，吐出一堆语法正确、内容全错的字节。往上传到 PNG 层，
CRC-32 全部通过（它校验的是**压缩前**的字节，没坏），只有 Adler-32 拦下来。

这正好演示了 `png.md` 里那句「两道校验的作用域不同」的实际价值：**如果只有
CRC，这个 bug 会以「图像花屏但不报错」的形式存在**。自写解压器时 Adler-32
是最值钱的一道防线，因为它是唯一校验解压**产物**的。

### 3.11 `<< 24` 在 Web 上是负数

Dart 的位运算在 Web（编译到 JavaScript）上是 **32 位有符号**的，桌面/移动
（原生 int 是 64 位）上不是。所以 `0xFF << 24 == -16777216` 在 Web 上成立。

踩到两次，都在「拼一个 32 位大端整数」的地方：

| 位置 | 症状 |
|---|---|
| `inflate.dart` 读 zlib 尾部的 Adler-32 | 校验和高字节 ≥ 0x80 的文件（约一半）在 Web 上全部报「Adler-32 校验失败」，桌面上一切正常 |
| `rgba_image.dart` 的 `pixelAt` | 红色分量 ≥ 0x80 时返回负数，`pixelAt(...) == 0xFF0000FF` 这类断言在 Web 上失败 |

两处都改成乘法（`* 16777216` 代替 `<< 24`，`* 65536` 代替 `<< 16`）。
乘法在两种数值语义下结果相同，因为它根本没碰符号位。

顺带查清了两处**不用改**的 `<< 24`，理由值得记下来 ——「统一用乘法」这条
规则不是无脑套的：

- `bmp_decoder.dart:166` 拼 32bpp 原始值后立刻走 `ChannelMask.extract`，
  那里是 `(pixel >> shift) & maxValue`。移位后的**掩码把符号位的影响
  抹掉了**：Web 上 `raw` 是负数，右移是算术右移（符号位向右填充），但
  `& maxValue` 只取低几位，取出来的通道值和 64 位下完全一致。
- `rgba_image.dart:105` 已按上表改掉了，剩下的 `<< 8` 不可能溢出 32 位。

区别在于**结果有没有被暴露出去**。中间值只要最终被掩码收窄，负不负都不影响；
一旦作为整数被比较或返回，符号位就是可见的。这也说明「Web 上的 int 不一样」
这件事不能靠全局搜索位运算符解决，得看每一处的数据流。

而这个 bug 类型在本项目里格外危险：**测试默认跑在 VM 上**（`flutter test`
不编译到 JS），所以 Web 专属的算术 bug 一个测试都拦不住。目前的对策是把
「拼多字节整数一律用乘法」写进约定，并在 `rgba_image_test.dart` 里留一个
高位 ≥ 0x80 的断言当哨兵。

### 3.12 期望值要跑一遍参考实现，不能手写

`png.md` 结尾有一段 82 字节的十六进制转储，逐字节标注了一张 2×2 PNG 的
每个字段。这种教学用的字节样例最容易出错的地方在于：**它一旦写错，就永远
错着**，读者对着算不出来只会以为自己错了。

里面有三个值是人手算不出来的：两个 CRC-32、一个 Adler-32。所以这段转储
是先用 Python 的 `zlib` 生成、验证 `zlib.decompress(stream) == raw` 通过，
再抄进 Markdown 的 —— 而不是反过来。

抄完还不够。文档里的字节和解码器之间没有任何机械联系，改了解码器不会有
任何东西提醒你文档已经过时。所以那 82 个字节又被抄进了
`png_test.dart` 的最后一个 group，断言四个角的颜色、总长 82、以及
「改动任意一个字节都会被两道校验之一抓住」。文档现在**钉在测试里**。

这条和 3.7 是同一个道理的两个方向：3.7 说期望值不能照公式推第二遍，
这条说文档里的字节不能只存在于 Markdown 里。

## 4. PNG 这一阶段，一多半工作量不在 PNG

计划里阶段 2 只写了「PNG」。做完回头看，2837 行新代码里 1069 行在
`compress/` —— 而 `compress/` 和 PNG 没有关系，它是 deflate。

这个比例不是意外，而是 PNG 这个格式的本质：

| | BMP（阶段 1） | PNG（阶段 2） |
|---|---|---|
| 格式自身的语义 | 六个头部版本、五种压缩、任意位掩码 —— **很复杂** | IHDR 十三字节 + 五个滤波器 —— **很简单** |
| 依赖的算法 | 无（RLE 算半个） | 整个 deflate：Huffman + LZ77 + 三种块类型 |
| 规范页数感觉 | 读不完，因为版本多 | 读得完，因为设计干净 |
| 实际难点 | 判断「这是哪个版本」 | 写出一个正确的解压器 |

**两个格式的难度来自相反的方向。** BMP 难在它二十年里长出了六个头部版本
和一堆事实标准；PNG 1996 年定稿后几乎没变过，难在它把复杂度全外包给了
deflate，而 deflate 得你自己写。

所以 `compress/` 从一开始就放在 `codecs/` 外面（`design.md` 第 2 节的
`ui → codecs → compress → core`）。当时的理由是「阶段 4 的 WebP VP8L 和
ALPH 会复用 Huffman 机制」—— 一个对未来的押注。做完阶段 2 可以说这个押注
的收益已经提前到账了：**inflate 的 67 个测试完全不需要构造 PNG 文件**，
直接喂 zlib 流就行。如果它长在 `codecs/png/` 里，测一个 stored 块都得先
包一个 IHDR。

分层带来的可测性，比复用更早兑现。

## 5. JPEG 这一阶段，难点在控制流

阶段 2 的教训是「成本会花在格式之外」。阶段 3 的数字恰好相反：3390 行新代码
里 3351 行在 `codecs/jpeg/` 内部。JPEG 不外包任何东西，它自己就是那个复杂的
东西。

但**行数不是难点所在**。难的是前三种格式都能写成流水线，JPEG 不能：

| | BMP / PNM / YUV / PNG | JPEG |
|---|---|---|
| 头部与像素 | 分开，先解析完头部再解像素 | **交错**，DQT/DHT 可以出现在任何位置 |
| 表 | 一次性的 | **可变的当前状态**，同号后来的覆盖先前的 |
| 像素数据 | 一整块，有长度 | 多趟扫描，**熵数据没有长度字段** |
| 一个块解几次 | 一次 | 渐进模式下要被写好几遍 |

于是 `jpeg_decoder.dart` 的主循环没有「解析头部」这个阶段：读一个 marker，
按类型改状态或者交给扫描器，**扫描器返回它自己停下来的偏移**，接着读。
这个「返回停止位置」的接口是被格式逼出来的 —— 没有长度字段，只有扫描自己
知道它在哪撞上了下一个 marker。

`jpeg_scan.dart` 678 行占了整层的五分之一，因为基线加渐进一共四条熵解码
路径（DC 首趟 / DC 细化 / AC 首趟 / AC 细化），细化趟读裸位、不过霍夫曼表，
和首趟几乎没有共用代码。

### 5.1 `IdctAan` 改名 `IdctFast`，因为实现的是别的算法

`design.md` 第 4.5 节写的是 `IdctAan`。实际实现的是
Loeffler-Ligtenberg-Moschytz（LLM），类名跟着改了。

差别不是命名讲究。真正的 AAN（libjpeg 的 `jidctflt.c`）输出带一组余弦缩放
因子，必须**把因子预先乘进量化表**才能抵消。那会让 IDCT 和反量化耦合起来：
换一个 IDCT 就得换一张量化表，`dequantizeBlock` 也不能再是「系数 × 除数」
这么一句话，而本项目留着 `IdctNaive` 正是为了**两个实现吃同一份输入**做对照。

LLM 不需要预缩放，这也是 libjpeg 自己的 `jidctint.c` 和 stb_image 都选它的
原因。用一个不准确的类名换一层耦合不值得。

### 5.2 IDCT 没有「对不对」，只有「差多少」

规范（ITU T.83）不要求 IDCT 位精确，只给容差。所以「我们的 IDCT 对不对」
这个问题本身问错了 —— 正确的问法是「差多少，和谁比」。

拿 `djpeg` 的三种 IDCT 在同一张 q90 4:4:4 图上比（9216 个通道）：

| 参照 | 差异通道数 | 最大差 |
|---|---|---|
| 我们 vs `-dct int`（islow） | 34 | 2 |
| 我们 vs `-dct fast`（ifast） | 6154 | 3 |
| **libjpeg 自己的 islow vs float** | **67** | —— |

第三行是关键：**libjpeg 内部两种 IDCT 的差距比我们和它的差距还大**。有了
这个数，`tolerance: 2` 就不是调出来的魔数，而是有依据的。

量化越粗，非零系数越少，分歧越消失 —— 所以 q75 4:2:0 和 q85 灰度是逐字节
相等的，那两处写 `tolerance: 0`。

## 6. 渲染上的两个决定

### 6.1 放大用最近邻，缩小用线性

```dart
filterQuality: scale >= 1.0 ? FilterQuality.none : FilterQuality.medium
```

放大时若插值，相邻像素被抹成渐变 —— 而「像素的边界在哪」正是要看的东西：
解码错位表现为一道斜纹，插值之后就成了一片模糊。所以 `scale >= 1` 一律
`none`，保证一个图像像素是一个实心方块。

缩小时反过来：不插值会走样，一张 4000 宽的图缩到 800 会出现摩尔纹 ——
那是采样假象，不是解码结果。误把它当成解码 bug 会白排查很久。

最大缩放定为 64 倍，就是为了让单个像素能占满一格看清楚。

### 6.2 `hasTransparency` 预先算好

判断有没有透明像素是 O(n) 全图扫描，而 `build()` 每帧都跑。所以
`DisplayImage.from()` 构造时算一次存起来，用来决定要不要画棋盘格。

## 7. 实际的分层

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
            │         └─ codecs/{bmp,png,jpeg,pnm,yuv}/
            │              └─ compress/inflate.dart   ← 只有 png/ 用到
            │                   └─ compress/{huffman,adler32,deflate_tables}
            └─ platform/file_source.dart      条件导入隔离 dart:io
```

`ui/` 依赖 `services/` 和 `platform/`，`codecs/` 谁也不依赖（连 `dart:io`
都不许 import）。反向依赖一次都没有出现 —— 阶段 2 是这条约定的第一次真正
考验，因为它引入了 `codecs/` 之下的新一层：

- `compress/` 只 import `core/`（`BitReaderLsb` 和 `errors.dart`），
  对 `codecs/` 一无所知。它甚至不知道「PNG」这个词 —— `inflate` 的
  `format` 参数是调用方传进来的字符串，只用于拼错误信息。
- `codecs/png/` 里九个文件只有 `png_decoder.dart` 一个 import `compress/`。
  滤波、隔行、像素展开、CRC 都不碰压缩。

阶段 3 没有引入新层。JPEG 的 Huffman **没有**复用 `compress/huffman.dart`：
两者的思想一样（规范化 Huffman），但位序相反（MSB / LSB）、最大码长不同
（16 / 15）、码表传输方式完全两样（`BITS`+`HUFFVAL` / 每符号码长），硬凑成
一个类只会让两边都别扭。这是**刻意的重复**，理由写在 `jpeg_huffman.dart`
的类文档里。

`info_panel.dart` 遍历 `metadata.toDisplayMap()` 渲染，所以加 PNG/JPEG/WebP
时**不需要改任何 UI 代码**。这条阶段 1 立下的设计假设在阶段 2 和 3 各验证了
一次：PNG 的元数据多了 chunk 数、deflate 块类型、滤波器用量；JPEG 又多了
采样因子、MCU 尺寸、扫描趟数、表数量、IDCT 名字、重启间隔、EXIF 方向、
Adobe 变换 —— 两次都是**UI 代码一行没改**。

两个阶段为格式改动的 UI 代码都只有文件选择器的扩展名白名单（阶段 2 加
`'png'`，阶段 3 加 `'jpg'/'jpeg'/'jpe'/'jfif'`）。那不是渲染逻辑，是「能选
什么文件」的策略 —— 见第 9 节，它和侧栏的白名单方向相反。

## 8. 参考实现只出现在生成脚本里

`tool/gen_samples.dart` 用 `dart:io` 的 `ZLibCodec(level: 9)` 压缩 PNG 样图的
像素数据。这看起来违反了「不依赖任何解码库」，值得说清楚为什么不是：

- **方向相反。** 项目的约束是**解**码全自己写。这里用的是**压**缩，而且
  压缩器的输出正是我们要解的东西 —— 用官方 zlib 生成、用手写 inflate 解开，
  这才构成一次真正的验证。自己写压缩器再自己解开，只能证明两个 bug 互相
  抵消了。
- **产物入库，脚本不参与测试。** 六张 PNG 样图是 git 里的二进制文件，
  `flutter test` 只读它们。测试进程从不 shell out、从不 import `dart:io`
  的压缩 API。这条是 `testing.md` 的硬要求。
- **它是唯一的动态 Huffman 来源。** 手写测试用例能覆盖 stored 和固定
  Huffman，但**人写不出真实的动态 Huffman 块** —— 那需要先做频率统计再
  构造最优码表。zlib level 9 的输出正好补上这一块：`gradient_96x64_rgb8.png`
  和 `rings_64x64_adam7.png` 里是真实的动态块，带 HCLEN 压缩过的码长表。

换句话说，`compress/` 的 67 个单测证明 inflate 对**我们能想到的**位模式
正确，六张样图证明它对**zlib 实际产出的**位模式正确。两者缺一不可，而后者
只能借助参考实现来构造。

### 8.1 阶段 3 把这条规则推到了边上

JPEG 的情况比 zlib 那次更微妙，得分成两半说。

**`cjpeg` 生成样图，和 zlib 那次一模一样。** 它是编码器，方向相反，产物入库。
理由完全相同，没有新问题。这里只多一条无法回避的现实：前三种格式的样图能用
`tool/gen_samples.dart` 手写字节拼出来，JPEG 不行 —— 手写 JPEG 字节要先有一个
DCT + 量化 + Huffman 编码器，规模和解码器本体相当。写它只为了造测试数据，
不划算。

**`djpeg` 生成参考解码结果，这一条是新的。** 它是**解码器**，而我们比对的是
它的解码输出。这不能用「方向相反」来辩护，得换个说法：

- **它是参照，不是依赖。** 五份 `.pnm` 是 git 里的文本文件，`flutter test`
  只读它们。测试进程仍然从不 shell out —— 这条硬要求没破。
- **每张图同时比两个参照。** 除了 `djpeg` 的输出，还比**压缩前的原图**
  （那张 PNM 本来就在仓库里）。两个都需要：我们和 libjpeg 同属 islow 家族，
  有可能一起错；而量化损失把源图比对的容差推到 8，单靠它抓不住多少东西。
  只有 `djpeg` 那一路能给出 `tolerance: 0`，只有源图那一路和 libjpeg 无关。
- **有损格式没有别的办法。** PNG 的正确性是可判定的：解出来的字节要么和原图
  逐字节相等，要么不等。JPEG 的正确性是个容差问题（见 5.2），而容差得有个
  参照才能定 —— 拿 `djpeg` 的三种 IDCT 互相比，才知道 2 是合理的、6154 个通道
  是不合理的。

代价记在这里：**CMYK 和 YCCK 两条路径没有交叉验证**。`djpeg` 的 PNM 输出只
支持 1 或 3 分量，四分量图它写不出来。那两条路径只有单元测试覆盖，靠的是
「同一组样本值在有/无 APP14 两种情况下必须给出不同结果」这类可判别的断言。

## 9. 三个阶段的遗留

- 窄窗口下侧栏收进抽屉，抽屉一关就丢掉当前浏览的目录（`BrowserSidebar` 的
  `State` 随抽屉销毁）。要保住得把目录状态提到 `ViewerPage`。暂不处理：
  真正窄的平台是手机，那儿 `canBrowse` 常常为假，目录浏览本来就不是主来源。
- 文件选择器的扩展名白名单只列已实现的格式（阶段 2 加了 `png`，阶段 3 加了
  `jpg`/`jpeg`/`jpe`/`jfif`，现在只差 webp）。**不能**照抄侧栏的
  `kBrowsableExtensions` —— 那份含所有六种格式，用户若选中一张正常的 WebP
  会得到「没有解码器认领」+「试试按裸 YUV 解码」，而这个建议是错的。每加一个
  解码器要同时看这两处，方向相反：选择器收紧，侧栏放宽。
- 命令行参数打开文件（`ImageFileSource.commandLine` 已经定义但没接线）。
- APNG 没做。`acTL`/`fcTL`/`fdAT` 都是辅助 chunk，所以现在打开一个 APNG
  会正常显示它的第一帧（默认图像）—— 不报错，只是不动。这是规范设计好的
  向后兼容行为，不是我们绕过去的。
- 16 位 PNG 一律降到 8 位。`RgbaImage` 是 RGBA8888，改不了 —— 要保住 16 位
  精度得让统一容器支持两种深度，那会波及所有格式和整个渲染路径。
- `gAMA` 只显示不应用。真正应用伽马要做色彩管理（还得处理 `sRGB`/`iCCP`
  的优先级），而阶段 5 的教学模式更需要的是「原始解码结果」。
- 像素探针、直方图、旋转翻转仍在阶段 5。`pixelAt` 已经为探针准备好了
  （见 3.11：正因为它要被返回和比较，才必须用乘法）。
- JPEG 的算术编码（SOF9..SOF11）、无损（SOF3）、层次/差分（SOF5..SOF7）都抛
  `UnsupportedImageFeature`。前者比 Huffman 高 5~10% 压缩率但专利到期得晚，
  实际产出的编码器几乎没有；后两者是和 DCT 那套完全不同的算法，实质上是另一
  种格式。
- JPEG 12 位精度没做。SOF1 允许，但需要另一套量化和 IDCT 值域 —— 和 16 位 PNG
  是同一个障碍（`RgbaImage` 是 RGBA8888）。
- EXIF 只解 0x0112 一个标签。相机型号、光圈、GPS 都在同一个 IFD 里，加起来是
  纯体力活，且不影响画面。ICC（APP2 分片）同理，还得先做色彩管理。
- CMYK / YCCK 没有交叉验证参照（见 8.1），是目前覆盖最薄的一处。要补得先找一
  个能写四分量输出的参考工具，`djpeg` 的 PNM 写不出来。
- **旋转翻转和 EXIF 方向撞车。** `applyOrientation` 已经把 D4 群八种变换都实现
  了，而阶段 5 的「旋转 90° / 水平垂直翻转」是同一件事的手动版。做那个功能时
  应该复用它，而不是在 UI 层再写一遍 —— 但它现在在 `codecs/jpeg/` 下，UI 不能
  依赖那里。到时候得把它提到 `core/`。
