/// SOS 段与熵解码：把位流变回系数。
///
/// ## 扫描数据没有长度
///
/// 前面每个段都有长度字段，SOS 是唯一的例外：段头声明了参数，之后的熵编码
/// 数据一直流到**撞上下一个 marker** 为止。所以这里不能「按长度读一块再处理」，
/// 只能一位一位读，边读边看有没有撞上 marker。
///
/// ## 重启间隔：唯一能从错误里恢复的地方
///
/// DC 系数是差分编码的 —— 每个块只存和前一个块的差。一位读错，后面**所有**
/// DC 都跟着错，整条带子的亮度全歪。DRI 段声明的重启间隔就是为这个存在的：
/// 每 Ri 个 MCU 插一个 RSTn marker，解码器在那里把 DC 预测值清零、回到字节
/// 边界，于是错误最多污染一个间隔。
///
/// 代价是压缩率（marker 本身占空间，DC 预测也断了）。所以很多编码器默认不开。
///
/// ## 渐进模式：同一个系数要被写好几遍
///
/// 基线模式一个块解一次就定了。渐进模式把系数拆成多趟扫描传：
///
/// * **谱选择**：这趟只管 Ss..Se 这几个频率位置
/// * **逐次逼近**：Ah/Al 是位平面。Al 是这趟要写的最低位，Ah 是上一趟已经
///   写到哪了。`Ah == 0` 是首趟（写值），`Ah != 0` 是细化趟（补一位）
///
/// 四种组合各有一套读法，代码里就是 [_decodeDcFirst] / [_decodeDcRefine] /
/// [_decodeAcFirst] / [_decodeAcRefine]。首趟像基线，细化趟完全不同 ——
/// 细化趟读的是**裸位**，不过霍夫曼表，只有 AC 细化的「跳过几个零」要查表。
///
/// ## EOB run：渐进独有的跨块游程
///
/// AC 扫描里 `EOBn` 符号说的是「接下来 n 个块在这一频段全是零」—— 一个符号
/// 跨过多个块。基线的 EOB 只结束当前块，两者不是一回事。忘了跨块这层，
/// 渐进图会解出规律性的方格噪声。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/jpeg/jpeg_frame.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_huffman.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_idct.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_markers.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';
import 'package:image_viewer/src/core/bit_reader_msb.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 扫描里的一个分量：指向帧里的分量，外加这趟用哪两张霍夫曼表。
class JpegScanComponent {
  const JpegScanComponent({
    required this.component,
    required this.dcTableId,
    required this.acTableId,
  });

  /// 帧里的分量。SOS 按标识符点名，这里已经解析成对象了。
  final JpegComponent component;

  /// DC 霍夫曼表编号 Td。
  final int dcTableId;

  /// AC 霍夫曼表编号 Ta。
  final int acTableId;
}

/// 一趟扫描的参数，[parseSos] 的产物。
class JpegScanHeader {
  const JpegScanHeader({
    required this.components,
    required this.spectralStart,
    required this.spectralEnd,
    required this.approxHigh,
    required this.approxLow,
  });

  /// 这趟扫描涉及的分量，顺序就是 MCU 里的块顺序。
  final List<JpegScanComponent> components;

  /// 谱选择起点 Ss（zigzag 下标）。基线恒为 0。
  final int spectralStart;

  /// 谱选择终点 Se。基线恒为 63。
  final int spectralEnd;

  /// 逐次逼近的上一趟位置 Ah。0 表示这是首趟。
  final int approxHigh;

  /// 逐次逼近的本趟最低位 Al。
  final int approxLow;

  /// 是否交错扫描。
  ///
  /// 单分量扫描按该分量自己的块网格走（**不**补齐到 MCU），多分量扫描按
  /// MCU 网格走。渐进的 AC 扫描规范强制单分量，所以 AC 永远走前一条路。
  bool get isInterleaved => components.length > 1;

  /// 是否 DC 扫描（渐进模式下 DC 和 AC 分开传）。
  bool get isDcScan => spectralStart == 0;

  /// 是否细化趟（补一个位平面），而不是首趟（写值）。
  bool get isRefinement => approxHigh != 0;

