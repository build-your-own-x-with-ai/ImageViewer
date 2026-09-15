/// 逆离散余弦变换（IDCT），两套实现。
///
/// ## 为什么留两套
///
/// 这是本项目里唯一刻意保留「慢版本」的地方，理由是教学：
///
/// * [IdctNaive] 直接照抄规范 A.3.3 的二维求和式。每个输出像素要 64 次
///   乘加，一个块 4096 次，慢得没法用于真实图片 —— 但它和纸上的公式
///   一行一行对得上，是**判断快版本对不对的基准**。
/// * [IdctFast] 行列分离的整数蝶形。一个块约 200 次乘法，快二十倍。
///
/// 有了基准，「快版本写错了」就从一件难查的事变成一条断言：两者输出差
/// 不超过 1。这个对照在 `test/codecs/jpeg_test.dart` 里是随机系数跑
/// 上百个块比的，比人肉盯蝶形连线可靠得多。
///
/// ## 命名与 design.md 的偏差
///
/// `design.md` 第 4.5 节把快版本叫 `IdctAan`。实际实现的是
/// **Loeffler-Ligtenberg-Moschytz**（LLM）算法，所以类名改成了 [IdctFast]。
///
/// 差别不是名字上的讲究。真正的 AAN 算法（libjpeg 的 `jidctflt.c`）输出
/// 带着一组余弦缩放因子，必须**把缩放因子预先乘进量化表**才能抵消掉。
/// 那会让 IDCT 和反量化耦合起来：换一个 IDCT 就得换一张量化表，
/// `dequantizeBlock` 也不能再是「系数 × 除数」这么一句话。
///
/// LLM 算法不需要预缩放，吃的就是普通反量化结果 —— 这也是 libjpeg 的
/// `jidctint.c` 和 stb_image 都选它的原因。用一个不准确的类名换一层耦合
/// 不值得，所以按实现的算法命名。
///
/// ## 32 位安全：两处 clamp 是为 Web 准备的
///
/// 定点运算的中间值会到 10⁹ 量级。Dart 在 Web 上位运算是 32 位**有符号**
/// 的（见 `implementation.md` 第 3.11 节），越过 2³¹ 就静默回绕，而桌面上
/// 是 64 位不会。同一个文件两个平台解出不同的图，是最难查的一类 bug。
///
/// 所以 [IdctFast] 在进入每一趟蝶形之前，把 8 个输入夹到 ±32767。
///
/// 上界这么定出来的：把每个输入在某个输出里的系数取绝对值加起来，得
/// 30606 —— 八个输出这个和都一样，因为那七个余弦的绝对值在不同输出位置
/// 上只是换了顺序。于是移位前的最大值是 30606 × 32767 ≈ 1.00×10⁹，
/// 加上折进去的偏置 1.68×10⁷，约 1.02×10⁹，距 2³¹ 还有一倍余量。
///
/// 下界要够宽，否则会削掉合法数据。列变换的输出带 4 倍放大
/// （`PASS1_BITS`，为的是把行变换的舍入误差缩到 1/4），而真实图片的
/// 中间值上限恰好是 4 × 1024 = 4096 —— 1024 是 8 位样本能产生的最大 DC，
/// 正变换的能量上界卡在那里，样本怎么排都出不去。±32767 留了八倍富余。
///
/// 碰得到 clamp 的只有畸形文件：`量化值 × 系数` 能到 10⁶ 量级。那时快
/// 版本会被截住，输出和浮点基准差出上百级 —— **这是设计的一部分**。
/// 全 64 项都取规范上限 ±2047 的块也算这一类：它不是任何 8 位图像能生成
/// 的（会要求中间值到 ±61182），只能来自损坏或恶意的数据。对这类输入我们
/// 只承诺三件事：不崩、落在 0..255、**两个平台产出同一份垃圾**。
library;

import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';

/// 把重建值夹到 0..255。
///
/// IDCT 的输出**必然**会越界：量化把系数改了，反变换出来的值不再保证落回
/// 原始范围，边缘附近尤其容易冲出去（振铃）。这不是文件坏了，是有损压缩的
/// 正常结果，所以这里直接饱和处理，不报错。
int clampSample(int value) => value < 0 ? 0 : (value > 255 ? 255 : value);

