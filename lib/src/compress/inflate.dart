/// deflate 解压（RFC 1951）与 zlib 容器（RFC 1950）—— 全部自写。
///
/// ## 这个文件同时是阶段 2 和阶段 4 的地基
///
/// PNG 的像素数据是 deflate 压缩的，WebP 的 VP8L 与 ALPH 也会用到同一套
/// Huffman 机制。所以它放在 `compress/` 而不是 `codecs/png/` 下 ——
/// 依赖方向是 `codecs → compress → core`，见 `design.md` §2。
///
/// ## deflate 的三种块
///
/// | BTYPE | 名称 | 什么时候用 |
/// |---|---|---|
/// | 00 | stored | 数据压不动（已压缩过的、或随机的），原样存反而更省 |
/// | 01 | 固定 Huffman | 码表写死在规范里，省掉传码表的开销，适合小数据 |
/// | 10 | 动态 Huffman | 按本块数据统计出码表，再连码表一起传 |
///
/// 一个流里可以混用，压缩器逐块自行选择。「码表本身也是 Huffman 编码的」
/// 是动态块最绕的一点，见 [_readDynamicTables]。
///
/// ## 与 design.md 的一处偏离
///
/// `design.md` §5 写的是「LZ77 回溯用 32KB 环形窗口」。实现时没有用环形
/// 缓冲：解压产物本来就要整块留在内存里交给上层（PNG 拿到后还要做反
/// filter），而输出缓冲里**任意历史位置都还在**，往回索引就是了。
///
/// 环形窗口是流式解压器（边解边吐、不保留全量输出）才需要的结构。我们不是
/// 流式的，硬套只会多一次拷贝和一处取模。32KB 这个上限依然生效 —— 它是
/// 规范对距离的约束，[_Output.copyBack] 照样检查。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/compress/adler32.dart';
import 'package:image_viewer/src/compress/deflate_tables.dart';
import 'package:image_viewer/src/compress/huffman.dart';
import 'package:image_viewer/src/core/bit_reader_lsb.dart';
import 'package:image_viewer/src/core/errors.dart';

/// LZ77 反向引用的最大距离，也就是滑动窗口大小。RFC 1951 §3.2.5。
const int kMaxDistance = 32768;

/// 输出大小的兜底上限（256 MB），仅在调用方没给 `sizeLimit` 时生效。
///
/// 这是**防解压炸弹**的安全阀：几百字节的 deflate 流可以膨胀成几个 GB
/// （全零数据的压缩比能到 1000:1 以上）。PNG 走的是精确上限，用不到这里。
const int kDefaultInflateLimit = 256 * 1024 * 1024;

/// 解压结果：产物加上一份「怎么压出来的」统计。
///
/// 统计信息不是解压必需的，但它们是**教学模式的原料**：三种块各用了几个、
/// 反向引用占多大比例，能直接说明这张图为什么是这个大小。信息面板也会显示。
class InflateResult {
  const InflateResult({
    required this.bytes,
    required this.storedBlocks,
    required this.fixedBlocks,
    required this.dynamicBlocks,
    required this.literalCount,
    required this.matchCount,
    required this.bytesConsumed,
  });

  /// 解压出的原始字节。
  final Uint8List bytes;

  /// stored（未压缩）块的个数。
  final int storedBlocks;

  /// 固定 Huffman 块的个数。
  final int fixedBlocks;

  /// 动态 Huffman 块的个数。
  final int dynamicBlocks;

  /// 解码出的字面量个数（直接照抄的字节）。
  final int literalCount;

  /// LZ77 反向引用的个数（「往回复制 N 字节」指令）。
  final int matchCount;

  /// 从输入里消费掉的字节数，含 zlib 头尾。
  ///
  /// 用于判断流后面还有没有多余数据。
  final int bytesConsumed;

  /// 数据块总数。
  int get blockCount => storedBlocks + fixedBlocks + dynamicBlocks;

