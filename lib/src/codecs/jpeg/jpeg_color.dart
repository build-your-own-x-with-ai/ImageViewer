/// JPEG 的色彩空间判定与转换。
///
/// 熵解码 + IDCT + 升采样之后，手里是几个全分辨率的分量平面，但**它们是什么
/// 颜色，文件里没写**。JPEG 比特流只描述"有几个分量、各自的 ID 是多少"，
/// 语义要靠外围标记和惯例去猜：
///
///   * 1 个分量 → 灰阶（唯一没有歧义的情形）
///   * 3 个分量 → 几乎总是 YCbCr，偶尔是 RGB
///   * 4 个分量 → CMYK 或 YCCK，且样本很可能是反存的
///
/// 猜的规则见 [chooseColorSpace]，抄自 libjpeg 的 `default_decompress_parms`。
/// 抄它而不是自己定，是因为这套启发式已经是事实标准：跟它一致，就意味着跟
/// 浏览器、Photoshop、djpeg 对同一个文件的判断一致。
///
/// 数值上走定点运算（见 [_scaleBits]），不用 double —— 一是快，二是结果能和
/// libjpeg 逐字节对上，交叉验证才有意义。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/core/errors.dart';

/// JPEG 的色彩空间。
///
/// 文件里没有任何一个字段直接写明这件事 —— 得从分量个数、APP0/APP14 标记和
/// 分量 ID 三处线索凑出来。[chooseColorSpace] 抄的是 libjpeg 的判定顺序。
enum JpegColorSpace {
  /// 单分量：Y 直接铺成灰阶。
  grayscale,

  /// 三分量 YCbCr。绝大多数 JPEG 是这个。
  ycbcr,

  /// 三分量但已经是 RGB —— 分量 ID 恰好是 `'R' 'G' 'B'`，或 Adobe
  /// transform=0。不常见，Photoshop 存「无色彩变换」时会出现。
  rgb,

  /// 四分量 CMYK。
  cmyk,

  /// 四分量 YCCK：CMY 先取反（变成类 RGB 的量），再做一次 YCbCr 变换，
  /// K 通道原样另存。
  ycck,
}

/// 分量 ID 为 `'R' 'G' 'B'` 时按 RGB 解释。
const int _idR = 0x52;
const int _idG = 0x47;
const int _idB = 0x42;

/// APP0 是不是 JFIF 头（`'J' 'F' 'I' 'F' 0x00`）。
///
/// [data] 是段载荷，不含那两个长度字节。
bool isJfifApp0(Uint8List data) =>
    data.length >= 5 &&
    data[0] == 0x4A &&
    data[1] == 0x46 &&
    data[2] == 0x49 &&
    data[3] == 0x46 &&
    data[4] == 0x00;

/// 从 APP14 里取 Adobe 的 transform 字节，不是 Adobe 段就返回 null。
///
/// 载荷布局：`'Adobe'`(5) + 版本(2) + flags0(2) + flags1(2) + transform(1)。
/// 只有最后那个字节有用，它决定四分量文件是 CMYK 还是 YCCK。
int? parseAdobeTransform(Uint8List data) {
  if (data.length < 12) {
    return null;
  }
  const List<int> tag = <int>[0x41, 0x64, 0x6F, 0x62, 0x65]; // 'Adobe'
  for (int i = 0; i < tag.length; i++) {
    if (data[i] != tag[i]) {
      return null;
    }
  }
  return data[11];
}

