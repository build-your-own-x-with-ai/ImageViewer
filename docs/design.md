# 设计文档

## 1. 总体数据流

```
文件字节 (Uint8List)
      │
      ▼
DecoderRegistry.sniff()        魔数嗅探，不看扩展名
      │
      ▼
ImageDecoder.decode()          纯 Dart，格式相关的全部工作在这里
      │
      ▼
RgbaImage                      统一中间表示：RGBA8888 直排
      │
      ▼
ui.decodeImageFromPixels()     唯一的引擎调用，只做 GPU 上传
      │
      ▼
ui.Image → RawImage widget     上屏
```

关键设计取舍：**所有解码器都归一到 RGBA8888**。代价是灰度图和调色板图会多占内存，收益是上层（UI、像素探针、直方图、测试断言）只需面对一种像素布局。教学项目里这个简化是值得的。

## 2. 分层

```
lib/src/
  core/         与格式无关的基础设施
  compress/     通用压缩算法（PNG 与 WebP ALPH 共用 inflate）
  codecs/       六个格式各一个子目录
  ui/           Widget 层
  platform/     dart:io 隔离（条件导入）
```

依赖方向严格单向：`ui → codecs → compress → core`。`codecs` 不允许 import `ui` 或 `dart:io`，保证解码器是可单测的纯函数。

## 3. core 层

### 3.1 ByteReader

顺序读取器，维护 `offset`，提供 `u8 / u16le / u16be / u32le / u32be / i32le / bytes(n) / skip(n)`。

每次读取前做越界检查并抛 `ImageDecodeException`。**不信任文件内声明的任何长度字段** —— 畸形文件最常见的攻击面就是声明一个巨大的宽高或 chunk 长度。

### 3.2 位读取器：为什么要两个

这是初学者最容易踩的坑。两种格式族的位序完全相反：

| | 填充方向 | 用于 |
|---|---|---|
| `BitReaderMsb` | 从字节高位往低位取 | JPEG 熵编码 |
| `BitReaderLsb` | 从字节低位往高位取 | deflate（PNG）、VP8L（WebP） |

举例：字节 `0b1011_0010`，读 3 位

- MSB 优先 → `101` = 5
- LSB 优先 → `010` = 2

两者不可混用，所以做成两个独立类而非一个带 flag 的类 —— 类型系统直接阻止用错。

`BitReaderMsb` 还要处理 JPEG 特有的**字节填充**：熵编码数据里 `0xFF` 后面跟 `0x00` 时，`0x00` 是填充物要丢弃；跟其它值则是 marker，说明数据段结束。

### 3.3 RgbaImage

```dart
class RgbaImage {
  final int width, height;
  final Uint8List pixels;   // length == width * height * 4，R,G,B,A 顺序
  final ImageMetadata metadata;
}
```

`metadata` 承载格式相关信息给信息面板与教学模式用（原始位深、色彩类型、压缩方式、子采样因子等），设计成 `Map<String, Object>` 加若干具名字段，避免为六种格式各造一个元数据类。

### 3.4 ImageDecoder 与注册表

```dart
abstract class ImageDecoder {
  String get name;
  bool canDecode(Uint8List bytes);   // 看魔数
  RgbaImage decode(Uint8List bytes);
}
```

`DecoderRegistry` 遍历已注册解码器调 `canDecode`。YUV 没有魔数，`canDecode` 恒返回 false，只能显式调用 —— 这也是它需要用户提供尺寸/格式参数的必然结果。

## 4. 各格式设计要点

### 4.1 BMP

难点不在压缩而在**头部版本繁多**。用一个 `BmpHeader.parse` 按 `biSize` 分派到 CORE(12) / INFO(40) / V4(108) / V5(124)。

行对齐：每行按 4 字节对齐补齐，`rowStride = ((width * bpp + 31) ~/ 32) * 4`。这个公式初学者常写错。

`height` 为负表示自顶向下，正表示自底向上（默认，行序颠倒）。

### 4.2 PNM

最简单，适合第一个动手实现。P1/P2/P3 是 ASCII，P4/P5/P6 是二进制。词法分析要跳过 `#` 注释和任意空白。