  /// 块构成的一句话概括，显示在信息面板上。
  String get blockSummary {
    final List<String> parts = <String>[];
    if (storedBlocks > 0) {
      parts.add('stored×$storedBlocks');
    }
    if (fixedBlocks > 0) {
      parts.add('固定×$fixedBlocks');
    }
    if (dynamicBlocks > 0) {
      parts.add('动态×$dynamicBlocks');
    }
    return parts.isEmpty ? '无数据块' : parts.join(' + ');
  }
}

/// 可增长的输出缓冲，兼作 LZ77 的历史窗口。
///
/// 「输出缓冲同时就是窗口」是本实现的关键简化：反向引用要往回读的字节
/// 全都还在这个缓冲里，直接按下标索引即可，不需要另开一份 32KB 环形窗口。
class _Output {
  _Output({required int sizeHint, required this.limit})
      : _buf = Uint8List(_initialCapacity(sizeHint, limit));

  /// 初始容量。有 sizeHint 就照它分配（PNG 能算出精确值，一次到位不用扩容），
  /// 没有就从 32KB 起步慢慢翻倍。
  static int _initialCapacity(int sizeHint, int limit) {
    final int want = sizeHint > 0 ? sizeHint : 32 * 1024;
    return want > limit ? limit : want;
  }

  Uint8List _buf;
  int _len = 0;

  /// 输出字节数上限，超出即抛异常。防解压炸弹。
  final int limit;

  /// 已写入的字节数。
  int get length => _len;

  /// 保证还能再写 [extra] 字节，不够就扩容。
  void _ensure(int extra) {
    final int need = _len + extra;
    if (need > limit) {
      throw ImageDecodeException(
        '解压产物超出上限 $limit 字节（已写 $_len，还要写 $extra）。'
        '要么数据损坏，要么这是一个解压炸弹',
        format: 'deflate',
      );
    }
    if (need <= _buf.length) {
      return;
    }
    int cap = _buf.isEmpty ? 32 * 1024 : _buf.length;
    while (cap < need) {
      cap *= 2;
    }
    if (cap > limit) {
      cap = limit;
    }
    final Uint8List bigger = Uint8List(cap);
    bigger.setRange(0, _len, _buf);
    _buf = bigger;
  }

  /// 写一个字面量字节。
  void writeByte(int b) {
    _ensure(1);
    _buf[_len++] = b;
  }

  /// 写一整段已对齐的字节（stored 块走这条路，比逐字节快得多）。
  void writeBytes(Uint8List src) {
    _ensure(src.length);
    _buf.setRange(_len, _len + src.length, src);
    _len += src.length;
  }

  /// LZ77 反向引用：从 [distance] 字节之前起，复制 [length] 字节到末尾。
  ///
  /// ## 必须逐字节复制，不能用 setRange
  ///
  /// 源区间和目标区间可以**重叠**，而且这种重叠是刻意利用的：
  /// `distance=1, length=100` 表示「把上一个字节重复 100 次」——
  /// 复制过程中写进去的字节又成了后面要读的源。这是游程编码的等价物，
  /// deflate 靠它高效表达纯色区域。
  ///
  /// `setRange` 对重叠区间的行为是先整块读再整块写（语义上等价于先拷副本），
  /// 那样 distance=1 只会重复原来那一个字节一次，而不是铺满 100 字节。
  void copyBack(int distance, int length) {
    if (distance <= 0 || distance > kMaxDistance) {
      throw ImageDecodeException(
        'LZ77 距离 $distance 非法（应在 1..$kMaxDistance）',
        format: 'deflate',
      );
    }
    if (distance > _len) {
      throw ImageDecodeException(
        'LZ77 距离 $distance 超过已解压的 $_len 字节 —— '
        '引用了流开始之前的数据，压缩数据已损坏',
        format: 'deflate',
      );
    }
    _ensure(length);
    int from = _len - distance;
    for (int i = 0; i < length; i++) {
      _buf[_len++] = _buf[from++];
    }
  }

  /// 取出产物。长度刚好时零拷贝，否则截断到实际长度。
  Uint8List toBytes() =>
      _len == _buf.length ? _buf : Uint8List.sublistView(_buf, 0, _len);
}