/// 判定色彩空间，抄 libjpeg `default_decompress_parms` 的顺序。
///
/// [componentIds] 是 SOF 里各分量的 ID（原始字节）。[hasJfif] 表示见过
/// JFIF 版 APP0，[adobeTransform] 是 [parseAdobeTransform] 的结果。
///
/// 三分量时的优先级值得留意：**JFIF 标记压过分量 ID**。有些编码器既写
/// JFIF 又把分量 ID 填成 `'R' 'G' 'B'`，这时候数据仍然是 YCbCr —— 认 ID
/// 会把颜色彻底解错。
JpegColorSpace chooseColorSpace({
  required List<int> componentIds,
  required bool hasJfif,
  required int? adobeTransform,
}) {
  switch (componentIds.length) {
    case 1:
      return JpegColorSpace.grayscale;
    case 3:
      if (hasJfif) {
        return JpegColorSpace.ycbcr;
      }
      if (adobeTransform != null) {
        // transform=0 说明没做色彩变换；1 是 YCbCr。其它值按 libjpeg
        // 的做法当 YCbCr 处理（它只是打一条警告）。
        return adobeTransform == 0 ? JpegColorSpace.rgb : JpegColorSpace.ycbcr;
      }
      if (componentIds[0] == _idR &&
          componentIds[1] == _idG &&
          componentIds[2] == _idB) {
        return JpegColorSpace.rgb;
      }
      return JpegColorSpace.ycbcr;
    case 4:
      if (adobeTransform != null) {
        // 0 = CMYK 直存，2 = YCCK。同样地，其它值当 YCCK。
        return adobeTransform == 0 ? JpegColorSpace.cmyk : JpegColorSpace.ycck;
      }
      return JpegColorSpace.cmyk;
    default:
      throw UnsupportedImageFeature(
        '不支持 ${componentIds.length} 个分量的 JPEG',
        format: 'JPEG',
      );
  }
}

/// 给信息面板用的色彩空间名字。
String colorSpaceLabel(JpegColorSpace space) {
  switch (space) {
    case JpegColorSpace.grayscale:
      return 'Grayscale';
    case JpegColorSpace.ycbcr:
      return 'YCbCr (BT.601)';
    case JpegColorSpace.rgb:
      return 'RGB';
    case JpegColorSpace.cmyk:
      return 'CMYK';
    case JpegColorSpace.ycck:
      return 'YCCK';
  }
}

/// 定点运算的小数位数。libjpeg 用 16 位，误差远小于 1/255。
const int _scaleBits = 16;

/// 移位前加上的半个最低位，等价于四舍五入而不是向下取整。
const int _half = 1 << (_scaleBits - 1);

// BT.601 的反变换系数乘 2^16 后取整（和 libjpeg 的 FIX() 逐位一致）：
//
//   R = Y                + 1.40200 * Cr
//   G = Y - 0.34414 * Cb - 0.71414 * Cr
//   B = Y + 1.77200 * Cb
const int _fixCrToR = 91881;
const int _fixCbToB = 116130;
const int _fixCbToG = -22554;
const int _fixCrToG = -46802;

/// 四张查表，把每个 Cb/Cr 字节预先乘好系数。
///
/// 顶层 `final` 是惰性初始化的，所以这 1024 次乘法在第一次解 JPEG 时才
/// 付出，之后每个像素只剩加法和一次移位。
///
/// 表里存的是负数，取值时要移位 —— Dart 的 `>>` 是算术移位（向下取整），
/// 和 libjpeg 的 `RIGHT_SHIFT` 语义相同。最大幅度约 890 万，32 位放得下，
/// 所以 Web 上 `>>` 编译成 JS 的有符号移位也不会变。
class _YccTables {
  _YccTables()
      : crToR = Int32List(256),
        cbToB = Int32List(256),
        cbToG = Int32List(256),
        crToG = Int32List(256) {
    for (int i = 0; i < 256; i++) {
      final int x = i - 128;
      crToR[i] = (_fixCrToR * x + _half) >> _scaleBits;
      cbToB[i] = (_fixCbToB * x + _half) >> _scaleBits;
      // 绿色那两项不预先移位：先相加再一次性移位，少一次舍入误差。
      // _half 只加在其中一张表里，免得加两遍。
      cbToG[i] = _fixCbToG * x;
      crToG[i] = _fixCrToG * x + _half;
    }
  }

  final Int32List crToR;
  final Int32List cbToB;
  final Int32List cbToG;
  final Int32List crToG;
}

final _YccTables _ycc = _YccTables();