/// 蝶形每一趟的输入上界，见库文档「32 位安全」一节。
const int _passInputLimit = 32767;

int _clampPassInput(int value) => value < -_passInputLimit
    ? -_passInputLimit
    : (value > _passInputLimit ? _passInputLimit : value);

/// 8×8 IDCT 的公共接口。
///
/// 输入是**自然序**（行优先）的反量化系数，输出是已做电平位移（+128）
/// 并夹到 0..255 的样本。
///
/// 输出直接写进分量的样本平面：起点 [outOffset]，行间隔 [stride]。不经过
/// 中间的 8×8 缓冲 —— 块在平面上本来就不连续（一行有很多块），既然要按
/// 行散着写，就没必要先攒起来再搬一次。
abstract class Idct {
  const Idct();

  /// 算法名，给信息面板和测试报告用。
  String get name;

  /// 一句话说明，给教学模式的算法切换用。
  String get description;

  /// 变换一个块。[block] 只读，不会被修改。
  void transform(Int32List block, Uint8List out, int outOffset, int stride);
}

/// 按定义式直接双重求和的 IDCT。
///
/// ```
/// s(x,y) = 1/4 · Σu Σv C(u)·C(v)·S(u,v)·cos((2x+1)uπ/16)·cos((2y+1)vπ/16)
///          C(0) = 1/√2，其余 C(k) = 1
/// ```
///
/// 每个输出点要扫完 64 个系数，一块 64 个点，就是 4096 次乘法 —— 快速版
/// 大约 200 次。慢了 20 倍，但代码和公式逐项对得上，没有蝶形、没有定点、
/// 没有需要盯着连线图核对的地方。这就是它存在的理由：当快速版出错时，
/// 你需要一个不可能出错的东西来比。
class IdctNaive extends Idct {
  const IdctNaive();

  @override
  String get name => 'Naive';

  @override
  String get description => '直接按二维定义式求和，每块 4096 次乘法。'
      '慢，但和公式一一对应，用作快速版的正确性基准。';

  /// `basis[u·8 + x] = C(u)·cos((2x+1)uπ/16)`。
  ///
  /// 二维基函数是两个一维的乘积，所以一张 8×8 表够了，不需要 8⁴。
  /// 进程内只算一次；放顶层 static 而不是实例字段，是为了保住 const 构造。
  static final Float64List _basis = _buildBasis();

  static Float64List _buildBasis() {
    final Float64List table = Float64List(kBlockSize);
    for (int u = 0; u < kBlockDim; u++) {
      final double scale = u == 0 ? 1 / math.sqrt2 : 1.0;
      for (int x = 0; x < kBlockDim; x++) {
        table[u * kBlockDim + x] =
            scale * math.cos((2 * x + 1) * u * math.pi / 16);
      }
    }
    return table;
  }

  @override
  void transform(Int32List block, Uint8List out, int outOffset, int stride) {
    final Float64List basis = _basis;
    for (int y = 0; y < kBlockDim; y++) {
      final int rowStart = outOffset + y * stride;
      for (int x = 0; x < kBlockDim; x++) {
        double sum = 0;
        for (int v = 0; v < kBlockDim; v++) {
          final double basisY = basis[v * kBlockDim + y];
          final int coefficientRow = v * kBlockDim;
          for (int u = 0; u < kBlockDim; u++) {
            sum += block[coefficientRow + u] * basis[u * kBlockDim + x] * basisY;
          }
        }
        out[rowStart + x] = clampSample((sum / 4).round() + 128);
      }
    }
  }
}

