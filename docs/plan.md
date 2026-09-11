# 实施计划

每阶段的完成标准（缺一不可）：

1. 可运行 —— `flutter run` 起得来
2. `flutter test` 全绿
3. `flutter analyze` 零告警
4. 文档同步更新（本文件 checklist + `implementation.md` + `CHANGELOG.md`）
5. git 打 tag

---

## 阶段 1 — 地基 + BMP + PNM + YUV （`v0.1.0`）

> 收口于 2026-09-07。五条标准：`flutter run` ✅ / 305 测试 ✅ /
> analyze 零告警 ✅ / 文档同步 ✅ / **tag 漏了**（当时没打，`v0.1.0`
> 事后补在 `889292a` 上）。
>
> 这一条漏了三天没人发现，正说明**完成标准得逐条记下来**，光写在文件
> 开头当口号不够。所以从阶段 2 起每个阶段都留这么一段。

### 工程与文档
- [x] `flutter create` 六平台
- [x] `git init`，主分支 `main`
- [x] 依赖收敛：不引入任何解码库；`cupertino_icons` / `flutter_lints` 保留（与解码无关）
- [x] `analysis_options.yaml` 接上 `flutter_lints`，再按解码器的风险加严
- [x] `docs/requirements.md`
- [x] `docs/design.md`
- [x] `docs/plan.md`
- [x] `docs/testing.md`

### core 层
- [x] `byte_reader.dart` —— 大小端读取 + 越界检查
- [x] `bit_reader_msb.dart` —— JPEG 用，含 `0xFF00` 字节填充处理
- [x] `bit_reader_lsb.dart` —— deflate / VP8L 用
- [x] `rgba_image.dart` —— 统一像素容器 + 元数据
- [x] `image_decoder.dart` —— 解码器接口
- [x] `decoder_registry.dart` —— 魔数嗅探分发
- [x] `errors.dart`
- [x] core 层单测（67 个）

### BMP
- [x] 头部解析：CORE(12) / INFO(40) / V2(52) / V3(56) / V4(108) / V5(124)
- [x] 1 / 2 / 4 / 8 bpp 调色板（2bpp 是 Windows CE 的扩展，顺手支持）
- [x] 16 bpp（RGB555 / RGB565 / 4-4-4-4 / 任意 `BI_BITFIELDS` 掩码）
- [x] 24 / 32 bpp（含 32bpp alpha 的启发式判断）
- [x] RLE4 / RLE8 游程解码（含绝对模式填充与增量跳转）
- [x] 自底向上与自顶向下（负 height）
- [x] 行 4 字节对齐
- [x] 测试（76 个）+ `docs/formats/bmp.md`

### PNM
- [x] P1 / P2 / P3（ASCII）
- [x] P4 / P5 / P6（二进制）
- [x] 注释与任意空白的词法处理
- [x] maxval 1–65535（含 16 位降 8 位）
- [x] 测试（38 个）+ `docs/formats/pnm.md`

### YUV
- [x] `YuvFormat` 布局描述子（九种格式 → 三个循环）
- [x] 平面格式：I420 / YV12 / I422 / I444
- [x] 半平面格式：NV12 / NV21
- [x] 打包格式：YUY2 / YVYU / UYVY
- [x] BT.601 / BT.709 / BT.2020 × limited / full range（六个系数全由 kr/kb 推导）
- [x] 奇数尺寸色度平面向上取整 + 最近邻上采样
- [x] 多帧序列（`frameIndex`）与参数错配时反推高度
- [x] 测试（64 个）+ `docs/formats/yuv.md`

### UI 外壳
- [x] `platform/` 条件导入隔离 `dart:io`
- [x] 缩放平移视图（放大用最近邻、缩小用线性）
- [x] 系统文件选择器（各平台通用，只取字节不解析）
- [x] 目录浏览侧栏（桌面）/ assets 列表（各平台）
- [x] 格式信息面板（走 `metadata.toDisplayMap()`，加格式不用改 UI）
- [x] YUV 参数对话框（尺寸与格式，实时算帧数与余数）
- [x] 错误提示 UI（按四类异常分开给建议）
- [x] macOS 沙盒 entitlement（`files.user-selected.read-only`）
- [x] 十二张内置样图 + 生成脚本 `tool/gen_samples.dart`
- [x] 样图测试（51 个）+ widget 测试（9 个）

---

## 阶段 2 — PNG （`v0.2.0`）

> 收口于 2026-09-10。五条标准：`flutter run` ✅ / 496 测试 ✅ /
> analyze 零告警 ✅ / 文档同步 ✅ / tag `v0.2.0` ⏳（待打）。
>
> 计划里这一阶段写作「PNG」，做下来发现一多半工作量在 `compress/`：
> PNG 自己的语义只有 IHDR 十三个字节加五个滤波器，而 deflate 是一整个
> 解压器。所以拆成两组来记。详见 `implementation.md` 第 4 节。