  @override
  String toString() => 'JpegScanHeader(${components.length} 分量, '
      'Ss..Se=$spectralStart..$spectralEnd, Ah/Al=$approxHigh/$approxLow)';
}

/// 解析 SOS 段的载荷。
///
/// [data] 是段载荷（不含 marker 和长度），[frame] 提供分量表，
/// [offset] 只用于报错定位。
JpegScanHeader parseSos(
  Uint8List data, {
  required JpegFrame frame,
  required int offset,
}) {
  if (data.isEmpty) {
    throw ImageDecodeException('SOS 段是空的', format: 'JPEG', offset: offset);
  }
  final int count = data[0];
  if (count < 1 || count > kMaxJpegComponents) {
    throw ImageDecodeException(
      'SOS 分量个数 $count 越界（1..$kMaxJpegComponents）',
      format: 'JPEG',
      offset: offset,
    );
  }
  final int expected = 1 + 2 * count + 3;
  if (data.length != expected) {
    throw ImageDecodeException(
      'SOS 段长 ${data.length} 与 $count 个分量不符（应为 $expected）',
      format: 'JPEG',
      offset: offset,
    );
  }

  final List<JpegScanComponent> components = <JpegScanComponent>[];
  for (int i = 0; i < count; i++) {
    final int id = data[1 + 2 * i];
    final int tables = data[2 + 2 * i];
    final JpegComponent? component = frame.componentById(id);
    if (component == null) {
      throw ImageDecodeException(
        'SOS 点名的分量 $id 不在帧里',
        format: 'JPEG',
        offset: offset,
      );
    }
    if (components.any((JpegScanComponent c) => c.component.id == id)) {
      throw ImageDecodeException(
        'SOS 里分量 $id 出现两次',
        format: 'JPEG',
        offset: offset,
      );
    }
    final int dc = (tables >> 4) & 0x0F;
    final int ac = tables & 0x0F;
    if (dc > 3 || ac > 3) {
      throw ImageDecodeException(
        '分量 $id 的霍夫曼表编号 Td=$dc Ta=$ac 越界（0..3）',
        format: 'JPEG',
        offset: offset,
      );
    }
    components.add(JpegScanComponent(
      component: component,
      dcTableId: dc,
      acTableId: ac,
    ));
  }

  final int ss = data[1 + 2 * count];
  final int se = data[2 + 2 * count];
  final int approx = data[3 + 2 * count];
  final int ah = (approx >> 4) & 0x0F;
  final int al = approx & 0x0F;

  if (ss > 63 || se > 63 || ss > se) {
    throw ImageDecodeException(
      '谱选择 Ss=$ss Se=$se 非法（需 0 ≤ Ss ≤ Se ≤ 63）',
      format: 'JPEG',
      offset: offset,
    );
  }
  if (al > 13 || ah > 13) {
    throw ImageDecodeException(
      '逐次逼近 Ah=$ah Al=$al 越界',
      format: 'JPEG',
      offset: offset,
    );
  }

  if (frame.isProgressive) {
    // DC 和 AC 不能混在一趟里：ss==0 时 se 必须也是 0。
    if (ss == 0 && se != 0) {
      throw ImageDecodeException(
        '渐进扫描里 DC（Ss=0）不能和 AC 合并，Se 应为 0 而不是 $se',
        format: 'JPEG',
        offset: offset,
      );
    }
    // AC 扫描只能单分量 —— 交错的 AC 没法表达跨块的 EOB run。
    if (ss != 0 && count != 1) {
      throw ImageDecodeException(
        '渐进 AC 扫描只能有 1 个分量，声明了 $count 个',
        format: 'JPEG',
        offset: offset,
      );
    }
    if (ah != 0 && ah != al + 1) {
      // 细化趟必须紧接着上一趟的位平面，跳位会让系数少掉中间几位。
      throw ImageDecodeException(
        '细化趟的 Ah=$ah 应当等于 Al+1=${al + 1}',
        format: 'JPEG',
        offset: offset,
      );
    }
  } else {
    // 基线/扩展顺序模式：整块一趟传完，这三个字段没有自由度。
    if (ss != 0 || se != 63) {
      throw ImageDecodeException(
        '顺序模式的谱选择必须是 0..63，读到 $ss..$se',
        format: 'JPEG',
        offset: offset,
      );
    }
    if (ah != 0 || al != 0) {
      throw ImageDecodeException(
        '顺序模式不能用逐次逼近，读到 Ah=$ah Al=$al',
        format: 'JPEG',
        offset: offset,
      );
    }
  }

  return JpegScanHeader(
    components: List<JpegScanComponent>.unmodifiable(components),
    spectralStart: ss,
    spectralEnd: se,
    approxHigh: ah,
    approxLow: al,
  );
}

