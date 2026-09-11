/// 手写 deflate / zlib 字节的构造器。
///
/// ## 这里的校验和是刻意重写一遍的
///
/// 用被测的 `adler32()` 去造测试数据，再拿它验证 `adler32()`，等于什么都
/// 没测 —— 公式写错时两边会一起错。所以这里的 Adler-32 是逐字节取模的
/// 朴素版（被测代码为了性能做了批处理延迟取模），CRC-32 是逐位移位的
/// 朴素版（被测代码是查表版）。
///
/// 两个实现从算法形态上就不一样，结果相同才说明两边都对。这是
/// `docs/testing.md` 里「交叉验证」那条原则在校验和上的落地。
library;

import 'dart:typed_data';

/// 朴素 Adler-32：逐字节取模，直译定义。
int naiveAdler32(List<int> data) {
  int a = 1;
  int b = 0;
  for (final int byte in data) {
    a = (a + byte) % 65521;
    b = (b + a) % 65521;
  }
  return b * 65536 + a;
}

/// 逐位计算的 CRC-32，不建表。
int bitwiseCrc32(List<int> data) {
  int crc = 0xFFFFFFFF;
  for (final int byte in data) {
    crc ^= byte;
    for (int i = 0; i < 8; i++) {
      crc = (crc & 1) != 0 ? (crc >>> 1) ^ 0xEDB88320 : crc >>> 1;
    }
  }
  return (crc ^ 0xFFFFFFFF) & 0xFFFFFFFF;
}

/// 构造存储块（BTYPE=00）的裸 deflate 流。
///
/// 存储块不压缩，只是把字节原样包起来：
///
/// ```
/// 1 位 BFINAL + 2 位 BTYPE(00) + 补齐到字节 + LEN(2,小端) + ~LEN(2) + 原始字节
/// ```
///
/// 之所以拿它当 PNG 测试的主力，是因为它**不需要 Huffman 编码器**就能
/// 造出合法的压缩流 —— PNG 各层（chunk、滤波、像素展开）的测试因此
/// 不必依赖 Huffman 路径是否正确，两者可以独立排查。
///
/// 单块上限 65535 字节，超出就切多块。
List<int> storedDeflate(List<int> data) {
  final List<int> out = <int>[];
  int at = 0;
  do {
    final int len = data.length - at > 65535 ? 65535 : data.length - at;
    final bool isFinal = at + len >= data.length;
    out.add(isFinal ? 1 : 0);
    out.add(len & 0xFF);
    out.add((len >> 8) & 0xFF);
    final int n = ~len & 0xFFFF;
    out.add(n & 0xFF);
    out.add((n >> 8) & 0xFF);
    out.addAll(data.sublist(at, at + len));
    at += len;
  } while (at < data.length);
  return out;
}

/// 给裸 deflate 流套上 zlib 头尾。
///
/// [uncompressed] 是解压后应得的字节 —— Adler-32 算的是**解压后**的数据，
/// 不是压缩流。这一点和 PNG 的 CRC 恰好相反（CRC 算的是压缩后的字节），
/// 一个文件里两种校验和覆盖两个不同阶段。
Uint8List zlibWrap(List<int> raw, List<int> uncompressed) {
  final int sum = naiveAdler32(uncompressed);
  return Uint8List.fromList(<int>[
    0x78, 0x01, // CM=8, CINFO=7, FCHECK 使 0x7801 % 31 == 0
    ...raw,
    (sum >> 24) & 0xFF, (sum >> 16) & 0xFF, (sum >> 8) & 0xFF, sum & 0xFF,
  ]);
}

/// 存储块的完整 zlib 流。PNG 测试用得最多的一个。
Uint8List storedZlib(List<int> data) => zlibWrap(storedDeflate(data), data);

/// LSB-first 位写入器，与 `BitReaderLsb` 对应。
class BitWriterLsb {
  final List<int> _bytes = <int>[];
  int _bit = 0;
  int _current = 0;

