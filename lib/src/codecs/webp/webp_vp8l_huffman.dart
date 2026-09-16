/// VP8L 的前缀码：和 deflate 同一套规范化 Huffman，但传输方式不同。
///
/// ## 能复用 `compress/huffman.dart` 的原因
///
/// JPEG 的 Huffman 我们**没有**复用（位序相反、码长上限 16、传输形式是两个
/// 平坦数组）。VP8L 相反，三件事都和 deflate 一致：
///
/// * 位序一致 —— 都是 LSB-first 取字节内的位，码字从高位往低位拼
/// * 码长上限一致 —— 都是 15 位
/// * 都是规范化码表 —— 只传码长，码字由排序约定推出
///
/// 所以 [HuffmanTable] 原样能用。VP8L 独有的只是**码长本身怎么传**，
/// 那部分在这个文件里。
///
/// ## 两种传输形式
///
/// ```
/// 简单码：1 位标志 = 1
///         1 位 → 符号个数 - 1（所以只能是 1 或 2 个符号）
///         1 位 → 第一个符号是 1 位还是 8 位
///         符号值本身，两个符号时第二个恒为 8 位
///
/// 普通码：1 位标志 = 0
///         先读一张「码长的码表」（19 个符号，各 3 位码长）
///         再用它解出真正的码长序列
/// ```
///
/// 「码长的码表」这层套娃和 deflate 的动态块是同一个思路。区别是 deflate
/// 传 4+ 个 3 位码长按固定顺序，VP8L 传 4..19 个 —— 个数自己也在码流里。
///
/// ## 唯一真正的坑：只有一个符号的码字占 0 位
///
/// 一张只有一个符号的码表，「读一位来区分」是没有意义的 —— 没有第二个符号
/// 可供区分。规范的做法是这种码**不消费任何位**，解码时直接返回那个符号。
///
/// 简单码里 `num_symbols == 1` 会走到这里，普通码里「只有一个符号码长非零」
/// 也会。两条路合并成同一条规则：**恰好一个符号有非零码长 ⇒ 零位码**。
///
/// 漏掉这条的症状极具欺骗性：单色图（最简单的输入）解不出来，而复杂的图
/// 好好的。因为只有单色图才会让编码器发出单符号码表。
library;

import 'package:image_viewer/src/codecs/webp/webp_types.dart';
import 'package:image_viewer/src/compress/huffman.dart';
import 'package:image_viewer/src/core/bit_reader_lsb.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 「码长的码表」有 19 个符号：0..15 是码长本身，16..18 是三种重复指令。
const int kCodeLengthCodes = 19;

/// 读这 19 个码长时的顺序，规范写死。
///
/// 不按 0..18 顺序读，是因为 17（重复零）和 18（重复长零串）在真实图像里
/// 出现得最频繁，把它们排在最前面，后面用不到的码长可以整段省掉不传
/// （`num_code_lengths` 一小，尾巴就全是 0）。deflate 的
/// `kCodeLengthOrder` 是同一个把戏。
const List<int> kCodeLengthCodeOrder = <int>[
  17, 18, 0, 1, 2, 3, 4, 5, 16, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15,
];

/// 符号 16/17/18 各自的额外位数与重复次数基数。
///
/// * 16 → 重复**前一个非零码长** 3..6 次（2 位额外）
/// * 17 → 重复零 3..10 次（3 位额外）
/// * 18 → 重复零 11..138 次（7 位额外）
const List<int> kCodeLengthExtraBits = <int>[2, 3, 7];
const List<int> kCodeLengthRepeatOffsets = <int>[3, 3, 11];

/// 符号 16 之前的「前一个非零码长」初值，规范定为 8。
const int kDefaultPrevCodeLength = 8;

/// 五个字母表的规模。
///
/// 绿色通道那张表是**三件东西挤在一个字母表里**：256 个字面量 + 24 个
/// LZ77 长度码 + 颜色缓存的索引。所以它的规模随缓存位数变，其余四张都固定。
///
/// 这个合并是 VP8L 省位的关键 —— 「下一个是字面像素、是反向引用、还是缓存
/// 命中」这个三选一不用单独花位去说，读一个绿色符号就知道了。
const int kNumLiteralCodes = 256;
const int kNumLengthCodes = 24;
const int kNumDistanceCodes = 40;

/// 一张前缀码表，可能是「零位码」。
///
/// 见库注释最后一节：恰好一个符号有非零码长时，该码**不消费任何位**。
/// 这一条把简单码的单符号情形和普通码的单符号情形统一了。
class Vp8lPrefixCode {
  Vp8lPrefixCode._(this._table, this._symbol);

