import 'package:image_viewer/src/core/errors.dart';

/// 平面的组织方式。
///
/// YUV 文件没有容器、没有魔数、没有头部 —— 里面就是裸的采样数据。所以布局
/// 必须由外部告知。好在布局只有三种大类，参数化之后一套循环能覆盖全部格式。
enum YuvLayout {
  /// 三个平面依次排列：Y 全平面，然后两个半（或全）分辨率的色度平面。
  planar('三平面分离'),

  /// 两个平面：Y 全平面，然后 U 与 V 逐字节交织的单个平面。
  ///
  /// 硬件解码器偏爱这种布局 —— 色度只需一次内存访问。
  semiPlanar('双平面（色度交织）'),

  /// 单平面：亮度与色度按宏像素打包，如 `Y0 U Y1 V` 表示两个像素。
  packed('单平面（打包）');

  const YuvLayout(this.description);

  /// 中文描述，显示在信息面板上。
  final String description;
}

/// 一种具体的 YUV 像素格式。
///
/// ## 为什么用描述子而不是每种格式写一遍
///
/// 九种格式的差别只在四个维度上：平面怎么排、色度抽样多少、U 和 V 谁在前、
/// 打包时亮度和色度谁在前。把这四个维度做成字段，解码器就只需要三条循环
/// （对应三种 [YuvLayout]），而不是九个分支。
///
/// 加一种新格式的成本因此是「加一行枚举」，不是「加一个函数」。
enum YuvFormat {
  /// Y 平面 + U 平面 + V 平面，色度水平垂直各减半。最常见的视频格式。
  i420('I420', YuvLayout.planar, '4:2:0', 2, 2, uFirst: true, aka: 'YU12'),

  /// 同 I420 但 V 平面在前。Android 相机与部分播放器用它。
  yv12('YV12', YuvLayout.planar, '4:2:0', 2, 2, uFirst: false),

  /// 色度只做水平减半，垂直保持全分辨率。专业采集常用。
  i422('I422', YuvLayout.planar, '4:2:2', 2, 1, uFirst: true, aka: 'YUV422P'),

  /// 不抽样，三个平面同尺寸。唯一无损的一种。
  i444('I444', YuvLayout.planar, '4:4:4', 1, 1, uFirst: true, aka: 'YUV444P'),

  /// Y 平面 + UV 交织平面。硬件解码器的默认输出。
  nv12('NV12', YuvLayout.semiPlanar, '4:2:0', 2, 2, uFirst: true),

  /// 同 NV12 但交织顺序是 VU。Android 的 `ImageFormat.NV21`。
  nv21('NV21', YuvLayout.semiPlanar, '4:2:0', 2, 2, uFirst: false),

  /// 打包成 `Y0 U Y1 V`，两个像素占四字节。
  yuy2('YUY2', YuvLayout.packed, '4:2:2', 2, 1,
      uFirst: true, lumaFirst: true, aka: 'YUYV / V422'),

  /// 打包成 `Y0 V Y1 U`，色度顺序与 YUY2 相反。
  yvyu('YVYU', YuvLayout.packed, '4:2:2', 2, 1,
      uFirst: false, lumaFirst: true),

  /// 打包成 `U Y0 V Y1`，色度在前。DV 与部分采集卡用它。
  uyvy('UYVY', YuvLayout.packed, '4:2:2', 2, 1,
      uFirst: true, lumaFirst: false, aka: 'UYNV / Y422');

  const YuvFormat(
    this.label,
    this.layout,
    this.samplingLabel,
    this.subX,
    this.subY, {
    required this.uFirst,
    this.lumaFirst = true,
    this.aka = '',
  });

  /// 格式名，如 `I420`。
  final String label;

  /// 平面组织方式。
  final YuvLayout layout;

  /// 抽样记号，如 `4:2:0`。
  ///
  /// 这个记号不是简单的公式能推出来的（J:a:b 里 J 是概念上的取样宽度），
  /// 所以直接写成字段而不是从 [subX] / [subY] 推导。
  final String samplingLabel;

  /// 色度在水平方向的抽样因子：2 表示每两个亮度共用一个色度。
  final int subX;

  /// 色度在垂直方向的抽样因子。
  final int subY;

  /// U 是否排在 V 之前。
  ///
  /// 这一个布尔值同时区分了 I420/YV12、NV12/NV21、YUY2/YVYU 三对格式 ——
  /// 它们的唯一差别就是色度顺序。
  final bool uFirst;

  /// 打包布局里亮度是否在宏像素的开头。仅 [YuvLayout.packed] 有意义。
  final bool lumaFirst;

  /// 同一格式的其他常见叫法，显示在信息面板上帮助对照。
  final String aka;

  /// 色度平面的宽度。
  ///
  /// 用**向上取整**：宽 5 的 4:2:0 图，色度宽是 3 而不是 2 —— 最后一列亮度
  /// 也得有色度可用。这是奇数尺寸最容易漏掉的地方。
  int chromaWidth(int width) => (width + subX - 1) ~/ subX;

  /// 色度平面的高度，同样向上取整。
  int chromaHeight(int height) => (height + subY - 1) ~/ subY;

  /// 平面个数。
  int get planeCount => switch (layout) {
        YuvLayout.planar => 3,
        YuvLayout.semiPlanar => 2,
        YuvLayout.packed => 1,
      };

  /// 一帧占多少字节。
  ///
  /// 这里假设**没有行填充**（stride == width），这是裸 YUV 文件的惯例。
  /// 带 stride 的数据来自显存布局，不会以文件形式流通。
  int frameSize(int width, int height) {
    final int luma = width * height;
    switch (layout) {
      case YuvLayout.planar:
        return luma + chromaWidth(width) * chromaHeight(height) * 2;
      case YuvLayout.semiPlanar:
        // 交织平面里 U 和 V 各占一半，总量与三平面相同。
        return luma + chromaWidth(width) * chromaHeight(height) * 2;
      case YuvLayout.packed:
        // 4:2:2 打包：每像素两字节。
        return width * height * 2;
    }
  }

  /// 校验这个格式能不能表示给定尺寸。
  ///
  /// 只有打包格式有硬性要求：宏像素含两个像素，宽度必须是偶数，否则最后
  /// 一个宏像素只有半个像素，无法表达。平面格式靠色度平面向上取整消化奇数。
  void validateFor(int width, int height) {
    if (layout == YuvLayout.packed && width.isOdd) {
      throw ImageDecodeException(
        '$label 是打包格式，每个宏像素含两个像素，宽度必须是偶数（实际 $width）',
        format: 'YUV',
      );
    }
  }

  @override
  String toString() => '$label ($samplingLabel, ${layout.description})';
}
