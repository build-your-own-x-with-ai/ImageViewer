/// Adler-32 校验和 —— zlib 流尾部那四个字节。
///
/// ## 为什么 PNG 里有两种校验和
///
/// 一个 PNG 文件里同时存在两套校验，初学者常以为其中一个是多余的：
///
/// | | 算法 | 保护对象 | 谁定的 |
/// |---|---|---|---|
/// | chunk 尾部 | CRC-32 | 每个 chunk 的类型+数据 | PNG 规范 |
/// | zlib 流尾部 | Adler-32 | **解压后**的原始字节 | zlib 规范（RFC 1950） |
///
/// 两者的检查点不同：CRC-32 保证「压缩数据在传输中没坏」，Adler-32 保证
/// 「解压出来的东西和压缩前一致」。前者验证的是密封的箱子，后者验证的是
/// 箱子里的货 —— 一个解压器实现有 bug 时，CRC 会全部通过而 Adler 会报错。
/// 对我们这种自写 inflate 的项目来说，Adler-32 是最有价值的一道防线。
///
/// ## 算法本身
///
/// 比 CRC-32 简单得多，两个累加器：
///
/// ```
/// a = 1 + d1 + d2 + ... + dn           (mod 65521)
/// b = n*1 + (n-1)*d1 + ... + dn + n    (mod 65521)   ← 即每步累加 a
/// 结果 = b * 65536 + a
/// ```
///
/// `a` 只是字节和，捕捉不到顺序错误；`b` 累加的是 `a`，所以对顺序敏感。
/// 65521 是小于 2^16 的最大素数 —— 取素数是为了让进位在模运算下均匀散开。
///
/// 代价是它比 CRC-32 弱（对短数据尤其弱），好处是快且好实现。zlib 选它
/// 是因为压缩流本身已经有 CRC 保护的场合很多，不必重复付代价。
library;

import 'dart:typed_data';

/// Adler-32 的模数：小于 2^16 的最大素数。
const int _kModulus = 65521;

/// 分批取模的批长。
///
/// 每字节都取一次模会很慢，但攒太多又会溢出。5552 是 zlib 里用的经典值：
/// 它保证 `b` 在批内的最大值不超过 32 位无符号范围。
///
/// 本项目的实际约束比 32 位更宽松 —— Dart 编译到 Web 时整数是 IEEE 754
/// 双精度，安全整数上限是 2^53。但沿用 5552 没有坏处，且与参考实现对齐，
/// 便于逐步调试时对照中间值。
const int _kBatch = 5552;

/// 计算 [data] 在 `[start, end)` 区间上的 Adler-32。
///
/// 返回值是 32 位无符号数，用乘法而非 `<<` 拼接高位 —— 在 Web 上 `b << 16`
/// 会走 32 位有符号语义，`b` 的最高位一旦是 1 结果就变成负数。这类 bug
/// 只在 Web 上出现，原生平台测试全绿，极难定位。
int adler32(Uint8List data, {int start = 0, int? end}) {
  final int stop = end ?? data.length;
  RangeError.checkValidRange(start, stop, data.length);

  int a = 1;
  int b = 0;
  int i = start;

  while (i < stop) {
    final int batchEnd = (stop - i) > _kBatch ? i + _kBatch : stop;
    // 批内不取模，攒够一批再统一模一次。
    while (i < batchEnd) {
      a += data[i++];
      b += a;
    }
    a %= _kModulus;
    b %= _kModulus;
  }

  return b * 65536 + a;
}