// ———————————————————————————————————————————————————————————————
// zlib 容器（RFC 1950）
// ———————————————————————————————————————————————————————————————

/// 解开一个 zlib 流：2 字节头 + deflate 数据 + 4 字节 Adler-32。
///
/// PNG 的 `IDAT` 里装的就是这个（不是裸 deflate —— 这是初学者常踩的坑，
/// 直接把 IDAT 喂给 deflate 解码器会因为多出的两字节头而全盘错位）。
///
/// [sizeHint] 是预期产物大小，用于一次性分配到位，猜错只影响性能。
/// [sizeLimit] 是硬上限，超出即抛异常；PNG 传精确值，于是解压炸弹在
/// 膨胀到第 `rawSize + 1` 字节时就被拦下。
InflateResult inflateZlib(
  Uint8List data, {
  int start = 0,
  int sizeHint = 0,
  int? sizeLimit,
  String format = 'zlib',
}) {
  if (data.length - start < 2) {
    throw ImageDecodeException(
      'zlib 流被截断：连 2 字节的头都不够',
      format: format,
      offset: start,
    );
  }

  // ## zlib 头的两个字节
  //
  // ```
  // CMF: 高 4 位 CINFO（窗口大小 = 2^(CINFO+8)），低 4 位 CM（压缩方法）
  // FLG: 高 2 位 FLEVEL（压缩级别，仅供参考），bit5 FDICT，低 5 位 FCHECK
  // ```
  final int cmf = data[start];
  final int flg = data[start + 1];

  final int cm = cmf & 0x0F;
  if (cm != 8) {
    throw ImageDecodeException(
      'zlib 压缩方法 $cm 不是 deflate（应为 8）',
      format: format,
      offset: start,
    );
  }

  final int cinfo = cmf >> 4;
  if (cinfo > 7) {
    throw ImageDecodeException(
      'zlib 窗口大小指数 CINFO=$cinfo 越界（应 ≤ 7，即窗口 ≤ 32KB）',
      format: format,
      offset: start,
    );
  }

  // FCHECK 的作用：让两个头字节合起来是 31 的倍数。
  // 这是个极轻量的头部自校验 —— 单字节损坏几乎必然被它抓到，
  // 代价只有 5 个比特。
  if ((cmf * 256 + flg) % 31 != 0) {
    throw ImageDecodeException(
      'zlib 头校验失败：(CMF=$cmf, FLG=$flg) 合起来不是 31 的倍数，'
      '头部字节已损坏',
      format: format,
      offset: start,
    );
  }

  // FDICT 表示后面跟 4 字节的预置字典 ID。PNG 规范明确禁止，
  // 因为解码器无从得知那个字典的内容。
  if ((flg & 0x20) != 0) {
    throw UnsupportedImageFeature(
      'zlib 流声明了预置字典（FDICT=1），PNG 规范不允许，也无法解码',
      format: format,
      offset: start,
    );
  }

  final InflateResult raw = inflateRaw(
    data,
    start: start + 2,
    sizeHint: sizeHint,
    sizeLimit: sizeLimit,
    format: format,
  );

  // Adler-32 校验解压**产物**，在 deflate 数据之后，大端。
  final int checksumAt = start + 2 + raw.bytesConsumed;
  if (checksumAt + 4 > data.length) {
    throw ImageDecodeException(
      'zlib 流被截断：缺少尾部 4 字节的 Adler-32 校验和',
      format: format,
      offset: checksumAt,
    );
  }
  // 用乘法而不是 `<< 24`：Web 上位运算是 32 位**有符号**的，最高字节
  // ≥ 0x80 时左移 24 位会得到负数，而 adler32() 返回的恒为非负 ——
  // 于是一半的合法文件会在 Web 上校验失败，在桌面上却一切正常。
  // 这类「只在一个平台上错」的 bug 最难查，所以整个项目统一用乘法。
  final int stored = data[checksumAt] * 16777216 +
      data[checksumAt + 1] * 65536 +
      data[checksumAt + 2] * 256 +
      data[checksumAt + 3];
  final int actual = adler32(raw.bytes);
  if (stored != actual) {
    throw ImageDecodeException(
      'Adler-32 校验失败：流里写的是 0x${stored.toRadixString(16)}，'
      '解压产物算出来是 0x${actual.toRadixString(16)}。'
      '压缩数据损坏，或解压实现有 bug',
      format: format,
      offset: checksumAt,
    );
  }

  return InflateResult(
    bytes: raw.bytes,
    storedBlocks: raw.storedBlocks,
    fixedBlocks: raw.fixedBlocks,
    dynamicBlocks: raw.dynamicBlocks,
    literalCount: raw.literalCount,
    matchCount: raw.matchCount,
    // 头 2 + deflate 数据 + 尾 4
    bytesConsumed: 2 + raw.bytesConsumed + 4,
  );
}