/// 行列分离的整数蝶形 IDCT（LLM 算法）。
///
/// 三层优化叠起来，把 4096 次乘法压到约 200：
///
/// 1. **行列分离。** 二维 IDCT 等于先做 8 次列变换、再做 8 次行变换。
///    16 次一维变换代替一次二维求和，乘法从 8⁴ 掉到 16 × 8²。
/// 2. **蝶形分解。** 一维 8 点 IDCT 里，偶数项和奇数项各自成组，组内又能
///    共用中间和。一维从 64 次乘法降到 11 次。
/// 3. **定点化。** 余弦常数预先乘 4096 取整，全程整数运算，末尾一次性移位
///    还原。整数乘法比浮点快，且**两个平台逐位一致** —— 浮点的舍入在
///    JS 和 VM 上未必相同，而我们要求跨平台同一份输出。
///
/// 代价是可读性：蝶形里的每个中间量都没有直观含义。这正是 [IdctNaive]
/// 存在的意义 —— 正确性靠对照，不靠盯代码。
class IdctFast extends Idct {
  IdctFast();

  @override
  String get name => 'LLM (fast)';

  @override
  String get description => '行列分离 + 整数蝶形，每块约 200 次乘法。'
      '实际解码走这条路径。';

  /// 列变换的中间结果，自然序 8×8。
  ///
  /// 实例字段而非局部变量：一张图有几万个块，每块新分配一个 [Int32List]
  /// 会把 GC 压力变成可测的耗时。解码是单线程的，复用安全。
  final Int32List _work = Int32List(kBlockSize);

  /// 余弦常数 × 4096 取整。12 位定点是精度和 32 位余量之间的常规折中：
  /// 再多几位换不来可见画质，却会把中间值推向溢出。
  ///
  /// 名字里的数字就是原始常数：`_f0541` = round(0.541196100 × 4096)。
  static const int _f0541 = 2217; // 0.541196100
  static const int _f1848 = 7568; // 1.847759065
  static const int _f0765 = 3135; // 0.765366865
  static const int _f1176 = 4816; // 1.175875602
  static const int _f0299 = 1223; // 0.298631336
  static const int _f2053 = 8410; // 2.053119869
  static const int _f3073 = 12586; // 3.072711026
  static const int _f1501 = 6149; // 1.501321110
  static const int _f0900 = 3686; // 0.899976223
  static const int _f2563 = 10498; // 2.562915447
  static const int _f1962 = 8035; // 1.961570560
  static const int _f0390 = 1598; // 0.390180644

  /// 常数自带的定点位数。
  static const int _fixedBits = 12;

  /// 列变换刻意少还原 2 位，让中间结果带 4 倍放大 —— libjpeg 管这叫
  /// `PASS1_BITS`，作用是把行变换的舍入误差缩小到 1/4。
  static const int _pass1Bits = 2;

  static const int _pass1Shift = _fixedBits - _pass1Bits; // 10
  static const int _pass1Rounding = 1 << (_pass1Shift - 1);

  /// 行变换要还原：常数的 12 位 + 列变换留下的 2 位 + 行列各 √8 合起来的
  /// 3 位 = 17 位。
  static const int _pass2Shift = _fixedBits + _pass1Bits + 3; // 17
  static const int _pass2Rounding =
      (1 << (_pass2Shift - 1)) + 128 * (1 << _pass2Shift);

  @override
  void transform(Int32List block, Uint8List out, int outOffset, int stride) {
    final Int32List work = _work;

    for (int c = 0; c < kBlockDim; c++) {
      _pass1d(
          block, c, kBlockDim, _pass1Rounding, _pass1Shift, work, c, kBlockDim);
    }

    // 行变换原地做。偏置里顺手把 +128 电平位移折进去，省一次加法 ——
    // 这也是 [_pass2Rounding] 看起来比 [_pass1Rounding] 怪的原因。
    for (int r = 0; r < kBlockDim; r++) {
      final int rowStart = r * kBlockDim;
      _pass1d(work, rowStart, 1, _pass2Rounding, _pass2Shift, work, rowStart, 1);
    }

    for (int y = 0; y < kBlockDim; y++) {
      final int rowStart = y * kBlockDim;
      final int outRow = outOffset + y * stride;
      for (int x = 0; x < kBlockDim; x++) {
        out[outRow + x] = clampSample(work[rowStart + x]);
      }
    }
  }