### compress 层（独立于 PNG，阶段 4 的 VP8L 会复用）
- [x] `adler32.dart` —— zlib 尾部校验（覆盖解压后的字节）
- [x] `huffman.dart` —— 规范化 Huffman 码表解码，含 Kraft 不等式检查
- [x] `deflate_tables.dart` —— 长度/距离码表与 HCLEN 传输顺序
- [x] **inflate 自写**：stored / 固定 Huffman / 动态 Huffman
- [x] LZ77 回溯，最大距离 32768（重叠拷贝逐字节）
- [x] 解压炸弹防护（`sizeLimit` 在写入前拦截）
- [x] compress 层单测（67 个：adler32 11 / huffman 17 / inflate 39）

### PNG
- [x] chunk 层：`IHDR` / `PLTE` / `IDAT` / `IEND` / `tRNS` / `gAMA` / `pHYs` / `tEXt`
- [x] CRC32 自建表与校验（`0xEDB88320`，覆盖类型 + 数据）
- [x] 八字节签名嗅探（每个字节各防一种传输事故）
- [x] 五种 filter 逆运算：None / Sub / Up / Average / Paeth
- [x] 色彩类型 0/2/3/4/6 × 位深 1/2/4/8/16（十五种合法组合）
- [x] `tRNS` 透明（调色板 / 灰度键色 / RGB 键色三种格式）
- [x] Adam7 隔行七遍扫描
- [x] 16 位降 8 位（四种位深缩放，调色板索引不缩放）
- [x] 顺序约束校验（IHDR 首 / IEND 尾 / PLTE 先于 IDAT / IDAT 连续）
- [x] 六张 PNG 样图（含 Adam7、16 位灰度、1 位、调色板、RGBA）
- [x] 测试（97 个）+ `docs/formats/png.md`
- [ ] 可选：APNG

## 阶段 3 — JPEG （`v0.3.0`）

- [ ] marker 扫描：SOI / APPn / DQT / SOF0 / SOF2 / DHT / SOS / DRI / RSTn / COM / EOI
- [ ] Huffman 解码（含字节填充与重启间隔）
- [ ] 反量化 + zigzag 反序
- [ ] `IdctNaive` 朴素二维定义式
- [ ] `IdctAan` 快速蝶形
- [ ] 任意采样因子 4:4:4 / 4:2:2 / 4:2:0 / 4:1:1
- [ ] 色度上采样
- [ ] YCbCr→RGB / 灰度 / Adobe CMYK-YCCK（APP14）
- [ ] 渐进式 SOF2：DC 首扫与精化、AC 首扫与精化、EOB run、频谱选择
- [ ] APP1 EXIF 方向
- [ ] 测试 + `docs/formats/jpeg.md`

## 阶段 4 — WebP （`v0.4.0`）

- [ ] RIFF 容器与 chunk 分派
- [ ] **VP8L 无损**：前缀码组、meta-Huffman 熵图像、颜色缓存、LZ77 反向引用与距离映射
- [ ] VP8L 四种变换：预测器(14 种) / 颜色变换 / 减绿 / 调色板(含像素打包)
- [ ] **VP8 有损**：布尔算术解码器
- [ ] VP8 帧头、分段、量化
- [ ] 帧内预测：16×16 四种 / 4×4 十种 / 色度四种
- [ ] token 解码含 WHT
- [ ] 反量化 + IDCT + 预测重建
- [ ] 环路滤波（simple + normal）
- [ ] `ALPH` 透明通道（原始与无损压缩两路 + 预处理滤波）
- [ ] 测试 + `docs/formats/webp.md`
- [ ] 可选：ANMF 动画

## 阶段 5 — 打磨与教学 （`v1.0.0`）

> 有四项在阶段 1 就落地了 —— 不是抢进度，而是它们是**让阶段 1 的解码结果
> 可被肉眼验证的最低条件**：缩放不到原始尺寸就看不出行对齐错没错，没有棋盘格
> 就分不清「透明」和「白色」。计划把它们归到本阶段，是按「界面功能」分的类；
> 实现时才发现该按「验证能力」分。详见 `implementation.md` 第 2.2 节。

- [x] `Isolate.run` 后台解码 + Web 内联回退（阶段 1 提前落地）
- [ ] 解码进度回调
- [x] 透明棋盘格背景（阶段 1 提前落地）
- [ ] 旋转 90° / 水平垂直翻转
- [x] 适配模式：适配窗口 / 原始尺寸 / 填充（阶段 1 提前落地）
- [x] 缩放平移视图（阶段 1 提前落地，放大用最近邻、缩小用线性）
- [ ] 像素探针（悬停显示坐标与 RGBA）
- [ ] 直方图
- [ ] 教学模式：PNG filter 分阶段对比
- [ ] 教学模式：JPEG DCT 系数与量化表热图
- [ ] 教学模式：WebP 预测器分布图
- [ ] 教学模式：YUV 三平面分离显示
- [ ] 可访问性：语义标签与键盘操作
- [ ] CI（GitHub Actions：analyze + test）
- [ ] `docs/implementation.md` 终稿
- [ ] 教学导览 `docs/tutorial.md`