// ———————————————————————————————————————————————————————————————
// deflate 本体（RFC 1951）
// ———————————————————————————————————————————————————————————————

/// 一个 Huffman 块解出来的统计。
class _BlockStats {
  const _BlockStats(this.literals, this.matches);

  final int literals;
  final int matches;
}

/// 动态块自带的两张码表。
class _DynamicTables {
  const _DynamicTables(this.literal, this.distance);

  final HuffmanTable literal;
  final HuffmanTable distance;
}

/// 解一个**裸** deflate 流（无 zlib 头尾）。
///
/// 每个块的头是 3 位：`BFINAL`(1) + `BTYPE`(2)。`BFINAL=1` 标志最后一块，
/// 所以流是自描述长度的 —— 不需要外部告知有多少字节。
InflateResult inflateRaw(
  Uint8List data, {
  int start = 0,
  int sizeHint = 0,
  int? sizeLimit,
  String format = 'deflate',
}) {
  final BitReaderLsb bits = BitReaderLsb(data, start: start, format: format);
  final _Output out = _Output(
    sizeHint: sizeHint,
    limit: sizeLimit ?? kDefaultInflateLimit,
  );

  int storedBlocks = 0;
  int fixedBlocks = 0;
  int dynamicBlocks = 0;
  int literals = 0;
  int matches = 0;

  // 固定码表每块都一样，建一次复用 —— 一张图可能有几十个固定块。
  HuffmanTable? fixedLiteral;
  HuffmanTable? fixedDistance;

  bool last = false;
  while (!last) {
    last = bits.readBit() == 1;
    final int type = bits.readBits(2);

    switch (type) {
      case 0:
        storedBlocks++;
        _readStoredBlock(bits, out, format);
      case 1:
        fixedBlocks++;
        fixedLiteral ??= HuffmanTable.fromLengths(
          buildFixedLiteralLengths(),
          format: format,
          what: '固定字面/长度码表',
        );
        fixedDistance ??= HuffmanTable.fromLengths(
          buildFixedDistanceLengths(),
          format: format,
          what: '固定距离码表',
        );
        final _BlockStats s =
            _decodeBlock(bits, out, fixedLiteral, fixedDistance, format);
        literals += s.literals;
        matches += s.matches;
      case 2:
        dynamicBlocks++;
        final _DynamicTables t = _readDynamicTables(bits, format);
        final _BlockStats s =
            _decodeBlock(bits, out, t.literal, t.distance, format);
        literals += s.literals;
        matches += s.matches;
      case 3:
        // BTYPE=11 是规范明确保留的非法值。压缩器不会产出它，
        // 出现说明位流已经错位 —— 往往是把 zlib 头当 deflate 数据喂进来了。
        throw ImageDecodeException(
          'deflate 块类型 3 是规范保留的非法值。'
          '常见原因：把带 zlib 头的数据当裸 deflate 解，或位流已错位',
          format: format,
          offset: bits.bytePosition,
        );
    }
  }

  // 块解完后位置可能停在字节中间，对齐后才是「消费了多少字节」。
  bits.alignToByte();
  final int consumed = bits.bytePosition - bits.bufferedBits ~/ 8 - start;

  return InflateResult(
    bytes: out.toBytes(),
    storedBlocks: storedBlocks,
    fixedBlocks: fixedBlocks,
    dynamicBlocks: dynamicBlocks,
    literalCount: literals,
    matchCount: matches,
    bytesConsumed: consumed,
  );
}