/// 把定点运算的结果截到 `[0, 255]`。
///
/// libjpeg 为此维护了一张 `range_limit` 表，那是为了在老 CPU 上省掉分支；
/// 现在直接比较又快又好读。
int _clamp(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

/// 把已升采样到全分辨率的各分量平面拼成 RGBA。
///
/// [planes] 的每一项长度至少 [pixelCount]（= 宽 × 高），顺序同 SOF 里的分量
/// 顺序。返回长度 `pixelCount * 4` 的 R,G,B,A 字节流，A 恒为 255 —— JPEG
/// 没有透明通道。
///
/// [adobeInverted] 只对 [JpegColorSpace.cmyk] 有意义：见 [_cmykToRgba] 里
/// 关于 Adobe 反存的说明。[JpegColorSpace.ycck] 必然来自 Adobe，无需此标志。
Uint8List convertToRgba({
  required List<Uint8List> planes,
  required JpegColorSpace colorSpace,
  required int pixelCount,
  bool adobeInverted = false,
}) {
  final int expected = _channelCount(colorSpace);
  if (planes.length != expected) {
    throw ImageDecodeException(
      '$colorSpace 需要 $expected 个分量，实际 ${planes.length} 个',
      format: 'JPEG',
    );
  }
  for (int i = 0; i < planes.length; i++) {
    if (planes[i].length < pixelCount) {
      throw ImageDecodeException(
        '分量 $i 的平面只有 ${planes[i].length} 字节，不足 $pixelCount',
        format: 'JPEG',
      );
    }
  }

  final Uint8List out = Uint8List(pixelCount * 4);
  switch (colorSpace) {
    case JpegColorSpace.grayscale:
      _grayToRgba(planes[0], out, pixelCount);
    case JpegColorSpace.rgb:
      _rgbToRgba(planes, out, pixelCount);
    case JpegColorSpace.ycbcr:
      _ycbcrToRgba(planes, out, pixelCount);
    case JpegColorSpace.cmyk:
      _cmykToRgba(planes, out, pixelCount, inverted: adobeInverted);
    case JpegColorSpace.ycck:
      _ycckToRgba(planes, out, pixelCount);
  }
  return out;
}

int _channelCount(JpegColorSpace space) {
  switch (space) {
    case JpegColorSpace.grayscale:
      return 1;
    case JpegColorSpace.ycbcr:
    case JpegColorSpace.rgb:
      return 3;
    case JpegColorSpace.cmyk:
    case JpegColorSpace.ycck:
      return 4;
  }
}

void _grayToRgba(Uint8List yp, Uint8List out, int count) {
  int o = 0;
  for (int i = 0; i < count; i++) {
    final int v = yp[i];
    out[o] = v;
    out[o + 1] = v;
    out[o + 2] = v;
    out[o + 3] = 255;
    o += 4;
  }
}

void _rgbToRgba(List<Uint8List> planes, Uint8List out, int count) {
  final Uint8List rp = planes[0];
  final Uint8List gp = planes[1];
  final Uint8List bp = planes[2];
  int o = 0;
  for (int i = 0; i < count; i++) {
    out[o] = rp[i];
    out[o + 1] = gp[i];
    out[o + 2] = bp[i];
    out[o + 3] = 255;
    o += 4;
  }
}

void _ycbcrToRgba(List<Uint8List> planes, Uint8List out, int count) {
  final Uint8List yp = planes[0];
  final Uint8List cbp = planes[1];
  final Uint8List crp = planes[2];
  final Int32List crToR = _ycc.crToR;
  final Int32List cbToB = _ycc.cbToB;
  final Int32List cbToG = _ycc.cbToG;
  final Int32List crToG = _ycc.crToG;
  int o = 0;
  for (int i = 0; i < count; i++) {
    final int y = yp[i];
    final int cb = cbp[i];
    final int cr = crp[i];
    out[o] = _clamp(y + crToR[cr]);
    out[o + 1] = _clamp(y + ((cbToG[cb] + crToG[cr]) >> _scaleBits));
    out[o + 2] = _clamp(y + cbToB[cb]);
    out[o + 3] = 255;
    o += 4;
  }
}

/// CMYK → RGB。
///
/// 用乘性公式而不是加性的 `255 - min(255, c + k)`：
///
///     R = (255 - C) * (255 - K) / 255
///
/// 前者把 K 当成一层中性灰滤镜，青 50% + 黑 50% 得到的红色是 64 而不是 0，
/// 更接近实际印刷。整除会往下偏最多 1 级，肉眼看不出来。
///
/// ## Adobe 反存
///
/// 带 APP14 Adobe 标记的四分量 JPEG，样本值是**反的** —— 255 表示"这里没有
/// 油墨"。这不是 JFIF 或 ITU T.81 里的规定，纯粹是 Photoshop 当年的行为，
/// 后来所有解码器都只能跟着认：见到 Adobe 段就假定反存。
///
/// 于是本函数内部统一按 `a = 255 - 油墨量` 来算（[inverted] 时样本本身就是
/// `a`，否则先取反），公式收缩成一行乘法：
///
///     R = a_c * a_k / 255
///
/// 注意 `djpeg` 不做这层判断，它把解出来的四个通道原样交出去，所以拿它的
/// 输出跟本实现比 CMYK 会看起来是反色的。这也是交叉验证只覆盖灰阶和 YCbCr
/// 的原因之一 —— djpeg 的 PPM 输出本来也只支持 1 或 3 个分量。
void _cmykToRgba(
  List<Uint8List> planes,
  Uint8List out,
  int count, {
  required bool inverted,
}) {
  final Uint8List cp = planes[0];
  final Uint8List mp = planes[1];
  final Uint8List yp = planes[2];
  final Uint8List kp = planes[3];
  int o = 0;
  for (int i = 0; i < count; i++) {
    final int ac = inverted ? cp[i] : 255 - cp[i];
    final int am = inverted ? mp[i] : 255 - mp[i];
    final int ay = inverted ? yp[i] : 255 - yp[i];
    final int ak = inverted ? kp[i] : 255 - kp[i];
    out[o] = ac * ak ~/ 255;
    out[o + 1] = am * ak ~/ 255;
    out[o + 2] = ay * ak ~/ 255;
    out[o + 3] = 255;
    o += 4;
  }
}

/// YCCK → RGB。
///
/// YCCK 的三个色度通道是这么来的：编码器先把 CMY 取反（`255 - C`，得到一组
/// 行为上就是 RGB 的量），再做标准的 RGB→YCbCr；K 通道原样另存，不参与变换。
///
/// 所以解码是把这一步倒回去：先 YCbCr→R'G'B'，再取反就得到存储的 CMY 样本
/// 值 —— 这正是 libjpeg `ycck_cmyk_convert` 输出的东西。拿到四个存储样本后，
/// 走 [_cmykToRgba] 里同一条 Adobe 反存公式（YCCK 只可能来自 Adobe，所以
/// `inverted` 恒真）：
///
///     a_c = 255 - R'   a_k = K       R = a_c * a_k / 255
///
/// 验算三个端点：无油墨时 R'=0、K=255 → R=255（白）；100% 青时 R'=255 →
/// R=0、G=B=255（青）；K 满版时存储的 K=0 → RGB 全 0（黑）。
void _ycckToRgba(List<Uint8List> planes, Uint8List out, int count) {
  final Uint8List yp = planes[0];
  final Uint8List cbp = planes[1];
  final Uint8List crp = planes[2];
  final Uint8List kp = planes[3];
  final Int32List crToR = _ycc.crToR;
  final Int32List cbToB = _ycc.cbToB;
  final Int32List cbToG = _ycc.cbToG;
  final Int32List crToG = _ycc.crToG;
  int o = 0;
  for (int i = 0; i < count; i++) {
    final int y = yp[i];
    final int cb = cbp[i];
    final int cr = crp[i];
    // 先截到 [0,255] 再取反，否则越界的 R' 会让下面的乘法溢出到界外。
    final int ac = 255 - _clamp(y + crToR[cr]);
    final int am =
        255 - _clamp(y + ((cbToG[cb] + crToG[cr]) >> _scaleBits));
    final int ay = 255 - _clamp(y + cbToB[cb]);
    final int ak = kp[i];
    out[o] = ac * ak ~/ 255;
    out[o + 1] = am * ak ~/ 255;
    out[o + 2] = ay * ak ~/ 255;
    out[o + 3] = 255;
    o += 4;
  }
}
