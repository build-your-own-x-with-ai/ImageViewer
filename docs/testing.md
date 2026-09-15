# 测试说明

## 铁律：`flutter test` 不调用任何外部命令

样图由生成脚本**一次性生成后提交进仓库**。脚本只是生成记录，保证可复现；
CI 与日常测试都不执行它们，只读已提交的文件。这样测试在任何机器上都能跑，
不要求装 libjpeg-turbo 或 `cwebp`。

两个脚本，分工不同：

| 脚本 | 产出 | 为什么是这个形式 |
|---|---|---|
| `tool/gen_samples.dart` | BMP / PNM / PNG / YUV 样图 | 纯 Dart 手写字节。PNG 的像素数据用 `dart:io` 的 `ZLibCodec` 压缩 —— **压**是允许的，我们自己写的是**解** |
| `tool/gen_jpeg_samples.sh` | JPEG 样图 + `djpeg` 参考解码 | 手写 JPEG 字节要先有一个 DCT + 量化 + Huffman 编码器，规模和解码器本体相当。所以拿 libjpeg-turbo 的 `cjpeg` 当生成器 |

参考解码结果放在 `test/assets/expected/` 而**不是** `assets/samples/` ——
后者会被 `pubspec.yaml` 整个打进应用包，测试数据不该进包。

理由与边界（尤其是「`djpeg` 是解码器，拿它当参照算不算破规则」）记在
`implementation.md` 第 8 节。

## 四类测试

### 1. 内联手写字节数组

极小图（1×1、2×2）与边界情况，字节直接写在测试文件里：

```dart
final bmp = Uint8List.fromList([
  0x42, 0x4D,             // 'BM'
  0x46, 0x00, 0x00, 0x00, // 文件大小 70
  ...
]);
```

**这是首选方式**。好处是测试本身就是格式教材 —— 读测试即可看懂头部布局，不需要 hex 编辑器。畸形输入测试（截断、尺寸溢出、CRC 错误）也全部走这条路。

### 2. 真实样图

`assets/samples/` 下的真实文件，覆盖手写字节难以覆盖的复杂情况：动态
Huffman 的 PNG、Adam7 隔行、渐进式 JPEG（10 趟扫描）、VP8 有损 WebP。

「手写字节难以覆盖」不是嫌麻烦。有些位模式**人写不出来**：真实的动态
Huffman 块要先做频率统计再构造最优码表；cjpeg 默认的渐进扫描脚本有 10 趟，
四条熵解码路径全都要走到。这类覆盖只能借助参考实现生成。

全部保持极小尺寸（多为 16×16 到 96×64）以免仓库膨胀 —— 最大的 JPEG 样图
1274 字节。

### 3. 交叉验证：以 PNM 为参照闭环

这是本项目验证正确性的主要手段，也是一个有点巧妙的设计。

PNM 是最简单的格式，我们的 PNM 解码器可以先被手写字节测试彻底验证。一旦它
可信，就能把它当作**参照解码器**：

```
真实 foo.jpg ──[参考实现，生成期望值时一次性]──> expected/foo.pnm  (提交进仓库)
      │                                                  │
      │ 我们的 JPEG 解码器                                 │ 我们的 PNM 解码器（已验证可信）
      ▼                                                  ▼
   RgbaImage  ──────────── 逐像素比对 ──────────────>  RgbaImage
```

好处是期望值以人类可读的文本/简单二进制形式存在仓库里，出错时能直接看出
哪个像素不对，而不是面对一堆不可读的二进制 golden 文件。

有损格式还多一道：**每张 JPEG 同时和压缩前的原图比**。两个参照都需要 ——
我们和 libjpeg 同属 islow IDCT 家族，有可能一起错；而量化损失把源图比对的
容差推到 8，单靠它抓不住多少东西。

### 4. 容差断言

JPEG 的 IDCT 按规范（ITU T.83）不要求位精确，只给容差。所以比对用逐通道
容差而非严格相等：

```dart
expectImageMatches(actual, expected, tolerance: 2);
```

容差值不是调出来的，是量出来的：同一张 q90 4:4:4 图上，我们和 `djpeg -dct int`
差 34 个通道（最大 2），而 **libjpeg 自己的 islow 和 float 差 67 个通道**。
详见 `implementation.md` 第 5.2 节。

量化越粗，非零系数越少，分歧越消失 —— 所以 q75 4:2:0 和 q85 灰度那两张写的
是 `tolerance: 0`。**能写 0 的地方一定要写 0**：4:2:0 那张同时钉住了 IDCT 和
三角滤波上采样，是整组里最有价值的断言。

无损格式（BMP / PNM / PNG / VP8L）必须 `tolerance: 0` 严格相等 —— 无损就是
无损，差一个字节就是 bug。

## 目录结构

```
test/
  core/            ByteReader、两种 BitReader、RgbaImage
  compress/        adler32、huffman、inflate
  codecs/
    bmp_test.dart  pnm_test.dart  yuv_test.dart  png_test.dart
    jpeg_test.dart         码表、量化、IDCT、marker
    jpeg_scan_test.dart    熵解码：基线与渐进四条路径
    jpeg_decoder_test.dart 整文件端到端与状态机
    jpeg_color_test.dart   色彩空间推断与转换
    jpeg_exif_test.dart    APP1 与八种方向
    jpeg_upsample_test.dart 上采样两种滤波
  support/
    pixel_matchers.dart   容差比对助手
    byte_builders.dart    手写字节的辅助构造器
    bmp_builders.dart     各格式的字节组装器
    png_builders.dart
    deflate_builders.dart
    jpeg_builders.dart    含一个「平坦色块」编码器，见下
  ui/              error_view_test.dart
  assets/
    samples_test.dart     样图与嗅探
    expected/             djpeg 参考解码结果（.pnm）
```

