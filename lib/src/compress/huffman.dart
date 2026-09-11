import 'dart:typed_data';

import 'package:image_viewer/src/core/bit_reader_lsb.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 码长上限：deflate 与 VP8L 里任何 Huffman 码字都不超过 15 位。
///
/// 定这个上限的实际收益是**解码循环有界** —— 畸形码表没法把我们拖进
/// 死循环。15 位可容纳 32768 个码字，而 deflate 的字面/长度字母表只有
/// 288 个符号，远远够用。
const int kMaxCodeBits = 15;

/// 规范化 Huffman 码表（canonical Huffman）。
///
/// ## 关键认识：码长决定码字，不需要传码字本身
///
/// 初学者看 deflate 的动态块时最大的困惑是：**码表里只有码长，码字呢？**
///
/// 答案是码字可以由码长唯一推出来，只要双方约定同一条规则：
///
/// 1. 按码长从小到大排；
/// 2. 同码长内按符号编号从小到大排；
/// 3. 第一个码字为 0，同码长内每个码字比前一个大 1；
/// 4. 码长每增加 1，码字左移一位。
///
/// 举例，四个符号 A/B/C/D 的码长分别是 2/1/3/3：
///
/// ```
/// 码长 1：B → 0
/// 码长 2：A → 10          (0+1=1，左移 → 10)
/// 码长 3：C → 110         (10+1=11，左移 → 110)
///         D → 111
/// ```
///
/// 于是码流里只传 `[2, 1, 3, 3]` 就够了。这就是「规范化」的全部含义 ——
/// 用一条排序约定换掉码字表本身。
///
/// ## 为什么不建树
///
/// 教科书讲 Huffman 都画二叉树，但解码不需要树。上面的规则意味着**同码长
/// 的码字是连续递增的整数**，所以只要知道「每个码长有几个码字」和「该码长
/// 的首码字」，就能靠一次减法算出符号在表里的下标。
///
/// 于是数据结构退化成两个平坦数组（[_counts] 与 [_symbols]），解码循环
/// 二十行、无指针跳转、无内存分配。这比树省内存也更快。
///
/// 实现思路取自 zlib 作者的教学代码 `puff.c` —— 那是理解 deflate 最好的
/// 参考，本项目的变量命名也刻意与它靠近，便于对照阅读。
class HuffmanTable {
  HuffmanTable._(this._counts, this._symbols, this.format, this.what);

  /// `_counts[n]` = 码长恰为 n 的码字个数。下标 0 恒为 0（没有 0 位码字）。
  final Uint16List _counts;

  /// 所有符号，按「码长升序、同码长内符号编号升序」排列。
  ///
  /// 这个顺序就是规范化码表的排序约定本身，所以解码时不需要额外索引。
  final Uint16List _symbols;

  /// 格式名，仅用于异常信息（`'deflate'` / `'VP8L'`）。
  final String format;

  /// 这张表是干什么的，仅用于异常信息（`'字面/长度码表'`）。
  final String what;

  /// 表里有多少个码字。
  int get symbolCount => _symbols.length;

  /// 是否是空表（没有任何码字）。
  ///
  /// 空表是**合法**的：一张只有字面量、没有任何 LZ77 反向引用的图，
  /// 距离码表就是空的。空表不能用于解码，[decode] 会拒绝。
  bool get isEmpty => _symbols.isEmpty;