/// BTYPE=00：未压缩块。
///
/// 结构是「对齐到字节边界 + LEN(2) + NLEN(2) + LEN 个原始字节」。
///
/// ## NLEN 为什么是 LEN 的反码
///
/// 唯一目的是**自校验**。stored 块里没有 Huffman 码表可以间接验证位流是否
/// 对齐，如果 LEN 读错了（比如少读一位），后面整段数据都会错位而没人发现。
/// 加一个反码副本，一次比较就能确认「这两字节确实是我们以为的那两字节」。
void _readStoredBlock(BitReaderLsb bits, _Output out, String format) {
  // 块头那 3 位之后要丢掉零散位 —— stored 块的数据是按字节存的。
  bits.alignToByte();

  // 对齐后 readBits(16) 低位在前，正好是小端 u16。
  final int len = bits.readBits(16);
  final int nlen = bits.readBits(16);

  if (nlen != (~len & 0xFFFF)) {
    throw ImageDecodeException(
      'stored 块的 LEN/NLEN 不互为反码：LEN=$len，NLEN=$nlen '
      '（应为 ${~len & 0xFFFF}）。位流已错位或数据损坏',
      format: format,
      offset: bits.bytePosition,
    );
  }

  out.writeBytes(bits.readAlignedBytes(len));
}

/// BTYPE=10：读出动态块自带的两张码表。
///
/// ## deflate 里最绕的一段：码表本身也是 Huffman 编码的
///
/// 三层套娃，从外往里读：
///
/// ```
/// 1. HLIT/HDIST/HCLEN          ← 三个定长字段，说明后面有多少项
/// 2. 19 个「码长的码长」         ← 每项 3 位定长，按 kCodeLengthOrder 乱序存
/// 3. 用第 2 步的表，解出第 1 步声明的那些真正的码长
/// ```
///
/// 为什么值得这么绕：一张图的字面量分布很偏（PNG 反 filter 后大量字节是 0
/// 附近的小值），专门统计出来的码表比固定码表短得多。而码表本身也是一串
/// 重复很多的小整数（大片符号码长相同），所以再压一层还能省。
_DynamicTables _readDynamicTables(BitReaderLsb bits, String format) {
  // 三个偏移量字段。加的常数是规范定的下界：字面量至少 257 个（256 个字节
  // 值 + 结束符），距离码至少 1 个，码长码至少 4 个。
  final int hlit = bits.readBits(5) + 257;
  final int hdist = bits.readBits(5) + 1;
  final int hclen = bits.readBits(4) + 4;

  if (hlit > 288) {
    throw ImageDecodeException(
      '动态块声明了 $hlit 个字面/长度码，超出字母表上限 288',
      format: format,
      offset: bits.bytePosition,
    );
  }
  if (hdist > 32) {
    throw ImageDecodeException(
      '动态块声明了 $hdist 个距离码，超出字母表上限 32',
      format: format,
      offset: bits.bytePosition,
    );
  }

  // 第二层：19 个码长码各自的码长，每个 3 位。
  // 只读 hclen 个，其余留 0 —— 按 kCodeLengthOrder 排序的意义就在这里，
  // 高频的排在前面，末尾用不到的整段省掉。
  final List<int> clLengths = List<int>.filled(kCodeLengthOrder.length, 0);
  for (int i = 0; i < hclen; i++) {
    clLengths[kCodeLengthOrder[i]] = bits.readBits(3);
  }
  final HuffmanTable clTable = HuffmanTable.fromLengths(
    clLengths,
    format: format,
    what: '码长码表',
  );

  // 第三层：用 clTable 解出 hlit + hdist 个真正的码长。
  // 两张表的码长**连在一起编码**，中间没有分隔 —— 所以要先合读再切开。
  final int total = hlit + hdist;
  final List<int> lengths = List<int>.filled(total, 0);
  int i = 0;
  while (i < total) {
    final int sym = clTable.decode(bits);

    if (sym < 16) {
      // 0..15：字面码长值。
      lengths[i++] = sym;
      continue;
    }

    // 16/17/18 是重复指令 —— 码长表里大片连续相同值靠它压缩。
    final int repeat;
    final int value;
    switch (sym) {
      case 16:
        // 重复**上一个**码长 3..6 次。所以它不能出现在最开头。
        if (i == 0) {
          throw ImageDecodeException(
            '码长表以「重复上一个码长」(符号 16) 开头，但前面没有码长可重复',
            format: format,
            offset: bits.bytePosition,
          );
        }
        value = lengths[i - 1];
        repeat = bits.readBits(2) + 3;
      case 17:
        // 重复码长 0（即「这些符号不参与编码」）3..10 次。
        value = 0;
        repeat = bits.readBits(3) + 3;
      default:
        // 18：重复码长 0 共 11..138 次。大字母表里绝大多数符号用不上，
        // 这个指令一条就能跳过一百多个。
        value = 0;
        repeat = bits.readBits(7) + 11;
    }

    if (i + repeat > total) {
      throw ImageDecodeException(
        '码长表重复指令越界：在第 $i 项要写 $repeat 项，'
        '但总共只声明了 $total 项',
        format: format,
        offset: bits.bytePosition,
      );
    }
    for (int r = 0; r < repeat; r++) {
      lengths[i++] = value;
    }
  }

  return _DynamicTables(
    HuffmanTable.fromLengths(
      lengths.sublist(0, hlit),
      format: format,
      what: '动态字面/长度码表',
    ),
    HuffmanTable.fromLengths(
      lengths.sublist(hlit),
      format: format,
      what: '动态距离码表',
    ),
  );
}