/// 解一趟扫描的熵数据，结果直接写进各分量的系数缓冲区。
///
/// [bytes] 是整个文件，[start] 是熵数据的起始偏移（SOS 段之后），
/// [restartInterval] 来自 DRI 段（0 表示不重启）。
/// [dcTables] / [acTables] 按表号索引，可以有空位。
///
/// 返回熵数据结束的字节偏移，调用方从那里继续扫 marker。
int decodeScan(
  Uint8List bytes, {
  required int start,
  required JpegFrame frame,
  required JpegScanHeader scan,
  required List<JpegHuffmanTable?> dcTables,
  required List<JpegHuffmanTable?> acTables,
  int restartInterval = 0,
}) {
  final _ScanDecoder decoder = _ScanDecoder(
    reader: BitReaderMsb(bytes, start: start),
    frame: frame,
    scan: scan,
    dcTables: dcTables,
    acTables: acTables,
    restartInterval: restartInterval,
  );
  decoder.run();
  return decoder.reader.bytePosition;
}

/// 熵解码的可变状态：位读取器、每个分量的 DC 预测值、跨块的 EOB 游程。
class _ScanDecoder {
  _ScanDecoder({
    required this.reader,
    required this.frame,
    required this.scan,
    required this.dcTables,
    required this.acTables,
    required this.restartInterval,
  }) : predictions = Int32List(scan.components.length);

  final BitReaderMsb reader;
  final JpegFrame frame;
  final JpegScanHeader scan;
  final List<JpegHuffmanTable?> dcTables;
  final List<JpegHuffmanTable?> acTables;
  final int restartInterval;

  /// 每个分量的 DC 预测值。差分编码的累加器，重启时清零。
  ///
  /// 用 [Int32List] 而不是普通 `List<int>`：溢出行为在 VM 和 Web 上一致
  /// （都截到 32 位）。畸形文件能把预测值累到很大，两个平台得给出同一份垃圾。
  final Int32List predictions;

  /// 渐进 AC 扫描里跨块的「接下来 n 个块本频段全零」计数。
  ///
  /// 这个计数**跨块存活**，是它和基线 EOB 的根本区别；重启时要清零，
  /// 否则一个间隔的游程会漏进下一个间隔。
  int eobRun = 0;

  /// 距下一个 RSTn 还有几个 MCU。
  int _restartCountdown = 0;

  JpegHuffmanTable _dcTable(int id) {
    final JpegHuffmanTable? t = dcTables[id];
    if (t == null) {
      // 扫描点名了一张没定义过的表。硬解会把位流读成噪声，不如说清楚。
      throw ImageDecodeException(
        '扫描引用了未定义的 DC 霍夫曼表 $id',
        format: 'JPEG',
        offset: reader.bytePosition,
      );
    }
    return t;
  }

  JpegHuffmanTable _acTable(int id) {
    final JpegHuffmanTable? t = acTables[id];
    if (t == null) {
      throw ImageDecodeException(
        '扫描引用了未定义的 AC 霍夫曼表 $id',
        format: 'JPEG',
        offset: reader.bytePosition,
      );
    }
    return t;
  }

  /// 数据是否真的没了 —— 撞上非 RSTn 的 marker，或读到文件尾。
  ///
  /// RSTn 不算「没了」：那是间隔边界，跳过去还有数据。
  bool get _outOfData {
    if (reader.hitEnd) {
      return true;
    }
    final int? m = reader.pendingMarker;
    return m != null && !isRestart(m);
  }

