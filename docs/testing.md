# 测试说明

## 铁律：`flutter test` 不调用任何外部命令

样图由 `tool/gen_fixtures.sh` **一次性生成后提交进仓库**。该脚本只是生成记录，保证可复现；CI 与日常测试都不执行它，只读已提交的文件。这样测试在任何机器上都能跑，不要求装 `sips` 或 `cwebp`。

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

`assets/samples/` 与 `test/fixtures/` 下的真实文件，覆盖手写字节难以覆盖的复杂情况：动态 Huffman 的 PNG、渐进式 JPEG、VP8 有损 WebP。

生成方式记录在 `tool/gen_fixtures.sh`，全部保持极小尺寸（多为 16×16 或 32×32）以免仓库膨胀。

### 3. 交叉验证：以 PPM 为参照闭环

这是本项目验证正确性的主要手段，也是一个有点巧妙的设计。

PNM 是最简单的格式，我们的 PNM 解码器可以先被手写字节测试彻底验证。一旦它可信，就能把它当作**参照解码器**：

```
真实 foo.png ──[系统 codec, 生成期望值时一次性]──> foo.expected.ppm  (提交进仓库)
      │                                                    │
      │ 我们的 PNG 解码器                                    │ 我们的 PNM 解码器（已验证可信）
      ▼                                                    ▼
   RgbaImage  ──────────── 逐像素比对 ────────────────>  RgbaImage
```

好处是期望值以人类可读的文本/简单二进制形式存在仓库里，出错时能直接看出哪个像素不对，而不是面对一堆不可读的二进制 golden 文件。

### 4. 容差断言

JPEG 的 IDCT 是浮点运算，不同实现（我们的朴素版、我们的 AAN 版、libjpeg）结果会有 ±1~2 的差异，这是规范允许的。所以比对用逐通道容差而非严格相等：

```dart
expectPixelsClose(actual, expected, tolerance: 2);
```

无损格式（BMP / PNM / PNG / VP8L）必须 `tolerance: 0` 严格相等 —— 无损就是无损，差一个字节就是 bug。

## 目录结构

```
test/
  core/            ByteReader、两种 BitReader、RgbaImage
  codecs/
    bmp_test.dart  pnm_test.dart  yuv_test.dart
    png_test.dart  jpeg_test.dart  webp_test.dart
  support/
    pixel_matchers.dart   容差比对助手
    byte_builders.dart    手写字节的辅助构造器
  fixtures/        提交进仓库的真实样图与 .expected.ppm
```

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