/// 用给定的两张码表解一个 Huffman 块，直到读到结束符 256。
///
/// ## 一个字母表装了两种东西
///
/// 字面/长度表里的符号有三种含义，这是 LZ77 与 Huffman 结合的关键：
///
/// ```
/// 0..255   字面量：直接输出这个字节
/// 256      块结束
/// 257..285 长度码：接下来是一条「往回复制」指令
/// ```
///
/// 把「字节」和「复制指令」放进同一个字母表，Huffman 就能同时统计两者的
/// 频率 —— 一张纯色图里复制指令远多于字面量，码表会自动给它们更短的码字。
/// 这个合并是 deflate 效率的来源，也是它比「先 LZ77 再 Huffman」的朴素
/// 串联更好的原因。
_BlockStats _decodeBlock(
  BitReaderLsb bits,
  _Output out,
  HuffmanTable literalTable,
  HuffmanTable distanceTable,
  String format,
) {
  int literals = 0;
  int matches = 0;

  while (true) {
    final int sym = literalTable.decode(bits);

    if (sym < 256) {
      out.writeByte(sym);
      literals++;
      continue;
    }
    if (sym == 256) {
      return _BlockStats(literals, matches);
    }

    // —— 长度 ——
    final int lengthIndex = sym - 257;
    if (lengthIndex >= kLengthBase.length) {
      // 286/287 有码长（为了让固定码表完整）但没有定义长度，属非法。
      throw ImageDecodeException(
        '长度码 $sym 未定义（合法范围 257..285）',
        format: format,
        offset: bits.bytePosition,
      );
    }
    final int length =
        kLengthBase[lengthIndex] + bits.readBits(kLengthExtraBits[lengthIndex]);

    // —— 距离 ——
    final int distSym = distanceTable.decode(bits);
    if (distSym >= kDistanceBase.length) {
      // 同理，30/31 在固定表里有码长但无定义。
      throw ImageDecodeException(
        '距离码 $distSym 未定义（合法范围 0..29）',
        format: format,
        offset: bits.bytePosition,
      );
    }
    final int distance =
        kDistanceBase[distSym] + bits.readBits(kDistanceExtraBits[distSym]);

    out.copyBack(distance, length);
    matches++;
  }
}