  void run() {
    _restartCountdown = restartInterval;
    if (scan.isInterleaved) {
      _runInterleaved();
    } else {
      _runSingle();
    }
  }

  /// 多分量扫描：按 MCU 网格走，一个 MCU 里按采样因子铺开各分量的块。
  void _runInterleaved() {
    for (int mcu = 0; mcu < frame.mcusPerLine * frame.mcusPerColumn; mcu++) {
      if (!_maybeRestart()) {
        return;
      }
      final int mcuRow = mcu ~/ frame.mcusPerLine;
      final int mcuCol = mcu % frame.mcusPerLine;
      for (int ci = 0; ci < scan.components.length; ci++) {
        final JpegComponent c = scan.components[ci].component;
        for (int v = 0; v < c.verticalFactor; v++) {
          for (int h = 0; h < c.horizontalFactor; h++) {
            // 这里用的是补齐后的块网格：边缘 MCU 的 dummy block 也要读，
            // 它们在位流里真实存在，跳过就会错位。
            _decodeBlock(
              ci,
              c.blockOffset(mcuRow * c.verticalFactor + v,
                  mcuCol * c.horizontalFactor + h),
            );
          }
        }
      }
      if (_outOfData) {
        return;
      }
    }
  }

  /// 单分量扫描：按该分量**真实**的块网格走，不碰补齐出来的 dummy block。
  ///
  /// 这是两套块数唯一分开用的地方。走错网格不会报错，只会让图像整体斜切 ——
  /// 因为每行多读或少读了几个块。
  void _runSingle() {
    final JpegComponent c = scan.components[0].component;
    for (int row = 0; row < c.blocksPerColumn; row++) {
      for (int col = 0; col < c.blocksPerLine; col++) {
        if (!_maybeRestart()) {
          return;
        }
        _decodeBlock(0, c.blockOffset(row, col));
        if (_outOfData) {
          return;
        }
      }
    }
  }

  /// 到间隔边界就跳过 RSTn 并重置状态。返回 false 表示该收工了。
  bool _maybeRestart() {
    if (restartInterval == 0) {
      return true;
    }
    if (_restartCountdown > 0) {
      _restartCountdown--;
      return true;
    }
    // 找不到 marker 也照样重置：那说明间隔算错或数据损坏，重置至少能让
    // 后面的块不继承错误的预测值。
    final bool found = reader.skipRestartMarker();
    predictions.fillRange(0, predictions.length, 0);
    eobRun = 0;
    _restartCountdown = restartInterval - 1;
    if (!found && _outOfData) {
      return false;
    }
    return true;
  }

  void _decodeBlock(int scanIndex, int blockOffset) {
    if (!frame.isProgressive) {
      _decodeBaseline(scanIndex, blockOffset);
      return;
    }
    if (scan.isDcScan) {
      if (scan.isRefinement) {
        _decodeDcRefine(scanIndex, blockOffset);
      } else {
        _decodeDcFirst(scanIndex, blockOffset);
      }
    } else {
      if (scan.isRefinement) {
        _decodeAcRefine(scanIndex, blockOffset);
      } else {
        _decodeAcFirst(scanIndex, blockOffset);
      }
    }
  }

