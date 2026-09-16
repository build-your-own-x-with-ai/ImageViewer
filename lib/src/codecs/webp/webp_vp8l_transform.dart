/// VP8L 的四种变换：熵编码之前的可逆预处理。
///
/// ## 它们和 PNG 的 filter 是同一个思路
///
/// PNG 在压缩前对每行做减法（Sub/Up/Average/Paeth），让数据变得好压。VP8L
/// 做同一件事，只是更进一步：
///
/// | | PNG filter | VP8L 变换 |
/// |---|---|---|
/// | 粒度 | 每行选一种 | 每个 tile 选一种（tile 边长 4..512） |
/// | 预测器 | 5 种 | 14 种 |
/// | 跨通道 | 无 | 有（减绿、颜色变换） |
/// | 调色板 | 单独的色彩类型 | 也是一种变换 |
///
/// 「每个 tile 选一种」是关键区别。PNG 一行只能用一种 filter，一行里既有
/// 平坦区又有边缘时只能折中；VP8L 可以让平坦区用 predictor 0、边缘用
/// predictor 11，各取所需。
///
/// ## 四种变换的顺序
///
/// 码流按编码时的施加顺序记录变换，解码要**倒着**逆推。每种最多出现一次
/// （规范强制），所以最多四个。
///
/// 调色板变换还会**改变图像宽度**：8 个 2 色像素挤进一个字节后，实际存储的
/// 图像比声明的窄。所以它一旦出现，后续变换和主图像解码用的都是缩窄后的宽度。
/// 这是本文件里唯一会反过来影响调用方的变换。
///
/// ## 一个必须照抄的怪癖：右上邻居会绕到下一行
///
/// 预测器 3/5/9/10 要用「右上」邻居。一行最后一个像素的右上，在扁平的像素
/// 缓冲里正好是**当前行的第一个像素**（`i - width + 1 == y * width`）。
///
/// libwebp 没有为此特殊处理，编码器也是同样的绕法，所以这个「越界」是格式
/// 的一部分，不是 bug。照抄，并且不要「修正」它 —— 修正的结果是最后一列
/// 像素全错，而且只在用到那几个预测器的图上出现。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/webp/webp_types.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 变换种类，2 位编码。顺序即码流里的数值。
enum Vp8lTransformType {
  predictor,
  crossColor,
  subtractGreen,
  colorIndexing;

  String get label => switch (this) {
        Vp8lTransformType.predictor => '预测器',
        Vp8lTransformType.crossColor => '颜色变换',
        Vp8lTransformType.subtractGreen => '减绿',
        Vp8lTransformType.colorIndexing => '调色板',
      };
}

/// tile 边长的位数范围：读 3 位再加 2，所以是 2..9（边长 4..512）。
const int kMinTransformBits = 2;
const int kTransformBitsCount = 3;

/// 变换最多四种，每种至多一次。
const int kMaxTransforms = 4;

/// 子采样后的尺寸：向上取整的 `size / 2^bits`。
///
/// tile 化的变换（预测器、颜色变换）用它算「一共多少个 tile」，调色板变换
/// 用它算「打包后的图像有多宽」。同一个公式服务两件事。
int subSampleSize(int size, int bits) => (size + (1 << bits) - 1) >> bits;

/// 一个已读出的变换。`data` 是它的辅助图像：
///
/// * 预测器 / 颜色变换 —— 一张 tile 分辨率的图，每个像素编码该 tile 的参数；
/// * 调色板 —— 一行 `num_colors` 个像素的色表，已展开到 2 的幂并做过差分还原；
/// * 减绿 —— 不需要参数，`data` 为 null。
class Vp8lTransform {
  Vp8lTransform({
    required this.type,
    required this.bits,
    required this.width,
    required this.height,
    this.data,
  });

  final Vp8lTransformType type;

  /// tile 边长的位数（预测器/颜色变换），或每字节像素数的位数（调色板）。
  /// 减绿用不到，填 0。
  final int bits;

  /// 变换施加时的图像尺寸 —— 注意不一定等于最终画布尺寸：调色板变换之后
  /// 宽度会缩窄，所以「在它之前读到的变换」记录的是缩窄前的宽。
  final int width;
  final int height;