一个格式的测试拆成几个文件不是按代码文件切的，是按**能独立判定的东西**切的。
`jpeg_scan_test.dart` 喂位流断言系数，`jpeg_decoder_test.dart` 喂整个文件断言
像素 —— 前者失败说明熵解码错了，后者失败说明装配错了。混在一个文件里就分不清。

### 有损格式的单元测试：平坦色块

JPEG 没法像 PNG 那样手写像素字节，但可以手写**一种**图：DC-only 的块 IDCT 出
常数 `DC/8 + 128`，所以

```dart
dcCoefficient = (sample - 128) * 8   // 范围 -1024..1016，落在 ±2047 内
```

能渲出一个精确已知的样本值。`test/support/jpeg_builders.dart` 就围绕这个建了
一个小编码器（463 行），能拼出任意尺寸、任意抽样因子、带或不带重启间隔、基线
或渐进的完整文件。

它的价值在于**流水线任何一环错了结果都会变**：量化表接错则亮度偏移、MCU 顺序
错则分量串色、上采样错则边缘破、重启 marker 位置错则后半张图错位。一个能精确
预测的期望值，比一堆「看着差不多」的容差断言管得多。

## 运行

```bash
flutter test                              # 全部
flutter test test/codecs/bmp_test.dart    # 单个格式
flutter analyze                           # 静态分析，要求零告警
```

## 每种格式的必测清单

无论哪个格式，以下几类必须都有用例：

1. **最小有效图** —— 1×1，验证基本通路
2. **奇数尺寸** —— 如 3×5，验证行对齐/块填充逻辑（这是 bug 高发区）
3. **各位深/子格式全覆盖**
4. **畸形输入** —— 截断的文件、声明尺寸与实际数据不符、非法枚举值，都必须抛 `ImageDecodeException` 而不是崩溃或返回错图
5. **尺寸溢出** —— 声明 `width * height` 溢出 int 的恶意文件

第 4、5 项容易被忽略，但对"不信任输入"这个原则来说是核心。

## 一条额外的要求：用例得**有可能失败**

上面五项说的是「测什么」，这一条说的是「怎么测」。一个永远通不掉的用例是
bug，一个永远通得过的用例也是 bug —— 后者更危险，因为它看着是绿的。

阶段 3 踩到两次，都值得记下来：

- `adobeSegment` 的 `transform` 字节位置写错了一格，而**错位后读到的也是 0**，
  于是 CMYK 那条路径「碰巧通过」。是 YCCK 用例（transform=2）把它揪出来的。
  改法：让「有 APP14」和「无 APP14」的四分量文件**用同一组样本值**，断言结果
  **不同**。标志一旦接错线，两个用例就会给出同一个答案。
- 两个 DQT 覆盖顺序的用例，只写一个方向（先 fill=2 再 fill=1）是不够的 ——
  「后者覆盖前者」和「前者被忽略」会给出同样的结果。两个方向都写，得到 160
  和 192 两个不同的数，才真的钉住了覆盖方向。

推论：**期望值不能从被测代码推导**。EXIF 方向那组的期望是从几何关系
`new(dx,dy) = base(dy, H-1-dx)` 算的，不是拿 `applyOrientation` 跑一遍存下来
的 —— 否则它只能证明函数和自己一致。相关的另一面见 `implementation.md`
第 3.12 节。

## 还有一条：查测试的工具也会静默失败

上一节说的是用例本身。这一节说的是**你用来找用例的东西**。

阶段 3 收尾时要确认「png.md 声称的那一组测试真的存在」，`grep` 在
`test/codecs/png_test.dart` 上返回了空。文件 1953 行，测试一直全绿。空结果的
原因是里面有一个**字面的 NUL 字节** —— 一个本该写成 `\x00` 的字符串字面量：

```dart
pngChunk('a1\x00!', const <int>[]),   // 对
pngChunk('a1<NUL>!', const <int>[]),  // 阶段 2 实际留下的
```

Dart 编译器不在乎，用例照跑照过。但 `grep` 按 POSIX 把含 NUL 的文件判成二进制，
于是**不报错、不警告，直接什么都不返回**。`grep -c` 返回 0，看起来和「确实没有
这一组」一模一样。

两条教训：

- **空的搜索结果不等于「不存在」**。真要下「代码里没有 X」这种结论，先确认
  搜索本身是有效的 —— 换个工具（`grep -a`、Python、编辑器）对一下，或者反过来
  搜一个你**确知存在**的串，看看能不能搜到。
- 顺手扫一遍全仓库比事后追查便宜。一段几行的脚本遍历 `.dart`/`.md`/`.yaml`/
  `.sh`/`.json`，检查 NUL 字节和 UTF-8 合法性，就能把这类「文件对编译器正常、
  对文本工具隐身」的问题一次筛掉。

这件事本身没有改变任何测试的行为 —— 修完之后字符串的值一个比特没变。它改变的
是「仓库能不能被可靠地检索」，而文档与代码的同步全靠这件事成立。
