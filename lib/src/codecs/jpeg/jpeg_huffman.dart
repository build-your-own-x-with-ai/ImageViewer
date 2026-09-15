/// JPEG 的 Huffman 码表。
///
/// ## 为什么不复用 `compress/huffman.dart`
///
/// 两者的**思想**完全一样（规范化 Huffman：码长决定码字），但接口三处不同，
/// 硬凑成一个类只会让两边都别扭：
///
/// | | deflate | JPEG |
/// |---|---|---|
/// | 位序 | LSB 优先（[BitReaderLsb]） | MSB 优先（[BitReaderMsb]） |
/// | 最大码长 | 15 | 16 |
/// | 码表传输方式 | 每个符号的码长 | `BITS[1..16]` + `HUFFVAL` |
///
/// 第三条差别最实质。deflate 传的是「符号 → 码长」的数组，JPEG 传的是
/// 「每个码长有几个码字」加「符号按码长顺序排成一列」—— 也就是说，JPEG
/// **直接传了规范化 Huffman 的那两个平坦数组**，连转换都不用做。
///
/// 这是 JPEG 比 deflate 简单的少数几个地方之一（1992 年的规范比 1996 年的
/// 更接近实现细节，好处是解析直白，坏处是灵活性差）。
///
/// ## 完整性校验：和 deflate 恰好相反
///
/// deflate 拒绝过订阅、有条件接受不完整表；JPEG 这边**也**拒绝过订阅，
/// 但对不完整表要宽容得多，因为规范自己就要求留一个空洞：
///
/// > 全 1 的码字（`1111111111111111`）是保留的，不得分配给任何符号。
///
/// 理由是防止熵数据里出现一长串 `0xFF` —— 那会被误认为 marker 前缀。
/// 规范附录 K 里那几张标准表都留着这个空洞，所以「表不完整」在 JPEG 里
/// 是**正常状态**，不能当错误。
///
/// 代价是「读满 16 位没匹配上」必须在解码时报错，而不能像 deflate 那样在
/// 建表时就排除掉这种可能。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/core/bit_reader_msb.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

/// JPEG 里 Huffman 码字的最大位数。
const int kMaxJpegCodeBits = 16;

/// 码表的类别：DC 表还是 AC 表。
///
/// 同一个表号可以同时存在一张 DC 表和一张 AC 表，互不冲突 —— 因为它们
/// 编码的是完全不同的东西（DC 编码「幅值类别」，AC 编码「跳过几个零 +
/// 幅值类别」），所以查表时要用 (类别, 表号) 两个键。
enum HuffmanTableClass {
  /// Tc=0：DC 系数与无损预测用。符号是幅值类别 S（0..15）。
  dc(0, 'DC'),

  /// Tc=1：AC 系数用。符号是 `RRRRSSSS`，高 4 位是零的个数。
  ac(1, 'AC');

  const HuffmanTableClass(this.value, this.label);

  /// DHT 里的数值。
  final int value;

  /// 可读名字。
  final String label;

  static HuffmanTableClass fromValue(int v, {int? offset}) {
    if (v == 0) {
      return HuffmanTableClass.dc;
    }
    if (v == 1) {
      return HuffmanTableClass.ac;
    }
    throw ImageDecodeException(
      'DHT 的类别字段 Tc=$v 非法（只有 0=DC、1=AC 两种）',
      format: 'JPEG',
      offset: offset,
    );
  }
}

/// 一张 JPEG Huffman 码表。
class JpegHuffmanTable {
  JpegHuffmanTable._(
    this.tableClass,
    this.id,
    this._counts,
    this._symbols,
    this.maxCodeBits,
  );

  /// DC 还是 AC。
  final HuffmanTableClass tableClass;

  /// 表号 Th，0..3。
  final int id;

  /// `_counts[n]` = 码长恰为 n 的码字个数，n 从 1 到 16。
  final Uint16List _counts;

  /// 所有符号，按码长升序排列 —— 这正是 `HUFFVAL` 在文件里的原始顺序，
  /// 所以这个数组是**直接从字节流拷过来的**，不需要任何重排。
  final Uint8List _symbols;

  /// 实际用到的最长码长。仅用于信息面板。
  final int maxCodeBits;

  /// 码字总数。
  int get symbolCount => _symbols.length;

