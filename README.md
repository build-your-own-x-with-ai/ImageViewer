# ImageViewer

一个**不用任何图像解码库**的看图工具。BMP、PNM、裸 YUV、PNG、JPEG、WebP
的解析全部手写，从文件的第一个字节开始。

Flutter 六平台（macOS / iOS / Android / Linux / Windows / Web）。

## 这个项目要干什么

看图工具本身不稀奇，稀奇的是**不许用现成的解码器**。`pubspec.yaml` 里除了
`flutter_lints` 和 `cupertino_icons` 什么都没有 —— 没有 `image`，也不调
`ui.instantiateImageCodec`（那个会替你解析格式）。

唯一用到的引擎能力是 `ui.decodeImageFromPixels`：把已经排好的 RGBA 字节
传给 GPU。它不认识任何图像格式，只负责上屏。**从字节到 RGBA 的那一段，
是这个项目本身。**

所以这既是个能用的看图工具，也是一份可运行的格式教材：
`docs/formats/` 下每种格式一篇，讲清它为什么长这样、哪里有坑。

## 现在能看什么

| 格式 | 覆盖范围 |
|---|---|
| **BMP** | 六个头部版本（CORE/INFO/V2/V3/V4/V5）、1/2/4/8 bpp 调色板、16 bpp（RGB555/565/4444/任意掩码）、24/32 bpp、RLE4/RLE8、自底向上与自顶向下 |
| **PNG** | 自写 inflate（stored / 固定 / 动态 Huffman + LZ77）、五种滤波器、十五种色彩类型 × 位深组合、`tRNS` 透明、Adam7 隔行 |
| **JPEG** | 基线与渐进（SOF0/1/2）、霍夫曼 + 字节填充 + 重启间隔、两套 IDCT、4:4:4 / 4:2:2 / 4:2:0 / 4:1:1、三角滤波上采样、YCbCr / RGB / Adobe CMYK-YCCK、EXIF 方向 |
| **PNM** | P1–P6 全部六种，ASCII 与二进制，maxval 1–65535 |
| **裸 YUV** | 九种布局（I420/YV12/I422/I444/NV12/NV21/YUY2/YVYU/UYVY）× BT.601/709/2020 × limited/full range，多帧序列 |

WebP 在计划里，见 `docs/plan.md`。

后两个格式的难点来自相反的方向，这一点比覆盖范围本身更有意思：

- **PNG 一多半的代码不是 PNG。** 它自己的语义只有 IHDR 十三个字节加五个
  滤波器，复杂度全外包给了 deflate —— 而 deflate 得自己写
  （`lib/src/compress/`，阶段 4 的 WebP 会复用）。
- **JPEG 什么都不外包。** 3351 行全在 `codecs/jpeg/` 里面，而且它是唯一
  没法写成流水线的格式：量化表和码表是**可变的当前状态**，熵数据**没有长度
  字段**（扫描自己决定在哪结束），渐进模式下同一个块要被写好几遍。
  解码器因此是台状态机，不是「读头部 → 读像素」。

## 跑起来

```bash
flutter pub get
flutter run                  # 或 -d macos / -d chrome / …
```

二十四张内置样图都在仓库里，不用生成。要重新生成的话：

```bash
dart tool/gen_samples.dart        # BMP / PNM / PNG / YUV 十八张
bash tool/gen_jpeg_samples.sh     # JPEG 六张，需要 libjpeg-turbo
```

JPEG 单独一个脚本，因为**手写 JPEG 字节要先有一个编码器**（DCT + 量化 +
霍夫曼，规模和解码器本体相当）。所以这六张拿 `cjpeg` 生成，顺带用
`djpeg` 生成参考解码结果供测试比对。测试本身从不执行这些脚本。

左侧「内置样图」点开即用 —— 空手启动也有东西看，这在 Web 和移动端是
唯一的来源。

## 为什么界面长这样

界面上每个决定都是为了**让解码结果可被肉眼验证**：

- **放大用最近邻**（缩小才插值）。放大时插值会把相邻像素抹成渐变，而
  「像素边界在哪」正是要看的东西 —— 解码错位表现为一道斜纹，模糊掉就看不见了。
  最大 64 倍，够看清单个像素方格。
- **透明棋盘格**。没有它，「透明」和「白色」在屏幕上完全一样，32bpp BMP 的
  alpha 分支就没法验证。
- **YUV 参数对话框实时算余数**。裸流没有文件头，参数填错时**解码器帮不上忙**
  —— 字节数够它就照解，画出一张斜图还不报错。唯一能提前发现的信号就是
  「这组参数把文件切成几帧、余多少字节」。
- **错误提示分四类**。「没人认领」（可能是裸流，建议手填参数）、「认领了但
  数据坏了」（给出字节偏移，可以拿 hex 编辑器跳过去）、「格式合法但特性
  没实现」、「连文件都没读到」（权限问题）。四种情况的下一步动作完全不同，
  糊成一句「加载失败」等于把解码器辛苦区分出来的信息全扔了。

## 测试

```bash
flutter test      # 731 个
flutter analyze   # 零告警
```

二十四张内置样图各自针对一个具体陷阱（行 4 字节对齐、自顶向下、RLE 增量跳转、
YUV 尺寸错配、Adam7 七遍扫描、16 位缩放的取整方向、渐进 JPEG 的十趟扫描……），
`test/assets/samples_test.dart` 逐张验证它们确实还在踩那个陷阱 ——
样图退化成「一张普通的图」就失去意义了。

有损格式还多一层：JPEG 按规范（ITU T.83）不要求 IDCT 位精确，所以容差得有
依据。实测我们和 `djpeg -dct int` 在一张 q90 4:4:4 图上差 34 个通道（最大 2），
而 **libjpeg 自己的两种 IDCT 差 67 个通道** —— 有了这个数，`tolerance: 2` 就
不是调出来的魔数。量化越粗分歧越少，所以 4:2:0 和灰度那两张写的是
`tolerance: 0`。

文档里的字节也被钉进了测试，三种格式各有一组。`docs/formats/png.md` 结尾那张
2×2 PNG 的 82 字节必须真能解出预期结果；`docs/formats/yuv.md` 那 12 个字节按
I420 和按 NV12 解出来必须是不同的颜色；`docs/formats/jpeg.md` 里那张 482 字节
灰度图，手算出的第一个 DC 系数（-182 → 整块 14.25）必须和 `djpeg` 输出的行均值
相等。改了解码器而文档没跟上，测试会失败。

## 文档

| 文件 | 内容 |
|---|---|
| `docs/requirements.md` | 要做成什么 |
| `docs/design.md` | 打算怎么做 |
| `docs/implementation.md` | 实际做成了什么，以及踩过的坑 |
| `docs/plan.md` | 分阶段 checklist |
| `docs/testing.md` | 测试策略 |
| `docs/formats/*.md` | 每种格式一篇 |

注释和文档都是中文，且解释的是**为什么**这么写，而不是复述代码在做什么。