  /// 写 [count] 位，低位先出。
  void writeBits(int value, int count) {
    for (int i = 0; i < count; i++) {
      if ((value >> i) & 1 != 0) {
        _current |= 1 << _bit;
      }
      _bit++;
      if (_bit == 8) {
        _bytes.add(_current);
        _current = 0;
        _bit = 0;
      }
    }
  }

  /// 写一个 Huffman 码字，**高位先出**。
  ///
  /// 这是 deflate 里最容易搞错的一处：数据字段（长度、距离的额外位）
  /// 按低位先出，而 Huffman 码字按高位先出。同一条位流里两种顺序并存，
  /// 原因是 Huffman 码需要「从前缀开始逐位判断」，高位先出才能边读边走。
  void writeCode(int code, int length) {
    for (int i = length - 1; i >= 0; i--) {
      writeBits((code >> i) & 1, 1);
    }
  }

  /// 补齐到字节边界并取出结果。
  List<int> toBytes() {
    if (_bit > 0) {
      _bytes.add(_current);
    }
    return _bytes;
  }
}

/// 用固定 Huffman 表编码一串字面量（不做 LZ77 匹配）。
///
/// 固定表的字面量码字：0..143 是 8 位的 0x30..0xBF，144..255 是 9 位的
/// 0x190..0x1FF，结束符 256 是 7 位的 0。
List<int> fixedHuffmanLiterals(List<int> data) =>
    fixedHuffmanBlock(<Object>[...data]);

/// LZ77 的一个反向引用。
class Match {
  const Match(this.length, this.distance);
  final int length;
  final int distance;
}

/// 长度码的基值与额外位数，符号 257..285。照 RFC 1951 表格手抄一遍。
const List<List<int>> lengthCodes = <List<int>>[
  <int>[3, 0], <int>[4, 0], <int>[5, 0], <int>[6, 0], <int>[7, 0],
  <int>[8, 0], <int>[9, 0], <int>[10, 0], <int>[11, 1], <int>[13, 1],
  <int>[15, 1], <int>[17, 1], <int>[19, 2], <int>[23, 2], <int>[27, 2],
  <int>[31, 2], <int>[35, 3], <int>[43, 3], <int>[51, 3], <int>[59, 3],
  <int>[67, 4], <int>[83, 4], <int>[99, 4], <int>[115, 4], <int>[131, 5],
  <int>[163, 5], <int>[195, 5], <int>[227, 5], <int>[258, 0],
];

/// 距离码的基值与额外位数，符号 0..29。
const List<List<int>> distanceCodes = <List<int>>[
  <int>[1, 0], <int>[2, 0], <int>[3, 0], <int>[4, 0], <int>[5, 1],
  <int>[7, 1], <int>[9, 2], <int>[13, 2], <int>[17, 3], <int>[25, 3],
  <int>[33, 4], <int>[49, 4], <int>[65, 5], <int>[97, 5], <int>[129, 6],
  <int>[193, 6], <int>[257, 7], <int>[385, 7], <int>[513, 8], <int>[769, 8],
  <int>[1025, 9], <int>[1537, 9], <int>[2049, 10], <int>[3073, 10],
  <int>[4097, 11], <int>[6145, 11], <int>[8193, 12], <int>[12289, 12],
  <int>[16385, 13], <int>[24577, 13],
];

/// 找到能表示 [value] 的码：返回 `[符号下标, 额外位数, 额外位的值]`。
List<int> _pickCode(List<List<int>> table, int value) {
  for (int i = table.length - 1; i >= 0; i--) {
    if (value >= table[i][0]) {
      return <int>[i, table[i][1], value - table[i][0]];
    }
  }
  throw ArgumentError('$value 无法用该码表表示');
}

