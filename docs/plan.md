# 实施计划

每阶段的完成标准（缺一不可）：

1. 可运行 —— `flutter run` 起得来
2. `flutter test` 全绿
3. `flutter analyze` 零告警
4. 文档同步更新（本文件 checklist + `implementation.md` + `CHANGELOG.md`）
5. git 打 tag

---

## 阶段 1 — 地基 + BMP + PNM + YUV （`v0.1.0`）

### 工程与文档
- [x] `flutter create` 六平台
- [x] `git init`，主分支 `main`
- [x] 清空第三方依赖（去掉 `cupertino_icons` / `flutter_lints`）
- [x] `analysis_options.yaml` 显式列出 lint 规则
- [x] `docs/requirements.md`
- [x] `docs/design.md`
- [x] `docs/plan.md`
- [ ] `docs/testing.md`

### core 层
- [ ] `byte_reader.dart` —— 大小端读取 + 越界检查
- [ ] `bit_reader_msb.dart` —— JPEG 用，含 `0xFF00` 字节填充处理
- [ ] `bit_reader_lsb.dart` —— deflate / VP8L 用
- [ ] `rgba_image.dart` —— 统一像素容器 + 元数据
- [ ] `image_decoder.dart` —— 解码器接口
- [ ] `decoder_registry.dart` —— 魔数嗅探分发
- [ ] `errors.dart`
- [ ] core 层单测

### BMP
- [ ] 头部解析：CORE(12) / INFO(40) / V4(108) / V5(124)
- [ ] 1 / 4 / 8 bpp 调色板
- [ ] 16 bpp（RGB555 与 `BI_BITFIELDS` 任意掩码）
- [ ] 24 / 32 bpp
- [ ] RLE4 / RLE8 游程解码
- [ ] 自底向上与自顶向下（负 height）
- [ ] 行 4 字节对齐
- [ ] 测试 + `docs/formats/bmp.md`

### PNM
- [ ] P1 / P2 / P3（ASCII）
- [ ] P4 / P5 / P6（二进制）
- [ ] 注释与任意空白的词法处理
- [ ] maxval 1–65535（含 16 位降 8 位）
- [ ] 测试 + `docs/formats/pnm.md`

### YUV
- [ ] `YuvFormat` 布局描述子
- [ ] 平面格式：I420 / YV12 / I422 / I444
- [ ] 半平面格式：NV12 / NV21
- [ ] 打包格式：YUY2 / UYVY
- [ ] BT.601 / BT.709 × limited / full range
- [ ] 测试 + `docs/formats/yuv.md`

### UI 外壳
- [ ] `platform/` 条件导入隔离 `dart:io`
- [ ] 缩放平移视图
- [ ] 目录浏览侧栏（桌面）/ assets 列表（移动端与 Web）
- [ ] 格式信息面板
- [ ] YUV 参数对话框（尺寸与格式）
- [ ] 错误提示 UI

---

## 阶段 2 — PNG （`v0.2.0`）

- [ ] chunk 层：`IHDR` / `PLTE` / `IDAT` / `IEND` / `tRNS` / `gAMA` / `pHYs` / `tEXt`
- [ ] CRC32 自建表与校验
- [ ] **inflate 自写**：stored / 固定 Huffman / 动态 Huffman
- [ ] 规范化 Huffman 码表解码
- [ ] LZ77 32KB 滑动窗口
- [ ] 五种 filter 逆运算：None / Sub / Up / Average / Paeth
- [ ] 色彩类型 0/2/3/4/6 × 位深 1/2/4/8/16
- [ ] `tRNS` 透明
- [ ] Adam7 隔行七遍扫描
- [ ] 16 位降 8 位
- [ ] 测试 + `docs/formats/png.md`
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

- [ ] `Isolate.run` 后台解码 + Web 内联回退
- [ ] 解码进度回调
- [ ] 透明棋盘格背景
- [ ] 旋转 90° / 水平垂直翻转
- [ ] 适配模式：适配窗口 / 原始尺寸 / 填充
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