  /// 一维 8 点 IDCT。
  ///
  /// 从 [src] 的 [srcOffset] 起按 [srcStride] 取 8 个值，结果按 [dstStride]
  /// 写到 [dst] 的 [dstOffset] 起。列变换和行变换只差这几个参数和移位量，
  /// 所以共用一份蝶形 —— 蝶形是全文件最容易写错的地方，不该存在两份。
  ///
  /// [src] 和 [dst] 可以是同一个数组：8 个输入在动手之前已全读进局部变量。
  static void _pass1d(Int32List src, int srcOffset, int srcStride, int rounding,
      int shift, Int32List dst, int dstOffset, int dstStride) {
    final int c0 = _clampPassInput(src[srcOffset]);
    final int c1 = _clampPassInput(src[srcOffset + srcStride]);
    final int c2 = _clampPassInput(src[srcOffset + 2 * srcStride]);
    final int c3 = _clampPassInput(src[srcOffset + 3 * srcStride]);
    final int c4 = _clampPassInput(src[srcOffset + 4 * srcStride]);
    final int c5 = _clampPassInput(src[srcOffset + 5 * srcStride]);
    final int c6 = _clampPassInput(src[srcOffset + 6 * srcStride]);
    final int c7 = _clampPassInput(src[srcOffset + 7 * srcStride]);

    // AC 全零 —— 这一路是平坦的，8 个输出都等于 DC 项。量化把高频清零是
    // 常态，这条捷径在真实图片上命中率很高（大片天空、色度分量）。
    if ((c1 | c2 | c3 | c4 | c5 | c6 | c7) == 0) {
      final int dc = (c0 * 4096 + rounding) >> shift;
      for (int i = 0; i < kBlockDim; i++) {
        dst[dstOffset + i * dstStride] = dc;
      }
      return;
    }

    // 偶数项 c0/c2/c4/c6：一次 √2 旋转加两组加减。
    final int rot26 = (c2 + c6) * _f0541;
    final int e2 = rot26 - c6 * _f1848;
    final int e3 = rot26 + c2 * _f0765;
    final int e0 = (c0 + c4) * 4096;
    final int e1 = (c0 - c4) * 4096;

    final int ev0 = e0 + e3;
    final int ev3 = e0 - e3;
    final int ev1 = e1 + e2;
    final int ev2 = e1 - e2;

    // 奇数项 c1/c3/c5/c7。照定义式要 16 次乘法，这里用四个交叉和加一个
    // 共享项压到 9 次 —— 蝶形省乘法的关键就在这一段。
    final int sum73 = c7 + c3;
    final int sum51 = c5 + c1;
    final int sum71 = c7 + c1;
    final int sum53 = c5 + c3;
    final int shared = (sum73 + sum51) * _f1176;

    final int a1 = shared - sum71 * _f0900;
    final int a2 = shared - sum53 * _f2563;
    final int a3 = -sum73 * _f1962;
    final int a4 = -sum51 * _f0390;

    final int od0 = c7 * _f0299 + a1 + a3;
    final int od1 = c5 * _f2053 + a2 + a4;
    final int od2 = c3 * _f3073 + a2 + a3;
    final int od3 = c1 * _f1501 + a1 + a4;

    // 偶奇相加得前半、相减得后半 —— 一维 IDCT 的对称性就体现在这八行。
    dst[dstOffset] = (ev0 + od3 + rounding) >> shift;
    dst[dstOffset + 7 * dstStride] = (ev0 - od3 + rounding) >> shift;
    dst[dstOffset + dstStride] = (ev1 + od2 + rounding) >> shift;
    dst[dstOffset + 6 * dstStride] = (ev1 - od2 + rounding) >> shift;
    dst[dstOffset + 2 * dstStride] = (ev2 + od1 + rounding) >> shift;
    dst[dstOffset + 5 * dstStride] = (ev2 - od1 + rounding) >> shift;
    dst[dstOffset + 3 * dstStride] = (ev3 + od0 + rounding) >> shift;
    dst[dstOffset + 4 * dstStride] = (ev3 - od0 + rounding) >> shift;
  }
}

