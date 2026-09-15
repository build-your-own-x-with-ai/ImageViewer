import 'dart:typed_data';

import 'package:image_viewer/src/codecs/jpeg/jpeg_frame.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';

/// 把各分量的样本平面放大回整帧尺寸。
///
/// 编码时色度被抽掉了一部分样本（4:2:0 只留 1/4），解码要先补回来才能做颜色
/// 转换 —— 三个分量必须逐像素对齐。
///
/// 放大倍数是**相对**的：`maxH / h` 和 `maxV / v`。所以同一份 4:2:0 图，
/// 写成 `Y=2x2 / C=1x1` 和 `Y=4x4 / C=2x2` 的放大倍数都是 2。倍数还不保证是
/// 整数 —— `maxH=4, h=3` 合法（倍数 4/3），只是几乎没有编码器这么干。
/// libjpeg 干脆断言倍数是整数，这里用 `x * h ~/ maxH` 反算源列，顺带把非整数
/// 倍数一起吃掉。
///
/// ## 边界要按真实样本数收，不是按平面宽度
///
/// `renderComponent` 交出来的平面是**补齐过**的（`blocksPerLineForMcu * 8`），
/// 右边和下边挂着 dummy block 的内容。插值取邻居时如果照平面宽度去夹，就会把
/// 那些垃圾拌进最后几列的色度里 —— 右边缘一条彩边，其它地方全对，是很难往
/// 上采样上想的一类 bug。所以这里一律夹在 `sampleWidth / sampleHeight` 上。
///
/// ## 两种滤波
///
/// * **最近邻**：直接复制。块效应明显，但任何倍数都能做。
/// * **三角滤波**（libjpeg 叫 fancy）：`3/4 近 + 1/4 远`，色度边缘平滑得多。
///
/// libjpeg 默认只对 h2v1 和 h2v2 两种倍数走三角滤波，别的倍数退回最近邻。
/// 这里照抄它的分派 —— 不是偷懒，是为了能拿 `djpeg` 的输出做交叉验证：
/// 滤波器选得不一样，色度边缘就会差一两级，整张图的比对全废。
Uint8List upsampleComponent(
  Uint8List plane,
  JpegComponent component,
  JpegFrame frame, {
  bool fancy = true,
}) {
  final int stride = component.blocksPerLineForMcu * kBlockDim;
  final int maxH = frame.maxHorizontalFactor;
  final int maxV = frame.maxVerticalFactor;
  final int h = component.horizontalFactor;
  final int v = component.verticalFactor;

  if (h == maxH && v == maxV) {
    // 这个分量本来就是满分辨率（灰度图、4:4:4 的三个分量），只用裁掉补齐。
    return _crop(plane, stride, frame.width, frame.height);
  }
  if (fancy && maxH == 2 * h) {
    if (maxV == v) {
      return _h2v1Fancy(plane, stride, component, frame);
    }
    if (maxV == 2 * v) {
      return _h2v2Fancy(plane, stride, component, frame);
    }
  }
  return _nearest(plane, stride, component, frame);
}

/// 裁掉为了补齐 MCU 而多出来的右边和下边。
Uint8List _crop(Uint8List plane, int stride, int width, int height) {
  final Uint8List out = Uint8List(width * height);
  for (int y = 0; y < height; y++) {
    out.setRange(y * width, y * width + width, plane, y * stride);
  }
  return out;
}

/// 最近邻：源列 `x * h ~/ maxH`，源行 `y * v ~/ maxV`。
///
/// 整数除法自带向下取整，所以倍数不是整数也算得出来 —— 代价是相邻输出列对应
/// 的源列间距会忽 0 忽 1，平滑渐变上看得出宽窄不一的竖条。
Uint8List _nearest(
  Uint8List plane,
  int stride,
  JpegComponent component,
  JpegFrame frame,
) {
  final int width = frame.width;
  final int height = frame.height;
  final int sw = component.sampleWidth;
  final int sh = component.sampleHeight;
  final int h = component.horizontalFactor;
  final int v = component.verticalFactor;
  final int maxH = frame.maxHorizontalFactor;
  final int maxV = frame.maxVerticalFactor;

  // 列映射每一行都一样，先算一遍存下来。
  final Int32List columns = Int32List(width);
  for (int x = 0; x < width; x++) {
    final int sx = x * h ~/ maxH;
    columns[x] = sx < sw ? sx : sw - 1;
  }

  final Uint8List out = Uint8List(width * height);
  for (int y = 0; y < height; y++) {
    int sy = y * v ~/ maxV;
    if (sy >= sh) {
      sy = sh - 1;
    }
    final int src = sy * stride;
    final int dst = y * width;
    for (int x = 0; x < width; x++) {
      out[dst + x] = plane[src + columns[x]];
    }
  }
  return out;
}