/// 用固定 Huffman 表编码一串 token。
///
/// [tokens] 的每一项是 `int`（字面量）或 [Match]（反向引用）。
List<int> fixedHuffmanBlock(List<Object> tokens, {bool isFinal = true}) {
  final BitWriterLsb w = BitWriterLsb();
  w.writeBits(isFinal ? 1 : 0, 1);
  w.writeBits(1, 2); // BTYPE = 01

  for (final Object t in tokens) {
    if (t is int) {
      if (t < 144) {
        w.writeCode(0x30 + t, 8);
      } else {
        w.writeCode(0x190 + t - 144, 9);
      }
    } else if (t is Match) {
      final List<int> len = _pickCode(lengthCodes, t.length);
      final int lenSymbol = 257 + len[0];
      // 符号 256..279 是 7 位，280..287 是 8 位。
      if (lenSymbol <= 279) {
        w.writeCode(lenSymbol - 256, 7);
      } else {
        w.writeCode(0xC0 + lenSymbol - 280, 8);
      }
      // 额外位按低位先出 —— 与 Huffman 码字的高位先出相反。
      w.writeBits(len[2], len[1]);

      final List<int> dist = _pickCode(distanceCodes, t.distance);
      w.writeCode(dist[0], 5); // 固定表的距离码一律 5 位
      w.writeBits(dist[2], dist[1]);
    } else {
      throw ArgumentError('token 必须是 int 或 Match，实际是 ${t.runtimeType}');
    }
  }

  w.writeCode(0, 7); // 结束符 256
  return w.toBytes();
}

/// 用给定的两张码表把 [tokens] 写进 [w]，末尾补上结束符 256。
///
/// 与 [fixedHuffmanBlock] 里那段的区别只在码字从哪来：固定表的码字是
/// 写死的，动态表的要先由码长算出来。长度/距离的基值与额外位数两边共用
/// 同一套表格 —— 那部分本来就是 RFC 的常量。
void writeTokens(
  BitWriterLsb w,
  List<Object> tokens,
  Map<int, List<int>> litCodes,
  Map<int, List<int>> distCodes,
) {
  void emit(Map<int, List<int>> codes, int symbol) {
    final List<int>? code = codes[symbol];
    if (code == null) {
      throw ArgumentError('码表里没有符号 $symbol，码长表给漏了');
    }
    w.writeCode(code[0], code[1]);
  }

  for (final Object t in tokens) {
    if (t is int) {
      emit(litCodes, t);
    } else if (t is Match) {
      final List<int> len = _pickCode(lengthCodes, t.length);
      emit(litCodes, 257 + len[0]);
      w.writeBits(len[2], len[1]);
      final List<int> dist = _pickCode(distanceCodes, t.distance);
      emit(distCodes, dist[0]);
      w.writeBits(dist[2], dist[1]);
    } else {
      throw ArgumentError('token 必须是 int 或 Match，实际是 ${t.runtimeType}');
    }
  }
  emit(litCodes, 256);
}

/// 码长的传输顺序，照 RFC 1951 手抄。被测代码里也有一份，刻意不共用。
const List<int> codeLengthOrder = <int>[
  16, 17, 18, 0, 8, 7, 9, 6, 10, 5, 11, 4, 12, 3, 13, 2, 14, 1, 15,
];

/// 由码长独立算出规范化码字，返回 `符号 → [码字, 位数]`。
///
/// 这是「规范化 Huffman」定义的直接翻译：按码长从小到大、同码长内按
/// 符号编号从小到大，码字依次加一，换档时左移一位。被测的
/// `HuffmanTable` 用的是 counts/offsets 的扁平数组形式，两者形态完全
/// 不同 —— 结果一致才说明双方都对。
Map<int, List<int>> canonicalCodes(List<int> lengths) {
  final Map<int, List<int>> out = <int, List<int>>{};
  int code = 0;
  for (int len = 1; len <= 15; len++) {
    for (int sym = 0; sym < lengths.length; sym++) {
      if (lengths[sym] == len) {
        out[sym] = <int>[code, len];
        code++;
      }
    }
    code <<= 1;
  }
  return out;
}