  /// 基线：一个块一趟解完，DC 差分 + AC 游程。
  void _decodeBaseline(int scanIndex, int blockOffset) {
    final JpegScanComponent sc = scan.components[scanIndex];
    final Int16List coefficients = sc.component.coefficients;

    // DC：符号是「幅值类别」，随后跟着那么多位幅值，得到的是**差分**。
    final int t = _dcTable(sc.dcTableId).decode(reader);
    if (t > 15) {
      throw ImageDecodeException(
        'DC 幅值类别 $t 越界（0..15）',
        format: 'JPEG',
        offset: reader.bytePosition,
      );
    }
    final int diff = t == 0 ? 0 : reader.receiveExtend(t);
    predictions[scanIndex] += diff;
    coefficients[blockOffset] = predictions[scanIndex];

    // AC：符号高 4 位是「前面有几个零」，低 4 位是幅值类别。
    final JpegHuffmanTable ac = _acTable(sc.acTableId);
    int k = 1;
    while (k < kBlockSize) {
      final int rs = ac.decode(reader);
      final int run = (rs >> 4) & 0x0F;
      final int size = rs & 0x0F;
      if (size == 0) {
        if (run != 15) {
          break; // EOB：本块剩下的全是零
        }
        k += 16; // ZRL：跳过 16 个零，注意这一步可能跨过 63
        continue;
      }
      k += run;
      if (k >= kBlockSize) {
        // 游程把下标顶出了块外。通常不是文件坏了，而是解码器**失步**了 ——
        // 最常见的原因是漏掉了一个重启间隔。
        if (_outOfData) {
          return;
        }
        throw ImageDecodeException(
          'AC 游程越过块尾（k=$k），位流已失步',
          format: 'JPEG',
          offset: reader.bytePosition,
        );
      }
      coefficients[blockOffset + k] = reader.receiveExtend(size);
      k++;
    }
  }

  /// 渐进 DC 首趟：和基线的 DC 一样，只是结果落在 Al 这个位平面上。
  void _decodeDcFirst(int scanIndex, int blockOffset) {
    final JpegScanComponent sc = scan.components[scanIndex];
    final int t = _dcTable(sc.dcTableId).decode(reader);
    if (t > 15) {
      throw ImageDecodeException(
        'DC 幅值类别 $t 越界（0..15）',
        format: 'JPEG',
        offset: reader.bytePosition,
      );
    }
    final int diff = t == 0 ? 0 : reader.receiveExtend(t);
    predictions[scanIndex] += diff;
    // 用乘法而不是 `<< approxLow`：Web 上位运算是 32 位有符号语义，畸形文件
    // 把预测值累大之后左移会静默翻符号。乘法在两个平台上都只是截断。
    sc.component.coefficients[blockOffset] =
        predictions[scanIndex] * (1 << scan.approxLow);
  }

  /// 渐进 DC 细化趟：读一个**裸位**补进去，不过霍夫曼表。
  void _decodeDcRefine(int scanIndex, int blockOffset) {
    if (reader.readBit() != 0) {
      final Int16List coefficients =
          scan.components[scanIndex].component.coefficients;
      coefficients[blockOffset] =
          coefficients[blockOffset] | (1 << scan.approxLow);
    }
  }

  /// 渐进 AC 首趟：像基线的 AC，但多了跨块的 EOB 游程。
  void _decodeAcFirst(int scanIndex, int blockOffset) {
    if (eobRun > 0) {
      // 这个块在本频段全是零，一位都不用读。
      eobRun--;
      return;
    }
    final JpegScanComponent sc = scan.components[scanIndex];
    final Int16List coefficients = sc.component.coefficients;
    final JpegHuffmanTable ac = _acTable(sc.acTableId);
    final int scale = 1 << scan.approxLow;

    int k = scan.spectralStart;
    while (k <= scan.spectralEnd) {
      final int rs = ac.decode(reader);
      final int run = (rs >> 4) & 0x0F;
      final int size = rs & 0x0F;
      if (size == 0) {
        if (run != 15) {
          // EOBn：接下来 2^run - 1 + 附加位 个块本频段全零，当前块算第一个。
          eobRun = (1 << run) - 1;
          if (run > 0) {
            eobRun += reader.readBits(run);
          }
          break;
        }
        k += 16; // ZRL
        continue;
      }
      k += run;
      if (k > scan.spectralEnd) {
        if (_outOfData) {
          return;
        }
        throw ImageDecodeException(
          'AC 游程越过谱选择终点（k=$k > Se=${scan.spectralEnd}），位流已失步',
          format: 'JPEG',
          offset: reader.bytePosition,
        );
      }
      coefficients[blockOffset + k] = reader.receiveExtend(size) * scale;
      k++;
    }
  }