  /// 从码长序列建表。`lengths[s]` 为 0 表示符号 s 不参与编码。
  factory Vp8lPrefixCode.fromLengths(
    List<int> lengths, {
    required String what,
  }) {
    int nonZero = 0;
    int lastNonZero = -1;
    for (int s = 0; s < lengths.length; s++) {
      if (lengths[s] != 0) {
        nonZero++;
        lastNonZero = s;
      }
    }
    if (nonZero == 0) {
      throw ImageDecodeException(
        '$what 里没有任何符号（全部码长为 0），码流已损坏',
        format: kWebpFormat,
      );
    }
    // 零位码。注意这里**不能**建 HuffmanTable —— 它的 decode 会读掉一位。
    if (nonZero == 1) {
      return Vp8lPrefixCode._(null, lastNonZero);
    }
    return Vp8lPrefixCode._(
      HuffmanTable.fromLengths(lengths, format: kWebpFormat, what: what),
      -1,
    );
  }

  final HuffmanTable? _table;

  /// 零位码时的那个符号，否则为 -1。
  final int _symbol;

  /// 是零位码（只有一个符号）。
  bool get isTrivial => _table == null;

  /// 读一个符号。零位码时不动位流。
  int decode(BitReaderLsb reader) {
    final HuffmanTable? t = _table;
    return t == null ? _symbol : t.decode(reader);
  }
}

/// 码长符号 16..18 的起点。小于它的符号就是码长本身。
const int kCodeLengthLiterals = 16;

/// 从码流读一张前缀码表。
Vp8lPrefixCode readPrefixCode(
  BitReaderLsb reader,
  int alphabetSize, {
  required String what,
}) {
  if (reader.readBit() == 1) {
    return _readSimpleCode(reader, alphabetSize, what);
  }
  return _readNormalCode(reader, alphabetSize, what);
}

/// 简单码：直接把 1 或 2 个符号值写在码流里，不传码长。
///
/// 第一个符号可以用 1 位或 8 位表示（1 位那档专为「只用到 0 和 1」的通道，
/// 比如全不透明图的 alpha 表）。第二个符号恒 8 位。
Vp8lPrefixCode _readSimpleCode(
  BitReaderLsb reader,
  int alphabetSize,
  String what,
) {
  final int numSymbols = reader.readBits(1) + 1;
  final int firstBits = reader.readBit() == 1 ? 8 : 1;
  final List<int> lengths = List<int>.filled(alphabetSize, 0);

  void put(int symbol) {
    // 符号值来自码流，必须当恶意值对待：距离表只有 40 个符号，但这里读的
    // 是 8 位，能给出 255。不检查就是一次数组越界写。
    if (symbol >= alphabetSize) {
      throw ImageDecodeException(
        '$what 的简单码给出符号 $symbol，超出字母表规模 $alphabetSize',
        format: kWebpFormat,
      );
    }
    lengths[symbol] = 1;
  }

  put(reader.readBits(firstBits));
  if (numSymbols == 2) {
    put(reader.readBits(8));
  }
  // 两个符号相同时会塌回单符号 —— 那就是零位码，由 fromLengths 认出来。
  return Vp8lPrefixCode.fromLengths(lengths, what: what);
}

/// 普通码：先读一张「码长的码表」，再用它解出真正的码长序列。
Vp8lPrefixCode _readNormalCode(
  BitReaderLsb reader,
  int alphabetSize,
  String what,
) {
  // 4..19 个 3 位码长，按 kCodeLengthCodeOrder 的顺序摆放。
  final int numCodeLengths = 4 + reader.readBits(4);
  final List<int> metaLengths = List<int>.filled(kCodeLengthCodes, 0);
  for (int i = 0; i < numCodeLengths; i++) {
    metaLengths[kCodeLengthCodeOrder[i]] = reader.readBits(3);
  }

  final Vp8lPrefixCode meta = Vp8lPrefixCode.fromLengths(
    metaLengths,
    what: '$what 的码长码表',
  );

  final List<int> lengths = _readCodeLengths(reader, meta, alphabetSize, what);
  return Vp8lPrefixCode.fromLengths(lengths, what: what);
}