  /// 从 `BITS` 与 `HUFFVAL` 构造。
  ///
  /// [counts] 是 16 项，`counts[i]` 为码长 `i+1` 的码字个数。
  /// [symbols] 长度必须等于 counts 之和。
  factory JpegHuffmanTable.build({
    required HuffmanTableClass tableClass,
    required int id,
    required List<int> counts,
    required Uint8List symbols,
    int? offset,
  }) {
    if (counts.length != kMaxJpegCodeBits) {
      throw ImageDecodeException(
        '内部错误：BITS 应有 $kMaxJpegCodeBits 项，实际 ${counts.length} 项',
        format: 'JPEG',
        offset: offset,
      );
    }

    final Uint16List c = Uint16List(kMaxJpegCodeBits + 1);
    int total = 0;
    int maxBits = 0;
    for (int i = 0; i < kMaxJpegCodeBits; i++) {
      c[i + 1] = counts[i];
      total += counts[i];
      if (counts[i] > 0) {
        maxBits = i + 1;
      }
    }

    if (total != symbols.length) {
      throw ImageDecodeException(
        'DHT ${tableClass.label} 表 #$id 的 BITS 之和是 $total，'
        '但 HUFFVAL 有 ${symbols.length} 项，两者必须相等',
        format: 'JPEG',
        offset: offset,
      );
    }
    if (total == 0) {
      throw ImageDecodeException(
        'DHT ${tableClass.label} 表 #$id 是空表，没有任何码字',
        format: 'JPEG',
        offset: offset,
      );
    }

    // 过订阅校验。和 deflate 那边同一套 Kraft 不等式：每加一位码长，
    // 可用码字数翻倍，减掉本层用掉的。负数说明码字挤不下。
    //
    // 不检查「用满」—— 见文件头注释，JPEG 规范要求留出全 1 码字，
    // 标准表本来就是不完整的。
    int left = 1;
    for (int len = 1; len <= kMaxJpegCodeBits; len++) {
      left <<= 1;
      left -= c[len];
      if (left < 0) {
        throw ImageDecodeException(
          'DHT ${tableClass.label} 表 #$id 过订阅：码长 $len 的码字个数'
          '超出可用编码空间（多出 ${-left} 个），文件已损坏',
          format: 'JPEG',
          offset: offset,
        );
      }
    }

    return JpegHuffmanTable._(tableClass, id, c, symbols, maxBits);
  }

  /// 从 [reader] 解出一个符号。
  ///
  /// 结构和 `compress/huffman.dart` 的 `decode` 一样：三个游标
  /// （`code` / `first` / `index`）同步推进，靠「同码长的码字连续递增」
  /// 一次减法定位符号。差别只在这里是 MSB 优先、上限 16 位。
  ///
  /// 位序在这边反而更自然：JPEG 的码字和字节内的位都是高位在前，
  /// 所以 `code = (code << 1) | bit` 直接就是码字的值，不像 deflate
  /// 那样要在脑子里做一次方向翻转。
  int decode(BitReaderMsb reader) {
    int code = 0;
    int first = 0;
    int index = 0;

    for (int len = 1; len <= kMaxJpegCodeBits; len++) {
      code |= reader.readBit();
      final int count = _counts[len];
      if (code - first < count) {
        return _symbols[index + (code - first)];
      }
      index += count;
      first = (first + count) << 1;
      code <<= 1;
    }

    // 16 位全读完还没匹配。因为建表时**不能**要求码表完整（全 1 码字是
    // 保留的），这里是唯一能发现「位模式落进空洞」的地方。
    //
    // 实际触发原因通常不是文件损坏，而是解码器自己错位了 —— 比如漏处理
    // 重启间隔，从错误的位偏移开始解，读到的位模式自然对不上任何码字。
    throw ImageDecodeException(
      '${tableClass.label} 表 #$id 解码失败：连续 $kMaxJpegCodeBits 位'
      '没有匹配任何码字。要么熵数据损坏，要么解码器位置错位'
      '（漏处理重启间隔时就是这个症状）',
      format: 'JPEG',
      offset: reader.bytePosition,
    );
  }

  @override
  String toString() => 'JpegHuffmanTable(${tableClass.label} #$id, '
      '$symbolCount 个码字, 最长 $maxCodeBits 位)';
}

/// 解析一个 `DHT` 段，返回其中的所有码表。
///
/// 和 `DQT` 一样，一个段里可以塞多张表 —— 大多数编码器把四张表
/// （亮度 DC/AC、色度 DC/AC）写在同一个 DHT 里。
List<JpegHuffmanTable> parseDht(Uint8List data, {required int offset}) {
  final ByteReader r = ByteReader(data, format: 'JPEG');
  final List<JpegHuffmanTable> tables = <JpegHuffmanTable>[];

  while (!r.isAtEnd) {
    final int at = offset + r.offset;
    final int tcTh = r.u8('DHT 的 Tc/Th');
    final HuffmanTableClass cls =
        HuffmanTableClass.fromValue(tcTh >> 4, offset: at);
    final int th = tcTh & 0x0F;
    if (th > 3) {
      throw ImageDecodeException(
        'DHT 的表号 Th=$th 越界（每类最多四张表，0..3）',
        format: 'JPEG',
        offset: at,
      );
    }

    // BITS：16 个字节，第 i 个是码长 i+1 的码字个数。
    final List<int> counts = <int>[];
    int total = 0;
    for (int i = 0; i < kMaxJpegCodeBits; i++) {
      final int n = r.u8('${cls.label} 表 #$th 的 BITS[${i + 1}]');
      counts.add(n);
      total += n;
    }

    // HUFFVAL：total 个符号，按码长升序。长度不写在段里，靠 BITS 之和
    // 算出来 —— 这是 JPEG 段解析里最需要小心的一处「隐含长度」。
    final Uint8List symbols =
        r.copyBytes(total, '${cls.label} 表 #$th 的 HUFFVAL');

    tables.add(JpegHuffmanTable.build(
      tableClass: cls,
      id: th,
      counts: counts,
      symbols: symbols,
      offset: at,
    ));
  }

  if (tables.isEmpty) {
    throw ImageDecodeException('DHT 段是空的，没有任何码表',
        format: 'JPEG', offset: offset);
  }
  return tables;
}
