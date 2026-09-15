/// 量化表与 zigzag 反序。
///
/// ## 量化是 JPEG 唯一丢信息的一步
///
/// DCT 本身是可逆的（浮点误差之外），色度子采样丢的是空间分辨率。真正
/// 把「有损」写进 JPEG 的是量化：编码器把每个 DCT 系数除以一个整数并四舍
/// 五入，解码器再乘回去。除掉的余数永远回不来了。
///
/// 量化表就是那 64 个除数。高频位置放大数（人眼对高频不敏感，多丢一些），
/// 低频放小数。质量参数 100 对应一张几乎全是 1 的表，质量 10 对应一张
/// 高频全是 255 的表 —— 所谓「调质量」调的就是这张表的缩放。
///
/// 所以解码器这一步只有一次乘法。所有的聪明都在编码器那边。
///
/// ## zigzag：为什么 64 个系数不按行列顺序存
///
/// 量化之后高频系数大量变成 0。zigzag 顺序沿对角线走，把低频排在前面、
/// 高频排在后面，于是**尾部会出现一长串连续的 0**，正好能被 EOB（块结束）
/// 一个符号带过去。按行列顺序存的话零散分布在每行末尾，压不掉。
///
/// 这是一个纯粹为了熵编码效率而存在的重排，没有任何数学意义。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 一个 8×8 块的系数个数。
const int kBlockSize = 64;

/// 块的边长。
const int kBlockDim = 8;

/// zigzag 序号 → 自然序（行优先）下标。
///
/// 读法：`kZigzagOrder[i]` 是 zigzag 里第 i 个系数在 8×8 矩阵中的位置。
/// 例如第 1 个（i=0）是 0（左上角 DC），第 2 个是 1（右移一格），
/// 第 3 个是 8（左下一格），走出一条对角线折返的路径。
const List<int> kZigzagOrder = <int>[
  0, 1, 8, 16, 9, 2, 3, 10, //
  17, 24, 32, 25, 18, 11, 4, 5, //
  12, 19, 26, 33, 40, 48, 41, 34, //
  27, 20, 13, 6, 7, 14, 21, 28, //
  35, 42, 49, 56, 57, 50, 43, 36, //
  29, 22, 15, 23, 30, 37, 44, 51, //
  58, 59, 52, 45, 38, 31, 39, 46, //
  53, 60, 61, 54, 47, 55, 62, 63, //
];

/// 一张量化表（DQT 段里的一项）。
///
/// 内部**按 zigzag 顺序**存放，和熵解码器吐出来的系数顺序一致，于是
/// 反量化就是逐下标相乘，不需要在乘法的同时做重排。重排留给
/// [dequantizeBlock] 一次做完。
class QuantizationTable {
  QuantizationTable({
    required this.id,
    required this.precision,
    required Int32List zigzagValues,
  }) : _values = zigzagValues;

  /// 表号 Tq，0..3。SOF 里每个分量指定自己用哪张。
  final int id;

  /// 精度：8 位表每项一字节，16 位表每项两字节。
  ///
  /// 16 位表只在扩展顺序/渐进式里合法，基线必须是 8 位 —— 不过实践中
  /// 见到的几乎全是 8 位。
  final int precision;

  final Int32List _values;

  /// 按 zigzag 顺序的 64 个除数。
  Int32List get zigzagValues => _values;

  /// 按自然序（行优先）的 64 个除数，供信息面板与教学热图使用。
  ///
  /// 只有展示才需要这个顺序 —— 解码路径上一律用 zigzag 序。
  Int32List get naturalValues {
    final Int32List out = Int32List(kBlockSize);
    for (int i = 0; i < kBlockSize; i++) {
      out[kZigzagOrder[i]] = _values[i];
    }
    return out;
  }

  /// DC 位置（zigzag 第 0 项）的除数。质量高低最直观的一个指标。
  int get dcQuant => _values[0];

  /// 64 项的平均值。用来在信息面板上粗略反映质量。
  double get averageQuant {
    int sum = 0;
    for (int i = 0; i < kBlockSize; i++) {
      sum += _values[i];
    }
    return sum / kBlockSize;
  }