/// 水平 2 倍三角滤波：`(3 × 近 + 远 + 偏置) / 4`。
///
/// 偏置在偶数列取 1、奇数列取 2。两个输出列合起来的舍入误差因此互相抵消 ——
/// 都取同一个偏置的话，大片平色会整体亮或整体暗半级。
///
/// 「远」邻居夹在真实样本范围内，等于把边缘样本复制一份再插值。于是首列和末列
/// 的结果正好等于源样本本身（`(4a + 1) / 4 == a`），和 libjpeg 特判这两列的
/// 写法完全一致。
Uint8List _h2v1Fancy(
  Uint8List plane,
  int stride,
  JpegComponent component,
  JpegFrame frame,
) {
  final int width = frame.width;
  final int height = frame.height;
  final int sw = component.sampleWidth;
  final Uint8List out = Uint8List(width * height);

  for (int y = 0; y < height; y++) {
    // v == maxV，所以行是一对一的，用不着算。
    final int src = y * stride;
    final int dst = y * width;
    for (int x = 0; x < width; x++) {
      // sw == ceil(width / 2)，所以 center 不会越界。
      final int center = x >> 1;
      final int bias = (x & 1) == 0 ? 1 : 2;
      int far = (x & 1) == 0 ? center - 1 : center + 1;
      if (far < 0) {
        far = 0;
      } else if (far >= sw) {
        far = sw - 1;
      }
      out[dst + x] = (3 * plane[src + center] + plane[src + far] + bias) >> 2;
    }
  }
  return out;
}

/// 双向 2 倍三角滤波：先按行凑出 `3 × 近 + 远`，再拿这些和按列做同一件事。
///
/// 能分两步是因为滤波器可分离 —— `(3a + b)` 做两遍展开出来就是四个邻居的
/// 9:3:3:1 加权。行方向的和先存进 colsum，列方向再用一次同样的公式；总权重
/// 变成 16，所以偏置是 8 / 7 而不是 1 / 2。
///
/// 行的取法和列一模一样：偶数输出行往上取远邻，奇数往下取，都夹在真实样本
/// 行数内。首行末行于是各自等于该行本身，和 libjpeg 靠上下文行缓冲拿到的
/// 结果一致。
Uint8List _h2v2Fancy(
  Uint8List plane,
  int stride,
  JpegComponent component,
  JpegFrame frame,
) {
  final int width = frame.width;
  final int height = frame.height;
  final int sw = component.sampleWidth;
  final int sh = component.sampleHeight;
  final Uint8List out = Uint8List(width * height);
  final Int32List colsum = Int32List(sw);

  for (int y = 0; y < height; y++) {
    final int near = y >> 1; // sh == ceil(height / 2)，不会越界
    int far = (y & 1) == 0 ? near - 1 : near + 1;
    if (far < 0) {
      far = 0;
    } else if (far >= sh) {
      far = sh - 1;
    }
    final int nearRow = near * stride;
    final int farRow = far * stride;
    for (int c = 0; c < sw; c++) {
      colsum[c] = 3 * plane[nearRow + c] + plane[farRow + c];
    }

    final int dst = y * width;
    for (int x = 0; x < width; x++) {
      final int center = x >> 1;
      final int bias = (x & 1) == 0 ? 8 : 7;
      int fc = (x & 1) == 0 ? center - 1 : center + 1;
      if (fc < 0) {
        fc = 0;
      } else if (fc >= sw) {
        fc = sw - 1;
      }
      // 上界 (3×1020 + 1020 + 8) >> 4 == 255，用不着夹。
      out[dst + x] = (3 * colsum[center] + colsum[fc] + bias) >> 4;
    }
  }
  return out;
}
