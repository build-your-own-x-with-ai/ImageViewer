/// YUV → RGB 的色彩转换。
///
/// 这个文件只做数学，不碰字节布局 —— 布局在 `yuv_format.dart`，两者正交。
library;

/// 色彩转换矩阵。
///
/// 矩阵的差别只在两个系数 [kr] 与 [kb] 上（[kg] 由 `1 - kr - kb` 推出）。
/// 整条转换路径都从这两个数推导，所以加一种新标准就是加一行枚举 ——
/// 不需要抄一张新的系数表，也不会抄错。
enum YuvMatrix {
  /// ITU-R BT.601，标清电视与 JPEG。绝大多数裸 YUV 文件是这一套。
  bt601(0.299, 0.114, 'BT.601（标清 / JPEG）'),

  /// ITU-R BT.709，高清电视。720p 及以上的视频用它。
  bt709(0.2126, 0.0722, 'BT.709（高清）'),

  /// ITU-R BT.2020 非恒定亮度，4K/8K 与 HDR。
  ///
  /// 注意规范里还有一个「恒定亮度」变体（BT.2020-CL），数学完全不同，
  /// 实践中几乎不用，这里不实现。
  bt2020(0.2627, 0.0593, 'BT.2020 NCL（4K / HDR）');

  const YuvMatrix(this.kr, this.kb, this.description);

  /// 红色的亮度权重。
  final double kr;

  /// 蓝色的亮度权重。
  final double kb;

  /// 中文描述，显示在信息面板上。
  final String description;

  /// 绿色的亮度权重。三者之和恒为 1。
  double get kg => 1.0 - kr - kb;
}

/// 采样值的取值范围。
///
/// 这是**最容易被忽略、后果又最明显**的一个参数：搞错了整张图的对比度就不对
/// —— 按 full range 解 limited range 的数据，黑不够黑白不够白，图像发灰。
enum YuvRange {
  /// 演播室范围：亮度 16–235，色度 16–240。视频文件的默认。
  ///
  /// 留出上下余量是模拟时代的遗产 —— 给信号的过冲留空间。
  limited('limited（Y 16–235，UV 16–240）'),

  /// 全范围：亮度与色度都是 0–255。JPEG 与手机相机常用。
  full('full（0–255）');

  const YuvRange(this.description);

  /// 中文描述，显示在信息面板上。
  final String description;

  /// 是否是全范围。
  bool get isFull => this == YuvRange.full;
}

/// 把 [YuvMatrix] 与 [YuvRange] 的组合展开成六个乘法系数。
///
/// ## 推导
///
/// 正向定义（[YuvMatrix] 的 kr/kg/kb 就是这里的权重）：
///
/// ```
/// Y' = Kr·R + Kg·G + Kb·B
/// Pb = (B - Y') / (2(1 - Kb))
/// Pr = (R - Y') / (2(1 - Kr))
/// ```
///
/// 解出逆变换：
///
/// ```
/// R = Y' + 2(1-Kr)·Pr
/// B = Y' + 2(1-Kb)·Pb
/// G = Y' - (Kb·2(1-Kb)/Kg)·Pb - (Kr·2(1-Kr)/Kg)·Pr
/// ```
///
/// 再把范围缩放并进去：limited range 的 Y 占 219 级、色度占 224 级，
/// 都要映射回 255 级。
///
/// ## 对照表
///
/// 这样算出来的系数与教科书上的常数完全一致，可以用来自查：
///
/// | 组合 | yScale | rV | gU | gV | bU |
/// |---|---|---|---|---|---|
/// | BT.601 full | 1.000 | 1.402 | 0.344 | 0.714 | 1.772 |
/// | BT.601 limited | 1.164 | 1.596 | 0.391 | 0.813 | 2.017 |
/// | BT.709 full | 1.000 | 1.575 | 0.187 | 0.468 | 1.856 |
/// | BT.709 limited | 1.164 | 1.793 | 0.213 | 0.533 | 2.112 |
class YuvColorConverter {
  YuvColorConverter(this.matrix, this.range)
      : yScale = range.isFull ? 1.0 : 255.0 / 219.0,
        yOffset = range.isFull ? 0 : 16,
        rV = 2 * (1 - matrix.kr) * (range.isFull ? 1.0 : 255.0 / 224.0),
        bU = 2 * (1 - matrix.kb) * (range.isFull ? 1.0 : 255.0 / 224.0),
        gU = matrix.kb *
            2 *
            (1 - matrix.kb) /
            matrix.kg *
            (range.isFull ? 1.0 : 255.0 / 224.0),
        gV = matrix.kr *
            2 *
            (1 - matrix.kr) /
            matrix.kg *
            (range.isFull ? 1.0 : 255.0 / 224.0);

  final YuvMatrix matrix;
  final YuvRange range;

  /// 亮度的缩放系数：limited range 下是 255/219 ≈ 1.164。
  final double yScale;

  /// 亮度要先减掉的偏移：limited range 下是 16。
  final int yOffset;

  /// V（Cr）对红色的系数。
  final double rV;

  /// U（Cb）对绿色的系数，**减去**。
  final double gU;

  /// V（Cr）对绿色的系数，**减去**。
  final double gV;

  /// U（Cb）对蓝色的系数。
  final double bU;

  /// 把一个 YUV 采样转成 RGB，写入 [out] 的 `offset..offset+2`，
  /// 并把 `offset+3` 置为不透明。
  ///
  /// 色度的零点恒为 128（不随 range 变），因为 limited range 的 16–240
  /// 也是以 128 为中心的。
  void convert(int y, int u, int v, List<int> out, int offset) {
    final double luma = yScale * (y - yOffset);
    final double cb = (u - 128).toDouble();
    final double cr = (v - 128).toDouble();

    out[offset] = _clamp8(luma + rV * cr);
    out[offset + 1] = _clamp8(luma - gU * cb - gV * cr);
    out[offset + 2] = _clamp8(luma + bU * cb);
    out[offset + 3] = 255;
  }

  /// 截断到 0..255。
  ///
  /// 截断是**必需**的，不是保险措施：YUV 的取值空间比 RGB 大，合法的
  /// YUV 组合（如 Y=235, U=V=16）算出来会落在 RGB 立方体外面。
  static int _clamp8(double v) {
    final int i = v.round();
    if (i < 0) {
      return 0;
    }
    if (i > 255) {
      return 255;
    }
    return i;
  }

  /// 六个系数的可读形式，供信息面板与教学模式显示。
  Map<String, String> describeCoefficients() => <String, String>{
        'Y 缩放': yScale.toStringAsFixed(4),
        'Y 偏移': '$yOffset',
        'R ← V': rV.toStringAsFixed(4),
        'G ← U': '-${gU.toStringAsFixed(4)}',
        'G ← V': '-${gV.toStringAsFixed(4)}',
        'B ← U': bU.toStringAsFixed(4),
      };

  @override
  String toString() =>
      'YuvColorConverter(${matrix.name}, ${range.name}, '
      'yScale=${yScale.toStringAsFixed(3)}, rV=${rV.toStringAsFixed(3)})';
}