/// 给 [symbols] 里的每个符号分配码长，保证构成**完整**码表。
///
/// k 个符号时取 m = ceil(log2(k))、r = 2^m - k，让前 r 个符号用 m-1 位、
/// 其余用 m 位。此时 Σ 2^-len 恰好等于 1，即码表刚好用满，不会被
/// 「过订阅」或「不完整」的校验拦下。
List<int> completeLengths(List<int> symbols, int tableSize) {
  final List<int> lengths = List<int>.filled(tableSize, 0);
  final List<int> sorted = symbols.toList()..sort();
  if (sorted.length == 1) {
    lengths[sorted.first] = 1; // 退化的单码字，zlib 也会产出
    return lengths;
  }
  int m = 1;
  while ((1 << m) < sorted.length) {
    m++;
  }
  final int r = (1 << m) - sorted.length;
  for (int i = 0; i < sorted.length; i++) {
    lengths[sorted[i]] = i < r ? m - 1 : m;
  }
  return lengths;
}

/// 长度 [length] 对应的字面/长度字母表符号（257..285）。
int lengthSymbol(int length) => 257 + _pickCode(lengthCodes, length)[0];

/// 距离 [distance] 对应的距离字母表符号（0..29）。
int distanceSymbol(int distance) => _pickCode(distanceCodes, distance)[0];

/// 推出编码 [tokens] 需要哪些符号，返回 `[字面/长度符号, 距离符号]`。
///
/// 构造动态块时得先知道「哪些符号要有码字」，才能给它们分配码长。漏一个
/// 符号，编码时就会撞上「码表里没有这个符号」。
List<List<int>> symbolsFor(List<Object> tokens) {
  final Set<int> lit = <int>{};
  final Set<int> dist = <int>{};
  for (final Object t in tokens) {
    if (t is int) {
      lit.add(t);
    } else if (t is Match) {
      lit.add(lengthSymbol(t.length));
      dist.add(distanceSymbol(t.distance));
    }
  }
  return <List<int>>[lit.toList(), dist.toList()];
}

/// 手写一个动态 Huffman 块（BTYPE=10）。
///
/// [litLengths] 是字面量/长度字母表（0..287）的码长表，[distLengths] 是
/// 距离字母表（0..29）的码长表，[tokens] 是 int 字面量与 [Match] 的混合。
/// 码长序列本身**不做**行程压缩 —— 只用符号 0..15 逐个直写，虽然浪费
/// 几十字节，但省掉一层需要自己也正确的编码逻辑。符号 16/17/18 的行程
/// 压缩留给专门的测试单独构造。
List<int> dynamicHuffmanBlock(
  List<int> litLengths,
  List<int> distLengths,
  List<Object> tokens, {
  bool isFinal = true,
  BitWriterLsb? into,
}) {
  final BitWriterLsb w = into ?? BitWriterLsb();
  w.writeBits(isFinal ? 1 : 0, 1);
  w.writeBits(2, 2); // BTYPE=10

  // HLIT/HDIST 是「个数 - 起点」，最少也要各报 257 / 1 个。
  final int hlit = litLengths.length;
  final int hdist = distLengths.length;
  w.writeBits(hlit - 257, 5);
  w.writeBits(hdist - 1, 5);

  // 码长序列：两张表首尾相接，一起用码长字母表编码。
  final List<int> allLengths = <int>[...litLengths, ...distLengths];
  final Set<int> used = allLengths.toSet();
  final List<int> clLengths = completeLengths(used.toList(), 19);

  // HCLEN 只传到「传输顺序里最后一个非零码长」为止，至少 4 个。
  int hclen = 19;
  while (hclen > 4 && clLengths[codeLengthOrder[hclen - 1]] == 0) {
    hclen--;
  }
  w.writeBits(hclen - 4, 4);
  for (int i = 0; i < hclen; i++) {
    w.writeBits(clLengths[codeLengthOrder[i]], 3);
  }

  final Map<int, List<int>> clCodes = canonicalCodes(clLengths);
  for (final int len in allLengths) {
    final List<int> code = clCodes[len]!;
    w.writeCode(code[0], code[1]);
  }

  writeTokens(w, tokens, canonicalCodes(litLengths), canonicalCodes(distLengths));
  return into == null ? w.toBytes() : const <int>[];
}