P4（二进制位图）每行按字节对齐，这点和 P5/P6 不同。

### 4.3 YUV

没有容器，纯平面数据。核心是两件事：

**平面布局**。I420 是 Y 全平面 + U 半分辨率 + V 半分辨率；NV12 是 Y + UV 交织；YUY2 是 `Y0 U Y1 V` 打包。用一个 `YuvFormat` 描述子把布局参数化，避免为每种格式写一遍循环。

**色彩转换矩阵**。BT.601 与 BT.709 系数不同，limited range (16–235) 与 full range (0–255) 缩放不同。写成矩阵参数，四种组合共用一条转换路径。

### 4.4 PNG

分三段独立实现，各自可单测：

1. **chunk 层**：`长度(4) + 类型(4) + 数据 + CRC32(4)`，CRC 表自建
2. **inflate**：见 §5
3. **重建层**：filter 逆运算 + 位深/色彩类型展开 + Adam7

Adam7 隔行是七遍独立的子图，每遍有自己的宽高和 filter 起始 —— 最容易出错的地方是每遍的 `bytesPerRow` 要按该遍的实际宽度重算。

### 4.5 JPEG

marker 驱动的状态机。IDCT **保留两套实现可运行时切换**：

- `IdctNaive`：直接按二维定义式双重求和，O(n⁴)，慢但一眼看懂数学
- `IdctAan`：AAN 快速算法，行列分离蝶形，实际使用

教学价值在于对照：先用朴素版确认正确性，再用快速版说明工程优化，两者输出差异应在 ±1 内。

渐进式的复杂度在于同一系数要跨多个 scan 逐步精化，需要把整幅图的系数矩阵全部保留在内存里直到所有 scan 结束，而非基线那样逐 MCU 出像素。

### 4.6 WebP

RIFF 容器下**两套完全独立的编解码器**，这是 WebP 最反直觉的地方：

- `VP8L`：无损，基于 LZ77 + Huffman + 四种变换，思路接近 PNG
- `VP8`：有损，基于 DCT + 帧内预测 + 环路滤波，思路接近 JPEG 但更复杂

两者共享的只有容器解析和最终的 RGBA 输出。VP8L 的 meta-Huffman（用一张"熵图像"给不同区域指定不同 Huffman 码表）是全项目最精巧的设计。

## 5. inflate 设计

PNG 与 WebP ALPH 共用，独立成 `lib/src/compress/inflate.dart`。

三种块类型：stored（原样）、固定 Huffman（码表写死在规范里）、动态 Huffman（码表本身也是 Huffman 编码的）。

Huffman 解码用**规范化码表**：按码长排序后，同码长的码字连续递增，于是可以只存每个码长的首码字与计数，逐位比较即可解码，无需建树。这比树结构省内存也更快，且实现只需二十行 —— 但需要理解"规范 Huffman 码"这个概念，文档里要讲清。

LZ77 回溯用 32KB 环形窗口。长度/距离码有额外位，表格写死在规范里。

## 6. 平台隔离

```dart
// platform/file_source.dart
export 'file_source_stub.dart' if (dart.library.io) 'file_source_io.dart';
```

`FileSource` 抽象出 `listDirectory` / `readFile` / `canBrowse`。Web 与移动端拿到的是 stub（`canBrowse == false`），UI 据此隐藏目录浏览侧栏，只显示 assets 样图列表。

## 7. 并发

`Isolate.run(() => registry.decode(bytes))`。解码器是纯函数且只吃 `Uint8List`、只吐 `RgbaImage`（都可跨 isolate 传输），天然适合。

Web 无 isolate，用 `kIsWeb` 判断走内联同步路径。这是分层设计的直接收益：解码器本身不需要知道自己跑在哪。

## 8. 测试策略

四条路并用，详见 `testing.md`：

1. 内联手写字节数组 —— 极小图与边界情况，自解释
2. 真实样图 —— `sips` / `cwebp` 一次性生成后提交进仓库，测试只读文件不调外部命令
3. 交叉验证 —— 参考实现转出的 PPM 作为期望像素（PPM 我们自己能解，形成闭环）
4. 容差断言 —— JPEG 的 IDCT 差异允许 ±2，不做硬性逐字节相等