  /// 渐进 AC 细化趟：四种读法里最绕的一种。
  ///
  /// 同一条位流里混着两种位：**已经非零**的系数各要一个校正位，而游程数出来
  /// 的位置上可能有新系数刚变成非零。所以扫描过程中每碰到一个非零系数都要先
  /// 消费掉它的校正位，游程只数**零**系数。
  void _decodeAcRefine(int scanIndex, int blockOffset) {
    final JpegScanComponent sc = scan.components[scanIndex];
    final Int16List coefficients = sc.component.coefficients;
    final int p1 = 1 << scan.approxLow; // 正系数的增量
    final int m1 = -1 << scan.approxLow; // 负系数的增量
    final JpegHuffmanTable ac = _acTable(sc.acTableId);

    int k = scan.spectralStart;
    if (eobRun == 0) {
      while (k <= scan.spectralEnd) {
        final int rs = ac.decode(reader);
        int run = (rs >> 4) & 0x0F;
        final int size = rs & 0x0F;
        int value = 0;
        if (size == 0) {
          if (run != 15) {
            // 细化趟的 EOBn 不减 1：当前块在下面的收尾段里统一减。
            eobRun = (1 << run);
            if (run > 0) {
              eobRun += reader.readBits(run);
            }
            break;
          }
          // ZRL：跳过 16 个**仍为零**的系数（非零的不算数，但要补校正位）。
        } else {
          // size 理论上恒为 1 —— 新变非零的系数只可能是 ±1×2^Al。
          // 读到别的值说明位流有问题，但 libjpeg 只是警告后照读一位，跟着走。
          value = reader.readBit() != 0 ? p1 : m1;
        }

        while (k <= scan.spectralEnd) {
          final int index = blockOffset + k;
          if (coefficients[index] != 0) {
            _refineNonZero(coefficients, index, p1, m1);
          } else {
            if (run == 0) {
              if (value != 0) {
                coefficients[index] = value;
              }
              k++;
              break;
            }
            run--;
          }
          k++;
        }
      }
    }

    if (eobRun > 0) {
      // 处在 EOB 游程里的块**不会**新增非零系数，但已有的非零系数照样要
      // 消费校正位 —— 漏掉这一步，渐进图会解出规律性的方格噪声。
      while (k <= scan.spectralEnd) {
        final int index = blockOffset + k;
        if (coefficients[index] != 0) {
          _refineNonZero(coefficients, index, p1, m1);
        }
        k++;
      }
      eobRun--;
    }
  }

  /// 给一个已经非零的系数补一个校正位：往远离零的方向挪一格。
  void _refineNonZero(Int16List coefficients, int index, int p1, int m1) {
    if (reader.readBit() == 0) {
      return;
    }
    final int current = coefficients[index];
    // 这一位平面已经写过就别写第二遍，否则幅值会翻倍。
    if ((current & p1) != 0) {
      return;
    }
    coefficients[index] = current >= 0 ? current + p1 : current + m1;
  }
}

/// 把一个分量的系数反量化 + IDCT，铺成它自己的样本平面（上采样前）。
///
/// 平面尺寸用**补齐后**的块数：边缘的 dummy block 也要有地方落，裁剪留给
/// 上采样那一步做。返回的平面每行 `blocksPerLineForMcu * kBlockDim` 字节。
Uint8List renderComponent(
  JpegComponent component,
  QuantizationTable quant,
  Idct idct,
) {
  final int stride = component.blocksPerLineForMcu * kBlockDim;
  final int rows = component.blocksPerColumnForMcu * kBlockDim;
  final Uint8List plane = Uint8List(stride * rows);
  final Int32List dequantized = Int32List(kBlockSize);

  for (int blockRow = 0; blockRow < component.blocksPerColumnForMcu;
      blockRow++) {
    for (int blockCol = 0; blockCol < component.blocksPerLineForMcu;
        blockCol++) {
      dequantizeBlock(
        component.coefficients,
        quant,
        dequantized,
        sourceOffset: component.blockOffset(blockRow, blockCol),
      );
      idct.transform(
        dequantized,
        plane,
        blockRow * kBlockDim * stride + blockCol * kBlockDim,
        stride,
      );
    }
  }
  return plane;
}