  /// 从码长表构造。`lengths[s]` 是符号 s 的码长，0 表示该符号不参与编码。
  ///
  /// ## 两种非法码表，各有说法
  ///
  /// 建表时顺带做完整性校验，这是**唯一**能廉价发现码表损坏的时机 ——
  /// 一旦进了解码循环，错误只会表现为「解出一堆合法但错误的字节」。
  ///
  /// **过订阅（over-subscribed）**：某码长的码字个数超过了该长度能容纳的
  /// 数量，比如声明三个 1 位码字（1 位最多两个）。这一定是数据损坏。
  ///
  /// **不完整（incomplete）**：码字没用满编码空间，存在一段没有任何符号
  /// 对应的位模式。这种表本身能解码，但遇到那段位模式就无法解释。
  ///
  /// 对不完整表的处理是有讲究的：**符号数 ≤ 1 时放行，否则拒绝**。
  /// 因为「只有一个符号」是真实存在的正常情况 —— 全图只有一种距离时，
  /// 距离表就只有一个 1 位码字，编码空间用了一半。zlib 也是这么处理的。
  /// 而符号数 ≥ 2 的不完整表在正常压缩器的输出里不会出现。
  factory HuffmanTable.fromLengths(
    List<int> lengths, {
    String format = 'deflate',
    String what = 'Huffman 码表',
  }) {
    final Uint16List counts = Uint16List(kMaxCodeBits + 1);
    for (final int len in lengths) {
      if (len < 0 || len > kMaxCodeBits) {
        throw ImageDecodeException(
          '$what 的码长 $len 越界（应在 0..$kMaxCodeBits）',
          format: format,
        );
      }
      counts[len]++;
    }
    // 码长 0 表示「不参与编码」，不是长度为 0 的码字。
    counts[0] = 0;

    // 完整性校验：从 1 位开始，每层可用码字数翻倍，减去本层用掉的。
    // left 归零表示刚好用满；负数是过订阅；结束时为正是不完整。
    int left = 1;
    for (int len = 1; len <= kMaxCodeBits; len++) {
      left <<= 1;
      left -= counts[len];
      if (left < 0) {
        throw ImageDecodeException(
          '$what 过订阅：码长 $len 的码字个数超出可用编码空间'
          '（多出 ${-left} 个），压缩数据已损坏',
          format: format,
        );
      }
    }

    // 各码长在 _symbols 里的起始下标 —— 即「码长升序」这条排序约定的落地。
    final Uint16List offsets = Uint16List(kMaxCodeBits + 2);
    for (int len = 1; len <= kMaxCodeBits; len++) {
      offsets[len + 1] = offsets[len] + counts[len];
    }

    int total = 0;
    for (int len = 1; len <= kMaxCodeBits; len++) {
      total += counts[len];
    }
    final Uint16List symbols = Uint16List(total);
    // 按符号编号升序遍历，天然满足「同码长内按编号升序」。
    //
    // 游标用 `offsets[len]` 而不是 `offsets[len + 1]`：offsets[len] 是
    // 码长 len 的**起始**下标，offsets[len + 1] 是下一档的起始。用后者
    // 会把每个符号写进相邻的错误区间，最后一档还会越界 —— 建表阶段的
    // 下标差一，症状是解出来的符号全错，但错得很有规律。
    for (int symbol = 0; symbol < lengths.length; symbol++) {
      final int len = lengths[symbol];
      if (len != 0) {
        symbols[offsets[len]++] = symbol;
      }
    }

    if (left > 0 && total > 1) {
      throw ImageDecodeException(
        '$what 不完整：还有 $left 个码字未分配，'
        '存在无法解释的位模式，压缩数据已损坏',
        format: format,
      );
    }

    return HuffmanTable._(counts, symbols, format, what);
  }

  /// 从 [reader] 逐位读出一个符号。
  ///
  /// ## 二十行里发生了什么
  ///
  /// 每轮循环处理一个码长。三个游标同步推进：
  ///
  /// * `code` —— 目前已读入的位拼成的值
  /// * `first` —— 当前码长的**首**码字
  /// * `index` —— 当前码长在 [_symbols] 里的起始下标
  ///
  /// 判据是 `code - first < count`：因为同码长的码字连续递增，所以
  /// 「当前值减去首码字」正好是它在本码长内的序号，也就是在 [_symbols]
  /// 里相对 `index` 的偏移。**一次减法定位符号，不需要任何查找。**
  ///
  /// 不匹配就进入下一码长：`first` 和 `code` 各左移一位（码长加一，码字
  /// 空间翻倍），`index` 跳过本码长的所有符号。
  ///
  /// ## 位序：为什么逐位读而不是一次读 15 位
  ///
  /// Huffman 码字在 deflate 里是**从码字的高位开始**存的，而字节内的位
  /// 是 LSB-first 取的（见 [BitReaderLsb]）。两个方向相反，所以只能一位
  /// 一位读、每读一位把它拼到 `code` 的最低位上。
  ///
  /// 这也是为什么 [BitReaderLsb.peekBits] 那种「一次预览最大码长再查表」
  /// 的加速需要先把位序翻转 —— 本项目取朴素版，一是够快（PNG 解码的热点
  /// 在反 filter 不在这里），二是这样代码和上面那段推导一一对应。
  int decode(BitReaderLsb reader) {
    if (_symbols.isEmpty) {
      throw ImageDecodeException(
        '$what 是空表，但码流里出现了需要用它解码的符号'
        '（多半是压缩数据损坏，或本该是纯字面量的块里出现了反向引用）',
        format: format,
      );
    }

    int code = 0;
    int first = 0;
    int index = 0;

    for (int len = 1; len <= kMaxCodeBits; len++) {
      code |= reader.readBit();
      final int count = _counts[len];
      if (code - first < count) {
        return _symbols[index + (code - first)];
      }
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }

    // 读满 15 位仍未命中。码表建表时已校验过完整性，所以走到这里说明
    // 码流本身损坏（位模式落在了不完整表的空洞里）。
    throw ImageDecodeException(
      '$what 解码失败：连续 $kMaxCodeBits 位都没有匹配任何码字，'
      '压缩数据已损坏',
      format: format,
    );
  }
}