  Uint32List? data;
}

/// 逐通道模 256 相加 —— 这就是「加回预测值」。
///
/// 用的是加法而不是 clamp。溢出直接绕回，编码器减的时候也绕回，一来一回正好
/// 抵消。clamp 反而会丢信息（255 + 3 clamp 成 255，减不回去）。
int addPixels(int a, int b) => packArgb(
      (argbA(a) + argbA(b)) % 256,
      (argbR(a) + argbR(b)) % 256,
      (argbG(a) + argbG(b)) % 256,
      (argbB(a) + argbB(b)) % 256,
    );

/// 逐通道向下取整的平均。
///
/// `(a + b) >> 1` 而不是四舍五入 —— 编码器也是这个式子，差一就全错。
int _average2(int a, int b) => packArgb(
      (argbA(a) + argbA(b)) >> 1,
      (argbR(a) + argbR(b)) >> 1,
      (argbG(a) + argbG(b)) >> 1,
      (argbB(a) + argbB(b)) >> 1,
    );

int _clip255(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// 把一个字节按有符号 int8 解释。颜色变换的乘数和 predictor 用的绿色都是
/// 有符号的，忘了这一步的症状是颜色偏移只在某些 tile 出现。
int _asInt8(int b) => b < 128 ? b : b - 256;

/// 预测器 11：从上、左两个候选里挑一个，判据是「谁离左上更远」。
///
/// 这是 PNG 的 Paeth 的近亲，但不完全一样：Paeth 会在三个候选（左、上、左上）
/// 里挑最接近 `L + T - TL` 的那个；VP8L 只在左和上之间二选一，判据是四个通道
/// 的绝对差之和。选择性预测比算术预测更抗边缘 —— 边缘两侧的值差得远，取平均
/// 或加减都会造出一个两边都不像的值，而挑一边至少像一边。
int _select(int top, int left, int topLeft) {
  int sum = 0;
  sum += (argbA(left) - argbA(topLeft)).abs() -
      (argbA(top) - argbA(topLeft)).abs();
  sum += (argbR(left) - argbR(topLeft)).abs() -
      (argbR(top) - argbR(topLeft)).abs();
  sum += (argbG(left) - argbG(topLeft)).abs() -
      (argbG(top) - argbG(topLeft)).abs();
  sum += (argbB(left) - argbB(topLeft)).abs() -
      (argbB(top) - argbB(topLeft)).abs();
  return sum <= 0 ? top : left;
}

/// 预测器 12：逐通道 `clip(L + T - TL)`，就是 Paeth 的那个算术式本身。
int _clampedAddSubtractFull(int left, int top, int topLeft) => packArgb(
      _clip255(argbA(left) + argbA(top) - argbA(topLeft)),
      _clip255(argbR(left) + argbR(top) - argbR(topLeft)),
      _clip255(argbG(left) + argbG(top) - argbG(topLeft)),
      _clip255(argbB(left) + argbB(top) - argbB(topLeft)),
    );

/// 不透明的黑，预测器 0 的固定值，也是整张图左上角那一个像素的预测值。
const int kArgbBlack = 0xFF000000;

/// 预测器 13：先取 L、T 的平均，再朝「远离左上」的方向外推半步。
///
/// `(ave - topLeft) ~/ 2` 里的除法必须**向零截断**（C 的 `/` 对负数就是这样），
/// 不能用 `>>` 的向下取整。差一位的后果是渐变区域出现规律性的一格偏差。
int _clampedAddSubtractHalf(int left, int top, int topLeft) {
  final int ave = _average2(left, top);
  int half(int a, int b) => _clip255(a + (a - b) ~/ 2);
  return packArgb(
    half(argbA(ave), argbA(topLeft)),
    half(argbR(ave), argbR(topLeft)),
    half(argbG(ave), argbG(topLeft)),
    half(argbB(ave), argbB(topLeft)),
  );
}

/// 14 种预测器的分派。
///
/// 名字里的 L/T/TL/TR 分别是左、上、左上、右上。分成三类看就不用死记：
///
/// * **直接取邻居**：0 黑、1 左、2 上、3 右上、4 左上；
/// * **取平均**：5..10，把两三个邻居混起来，适合渐变；
/// * **算术/选择**：11 选择、12 加减、13 半步加减，适合边缘。
///
/// 模式号来自 tile 参数像素的**绿色通道**。规范只定义 0..13，但绿色通道能给出
/// 0..255；这里跟 libwebp 一样先 `& 0xF`，再把 14、15 当作 0 处理 —— 用一个
/// 无害的默认值吸收畸形输入，而不是抛异常中断整张图。
int predict(int mode, int left, int top, int topLeft, int topRight) {
  switch (mode & 0xF) {
    case 1:
      return left;
    case 2:
      return top;
    case 3:
      return topRight;
    case 4:
      return topLeft;
    case 5:
      return _average2(_average2(left, topRight), top);
    case 6:
      return _average2(left, topLeft);
    case 7:
      return _average2(left, top);
    case 8:
      return _average2(topLeft, top);
    case 9:
      return _average2(top, topRight);
    case 10:
      return _average2(_average2(left, topLeft), _average2(top, topRight));
    case 11:
      return _select(top, left, topLeft);
    case 12:
      return _clampedAddSubtractFull(left, top, topLeft);
    case 13:
      return _clampedAddSubtractHalf(left, top, topLeft);
    default:
      return kArgbBlack;
  }
}

/// 逆预测：把残差加回预测值，**原地**改写 `pixels`。
///
/// 原地可行是因为预测只读左、上、左上、右上 —— 按行从上到下、行内从左到右走，
/// 这四个位置都已经复原好了。省下一整块和图像等大的缓冲。
///
/// 三个边界各有各的规则，而且是**规范强制**的，不是实现自由：
///
/// * (0, 0) 没有任何邻居 → 预测值恒为不透明黑；
/// * 第 0 行其余像素只有左邻居 → 恒用预测器 1；
/// * 第 0 列（y > 0）只有上邻居 → 恒用预测器 2。
///
/// tile 参数图只对「内部」像素生效。把边界也交给 tile 模式的话，第一行第一列
/// 会读到未初始化的邻居，整张图从左上角开始烂。
void applyPredictorInverse(Vp8lTransform t, Uint32List pixels) {
  final int width = t.width;
  final int height = t.height;
  final Uint32List modes = t.data!;
  final int tilesPerRow = subSampleSize(width, t.bits);

  // 第 0 行：左上角用黑，其余顺着左邻居推。
  pixels[0] = addPixels(pixels[0], kArgbBlack);
  for (int x = 1; x < width; x++) {
    pixels[x] = addPixels(pixels[x], pixels[x - 1]);
  }

  for (int y = 1; y < height; y++) {
    final int rowStart = y * width;
    final int modeRow = (y >> t.bits) * tilesPerRow;

    // 第 0 列：只能看上面。
    pixels[rowStart] = addPixels(pixels[rowStart], pixels[rowStart - width]);

    for (int x = 1; x < width; x++) {
      final int i = rowStart + x;
      // 模式藏在参数像素的绿色通道里。
      final int mode = argbG(modes[modeRow + (x >> t.bits)]);
      final int pred = predict(
        mode,
        pixels[i - 1],
        pixels[i - width],
        pixels[i - width - 1],
        // 行末的「右上」会绕到本行第一个像素 —— 见库文档，照抄。
        pixels[i - width + 1],
      );
      pixels[i] = addPixels(pixels[i], pred);
    }
  }
}

/// 颜色变换的 delta：两个有符号字节相乘再算术右移 5 位。
///
/// 右移 5 相当于除以 32，也就是把乘数当成 5 位定点小数看 —— 乘数 32 表示
/// 系数 1.0，乘数 -16 表示 -0.5。移位必须是**算术**的（负数向下取整），
/// Dart 的 `>>` 对 int 正是如此，不能换成 `~/ 32`。
int _colorDelta(int multiplier, int color) =>
    (_asInt8(multiplier) * _asInt8(color)) >> 5;

/// 逆颜色变换（cross-color）：把绿色对红蓝、红色对蓝色的相关性加回去。
///
/// 自然图像里三个通道高度相关 —— 亮的地方三个通道一起亮。减绿（下面那个变换）
/// 处理的是「整体一起变」，这个变换处理的是**残余的**线性相关：绿色偏高的地方
/// 红色也系统性偏高多少。三个乘数分别由 tile 参数像素的蓝、绿、红通道给出：
///
/// | 乘数 | 存在哪个通道 |
/// |---|---|
/// | green → red | 蓝 |
/// | green → blue | 绿 |
/// | red → blue | 红 |
///
/// 顺序有讲究：先算完红色并**截断到一个字节**，再拿这个字节（按有符号解释）去
/// 修正蓝色。用未截断的中间值会在极端色上偏一点点，肉眼看不出来，逐像素对比
/// 会红。
void applyCrossColorInverse(Vp8lTransform t, Uint32List pixels) {
  final int width = t.width;
  final int height = t.height;
  final Uint32List codes = t.data!;
  final int tilesPerRow = subSampleSize(width, t.bits);

  for (int y = 0; y < height; y++) {
    final int rowStart = y * width;
    final int codeRow = (y >> t.bits) * tilesPerRow;
    for (int x = 0; x < width; x++) {
      final int code = codes[codeRow + (x >> t.bits)];
      final int greenToRed = argbB(code);
      final int greenToBlue = argbG(code);
      final int redToBlue = argbR(code);

      final int i = rowStart + x;
      final int argb = pixels[i];
      final int green = argbG(argb);
      final int red = (argbR(argb) + _colorDelta(greenToRed, green)) % 256;
      final int blue = (argbB(argb) +
              _colorDelta(greenToBlue, green) +
              _colorDelta(redToBlue, red)) %
          256;
      pixels[i] = packArgb(argbA(argb), red, argbG(argb), blue);
    }
  }
}

/// 逆减绿：`red += green`、`blue += green`，逐通道模 256。
///
/// 四种变换里最简单的一个 —— 没有参数图，没有 tile，甚至没有边界情况。
/// 编码时存的是 `red - green` 和 `blue - green`，灰色区域于是变成一片零，
/// 熵编码器最爱这个。
///
/// 为什么减的是绿色而不是红或蓝：绿色在亮度里占比最大（人眼对绿最敏感，
/// 拜耳阵列里绿色像素也是两倍），拿它当基准，残差最小。同一个理由让
/// YCbCr 把 Y 的绿色系数定成 0.587。
void applyAddGreen(Uint32List pixels) {
  for (int i = 0; i < pixels.length; i++) {
    final int argb = pixels[i];
    final int green = argbG(argb);
    pixels[i] = packArgb(
      argbA(argb),
      (argbR(argb) + green) % 256,
      green,
      (argbB(argb) + green) % 256,
    );
  }
}

/// 展开色表：差分还原，再补黑到 2 的幂。
///
/// 色表本身也被压过 —— 存的是相邻颜色的**逐通道差**。渐变色板（很常见，比如
/// 一条从深蓝到浅蓝的 16 色带）差分之后全是小数字，好压。
///
/// 补到 2 的幂是给索引查表兜底：`bits` 决定了索引有几位，2 位索引能表示 4 个
/// 值，但色表可能只有 3 个颜色。补一个黑色进去，畸形码流里的越界索引就落在
/// 合法内存上，不用在每个像素上做一次边界检查。
Uint32List expandColorMap(Uint32List raw, int numColors, int bits) {
  final int finalColors = 1 << (8 >> bits);
  final Uint32List map = Uint32List(finalColors);
  map[0] = raw[0];
  for (int i = 1; i < numColors; i++) {
    final int d = raw[i];
    final int p = map[i - 1];
    map[i] = packArgb(
      (argbA(d) + argbA(p)) % 256,
      (argbR(d) + argbR(p)) % 256,
      (argbG(d) + argbG(p)) % 256,
      (argbB(d) + argbB(p)) % 256,
    );
  }
  // 尾部保持 0（全透明黑）—— Uint32List 自带零初始化。
  return map;
}

/// 逆调色板：把索引换回颜色，顺便把挤在一起的像素拆开。
///
/// 这是唯一**不能原地做**的变换 —— 输出比输入宽。颜色少于 256 种时，VP8L 会
/// 把多个索引塞进一个像素的绿色通道里：
///
/// | 颜色数 | bits | 每像素位数 | 每个存储像素装几个 |
/// |---|---|---|---|
/// | ≤ 2 | 3 | 1 | 8 |
/// | ≤ 4 | 2 | 2 | 4 |
/// | ≤ 16 | 1 | 4 | 2 |
/// | ≤ 256 | 0 | 8 | 1 |
///
/// 打包是**低位在前**：一个字节里的第一个像素在最低几位。这和 VP8L 整体的
/// LSB-first 位序是一致的。
///
/// 每行独立打包，行尾不足一组的部分补齐 —— 所以每行开头都要重新取一个存储
/// 像素，不能把整张图当成一条连续的位流。跨行连续读的话，宽度不是每字节像素
/// 数整数倍的图会从第二行开始整体错位。
Uint32List applyColorIndexInverse(Vp8lTransform t, Uint32List packed) {
  final int width = t.width;
  final int height = t.height;
  final Uint32List map = t.data!;
  final Uint32List out = Uint32List(width * height);

  if (t.bits == 0) {
    // 一个索引占满一个存储像素，只是查表。
    for (int i = 0; i < out.length; i++) {
      out[i] = map[argbG(packed[i])];
    }
    return out;
  }

  final int bitsPerPixel = 8 >> t.bits;
  final int pixelsPerByte = 1 << t.bits;
  final int mask = (1 << bitsPerPixel) - 1;
  final int packedWidth = subSampleSize(width, t.bits);

  for (int y = 0; y < height; y++) {
    final int inRow = y * packedWidth;
    final int outRow = y * width;
    int group = 0;
    for (int x = 0; x < width; x++) {
      if (x % pixelsPerByte == 0) {
        group = argbG(packed[inRow + x ~/ pixelsPerByte]);
      }
      out[outRow + x] = map[group & mask];
      group >>= bitsPerPixel;
    }
  }
  return out;
}

/// 按码流顺序的**逆序**施加所有变换，返回最终像素。
///
/// 逆序是因为编码器是正序施加的：先减绿、再预测、再打包，解码就得先拆包、
/// 再逆预测、再加回绿色。顺序错了不会崩，只会得到一张颜色乱掉的图 —— 所以
/// 这行 `for` 循环的方向值得单独一条测试盯着。
Uint32List applyInverseTransforms(
  List<Vp8lTransform> transforms,
  Uint32List pixels,
) {
  Uint32List current = pixels;
  for (int i = transforms.length - 1; i >= 0; i--) {
    final Vp8lTransform t = transforms[i];
    switch (t.type) {
      case Vp8lTransformType.predictor:
        applyPredictorInverse(t, current);
      case Vp8lTransformType.crossColor:
        applyCrossColorInverse(t, current);
      case Vp8lTransformType.subtractGreen:
        applyAddGreen(current);
      case Vp8lTransformType.colorIndexing:
        current = applyColorIndexInverse(t, current);
    }
  }
  return current;
}

/// 调色板变换的 `bits`：颜色越少，一个字节能装的索引越多。
int colorIndexBits(int numColors) => numColors > 16
    ? 0
    : numColors > 4
        ? 1
        : numColors > 2
            ? 2
            : 3;

/// 变换只允许各出现一次。重复出现要当成畸形拒掉 —— 不是洁癖，是因为第二次
/// 出现会覆盖第一次的参数图，给了畸形码流一个把解码器绕进无效状态的口子。
void checkTransformNotSeen(int seenMask, Vp8lTransformType type) {
  if (seenMask & (1 << type.index) != 0) {
    throw ImageDecodeException(
      '${type.label}变换出现了两次，规范规定每种至多一次',
      format: kWebpFormat,
    );
  }
}