/// 用「码长的码表」解出真正的码长序列。
///
/// ## `max_symbol` 是「读几个符号」，不是「填几个码长」
///
/// 码流里可以带一个上限，说明「后面只有这么多个码长符号，剩下的全是 0」。
/// 它计的是**从码流里读了几个符号**，而一个重复指令一次能填很多个码长。
/// 所以它和 `symbol` 不是同一个计数器，两者必须分开维护。
///
/// 把它当成「填了几个码长」的上限是个很容易犯的错，而且症状只在用到重复
/// 指令的图上出现 —— 简单的图照样能解。
List<int> _readCodeLengths(
  BitReaderLsb reader,
  Vp8lPrefixCode meta,
  int alphabetSize,
  String what,
) {
  final List<int> lengths = List<int>.filled(alphabetSize, 0);

  int maxSymbol;
  if (reader.readBit() == 1) {
    final int lengthBits = 2 + 2 * reader.readBits(3);
    maxSymbol = 2 + reader.readBits(lengthBits);
    if (maxSymbol > alphabetSize) {
      throw ImageDecodeException(
        '$what 声称有 $maxSymbol 个码长符号，超出字母表规模 $alphabetSize',
        format: kWebpFormat,
      );
    }
  } else {
    maxSymbol = alphabetSize;
  }

  int symbol = 0;
  int prevCodeLength = kDefaultPrevCodeLength;

  while (symbol < alphabetSize) {
    if (maxSymbol-- == 0) {
      break;
    }
    final int codeLength = meta.decode(reader);

    if (codeLength < kCodeLengthLiterals) {
      lengths[symbol++] = codeLength;
      // 只有非零码长才更新「前一个」——「重复前一个」指的是前一个**非零**
      // 码长，中间夹着的零不算。
      if (codeLength != 0) {
        prevCodeLength = codeLength;
      }
      continue;
    }

    // 16 重复前一个非零码长，17/18 重复零。
    final int slot = codeLength - kCodeLengthLiterals;
    final int fill = codeLength == kCodeLengthLiterals ? prevCodeLength : 0;
    int repeat = reader.readBits(kCodeLengthExtraBits[slot]) +
        kCodeLengthRepeatOffsets[slot];

    if (symbol + repeat > alphabetSize) {
      throw ImageDecodeException(
        '$what 的重复指令要填 $repeat 个码长，但从 $symbol 起'
        '只剩 ${alphabetSize - symbol} 个位置',
        format: kWebpFormat,
      );
    }
    while (repeat-- > 0) {
      lengths[symbol++] = fill;
    }
  }

  return lengths;
}

/// 一组五张前缀码表 —— 解一个像素要用到的全部码表。
///
/// ## 为什么是五张而不是一张
///
/// 四个通道的统计特性完全不同：绿色通道信息量最大（另外两个色度通道通常
/// 已经被「减绿」变换削成了接近零的小值），alpha 在多数图里是常数。用同一
/// 张码表会让 alpha 的那个常数值和绿色的 256 个值抢编码空间。
///
/// 第五张是距离表，服务 LZ77 反向引用。
///
/// ## meta-Huffman：一张图可以有很多组
///
/// 这是 VP8L 最精巧的地方（`design.md` 第 4.6 节的评价）。图像被切成
/// 若干块，一张「熵图像」为每块指定用哪一组码表。于是照片区域和纯色区域
/// 可以各用最适合自己的统计模型，而代价只是熵图像本身那点体积。
///
/// 熵图像自己也是一张 VP8L 图像，递归解码 —— 见 `webp_vp8l.dart`。
class Vp8lHuffmanGroup {
  const Vp8lHuffmanGroup({
    required this.green,
    required this.red,
    required this.blue,
    required this.alpha,
    required this.distance,
  });

  /// 从码流读一组。五张表的顺序由规范固定。
  factory Vp8lHuffmanGroup.read(BitReaderLsb reader, int colorCacheSize) {
    // 绿色那张表额外容纳 24 个长度码和整个颜色缓存的索引。
    final int greenSize =
        kNumLiteralCodes + kNumLengthCodes + colorCacheSize;
    return Vp8lHuffmanGroup(
      green: readPrefixCode(reader, greenSize, what: '绿色/长度码表'),
      red: readPrefixCode(reader, kNumLiteralCodes, what: '红色码表'),
      blue: readPrefixCode(reader, kNumLiteralCodes, what: '蓝色码表'),
      alpha: readPrefixCode(reader, kNumLiteralCodes, what: 'alpha 码表'),
      distance: readPrefixCode(reader, kNumDistanceCodes, what: '距离码表'),
    );
  }

  final Vp8lPrefixCode green;
  final Vp8lPrefixCode red;
  final Vp8lPrefixCode blue;
  final Vp8lPrefixCode alpha;
  final Vp8lPrefixCode distance;
}