  @override
  String toString() =>
      'QuantizationTable(#$id, $precision 位, DC=$dcQuant, '
      '均值 ${averageQuant.toStringAsFixed(1)})';
}

/// 解析一个 `DQT` 段，返回其中的所有表。
///
/// ## 一个段里可以有多张表
///
/// 段的结构是 `[Pq|Tq][64 项] [Pq|Tq][64 项] ...`，一直填到段长用完。
/// 循环终止条件是「字节读完」而不是固定次数 —— 写死读一张表的解码器
/// 会打不开一批把亮度和色度表放在同一个 DQT 里的文件（很常见）。
///
/// 高 4 位是精度 Pq，低 4 位是表号 Tq。这种「一字节塞两个字段」的写法在
/// JPEG 里到处都是（DHT 的 Tc/Th、SOS 的 Td/Ta、渐进的 Ah/Al 都是），
/// 是 1992 年为省字节做的选择。
List<QuantizationTable> parseDqt(Uint8List data, {required int offset}) {
  final ByteReader r = ByteReader(data, format: 'JPEG');
  final List<QuantizationTable> tables = <QuantizationTable>[];

  while (!r.isAtEnd) {
    final int at = offset + r.offset;
    final int pqTq = r.u8('DQT 的 Pq/Tq');
    final int pq = pqTq >> 4;
    final int tq = pqTq & 0x0F;

    if (pq > 1) {
      throw ImageDecodeException(
        'DQT 的精度字段 Pq=$pq 非法（只有 0=8 位、1=16 位两种）',
        format: 'JPEG',
        offset: at,
      );
    }
    if (tq > 3) {
      throw ImageDecodeException(
        'DQT 的表号 Tq=$tq 越界（最多四张表，0..3）',
        format: 'JPEG',
        offset: at,
      );
    }

    final Int32List values = Int32List(kBlockSize);
    for (int i = 0; i < kBlockSize; i++) {
      final int v = pq == 0
          ? r.u8('量化表 #$tq 的第 $i 项')
          : r.u16be('量化表 #$tq 的第 $i 项');
      // 0 是致命的：反量化要乘它，整个块会变成纯 0（一片纯灰）。这不是
      // 「画质差」而是数据损坏，必须报错。
      if (v == 0) {
        throw ImageDecodeException(
          '量化表 #$tq 的第 $i 项是 0，反量化会把整块系数抹成 0',
          format: 'JPEG',
          offset: at,
        );
      }
      values[i] = v;
    }

    tables.add(QuantizationTable(
      id: tq,
      precision: pq == 0 ? 8 : 16,
      zigzagValues: values,
    ));
  }

  if (tables.isEmpty) {
    throw ImageDecodeException('DQT 段是空的，没有任何量化表',
        format: 'JPEG', offset: offset);
  }
  return tables;
}

/// 反量化一个块，同时做 zigzag 反序。
///
/// [zigzagCoefficients] 是熵解码器吐出的系数（zigzag 序），从
/// [sourceOffset] 起连续 64 项；[out] 收结果（**自然序**，可直接喂给 IDCT）。
///
/// 两件事合成一步做，是因为它们都是纯粹的下标搬运：分开做要多写一遍
/// 64 次循环和一个中间缓冲，而合起来只是把写入下标从 `i` 换成
/// `kZigzagOrder[i]`。
///
/// 源收成 `List<int>` 而不是具体的 typed list：整帧的系数缓冲区是
/// [Int16List]（省一半内存），而测试和其它调用方手里常是 [Int32List]。
/// 这里只做读取，收宽一点省掉一次全帧拷贝。
void dequantizeBlock(
  List<int> zigzagCoefficients,
  QuantizationTable table,
  Int32List out, {
  int sourceOffset = 0,
}) {
  final Int32List q = table.zigzagValues;
  for (int i = 0; i < kBlockSize; i++) {
    out[kZigzagOrder[i]] = zigzagCoefficients[sourceOffset + i] * q[i];
  }
}
