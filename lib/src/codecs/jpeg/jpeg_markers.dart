/// JPEG 的 marker 常量与段扫描器。
///
/// ## JPEG 的结构和 PNG 完全不是一回事
///
/// PNG 是「长度 + 类型 + 数据 + CRC」的规整链条，每个 chunk 都自带长度，
/// 解码器可以盲跳过任何不认识的东西。JPEG 没有这种规整性：
///
/// * 文件是**marker 驱动**的 —— `0xFF` 后跟一个字节表示段类型
/// * 有的 marker 带长度，有的不带（[isStandalone]）
/// * 最要紧的一段（熵编码数据）**根本没有长度字段** —— 它从 `SOS` 段之后
///   一直延伸到下一个 marker 为止，所以扫描器必须在字节层面识别哪个 `0xFF`
///   是 marker、哪个是数据里的 `0xFF`（见 [BitReaderMsb]）
/// * 没有 CRC，没有任何校验 —— 一个位翻转会静默地毁掉后面所有块
///
/// 这几条决定了解码器的形态：PNG 能写成「读完 chunk 列表再处理」，JPEG
/// 只能写成**状态机** —— 段与段之间有依赖（`SOS` 要用之前 `DHT` 装好的
/// 码表），而且同一个 marker 可以出现任意多次并覆盖之前的状态。
///
/// ## 为什么 marker 都以 0xFF 开头
///
/// 为了能在损坏的流里**重新同步**。解码器丢失位置时只要往后找 `0xFF`
/// 就有机会找回下一个段的开头。代价是数据里真正的 `0xFF` 字节必须转义
/// 成 `FF 00`，这就是字节填充的由来。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

/// marker 的前缀字节。
const int kMarkerPrefix = 0xFF;

/// 图像开始。文件的头两个字节恒为 `FF D8`。
const int kMarkerSoi = 0xD8;

/// 图像结束。
const int kMarkerEoi = 0xD9;

/// 基线顺序 DCT，Huffman 编码。绝大多数 JPEG 是这个。
const int kMarkerSof0 = 0xC0;

/// 扩展顺序 DCT，Huffman 编码。与基线的差别只在位深可为 12 与表数量上限。
const int kMarkerSof1 = 0xC1;

/// 渐进式 DCT，Huffman 编码。
const int kMarkerSof2 = 0xC2;

/// 定义 Huffman 码表。
const int kMarkerDht = 0xC4;

/// 定义量化表。
const int kMarkerDqt = 0xDB;

/// 定义重启间隔。
const int kMarkerDri = 0xDD;

/// 扫描开始。它之后紧跟着无长度标记的熵编码数据。
const int kMarkerSos = 0xDA;

/// 定义行数。用于编码时高度未知的流，出现在第一个扫描之后。
const int kMarkerDnl = 0xDC;

/// 重启 marker RST0 的值，RST0..RST7 是 `0xD0`..`0xD7`。
const int kMarkerRst0 = 0xD0;

/// 重启 marker RST7。
const int kMarkerRst7 = 0xD7;

/// APP0，JFIF 用它声明密度信息。
const int kMarkerApp0 = 0xE0;

/// APP1，EXIF 用它装 TIFF 结构。
const int kMarkerApp1 = 0xE1;

/// APP14，Adobe 用它声明色彩变换（决定四通道图是 CMYK 还是 YCCK）。
const int kMarkerApp14 = 0xEE;

/// APP15。
const int kMarkerApp15 = 0xEF;

/// 注释。
const int kMarkerCom = 0xFE;

/// 临时私用，算术编码专用。与 RSTn 一样不带长度。
const int kMarkerTem = 0x01;

/// 是否是**不带长度字段**的 marker。
///
/// 这一小撮例外是 JPEG 解析里第一个容易写错的地方：对它们读两字节长度
/// 会把后面的真实数据当成长度用掉，之后整个文件的解析全部错位。
///
/// 名单本身是有道理的 —— 这些 marker 全是**纯信号**，不携带参数：
/// `SOI`/`EOI` 标记边界，`RSTn` 标记重启点，`TEM` 是临时私用。
bool isStandalone(int marker) =>
    marker == kMarkerSoi ||
    marker == kMarkerEoi ||
    marker == kMarkerTem ||
    isRestart(marker);

/// 是否是重启 marker（RST0..RST7）。
bool isRestart(int marker) => marker >= kMarkerRst0 && marker <= kMarkerRst7;

/// 是否是帧开始 marker（SOFn）。
///
/// SOF 占 `0xC0`..`0xCF` 这一段，但中间挖掉了两个：`0xC4` 是 `DHT`，
/// `0xCC` 是 `DAC`（算术编码的条件表）。它们混在 SOF 的编号区间里纯属
/// 历史原因，写判断时漏掉这两个例外会把码表当成帧头去解析。
bool isSof(int marker) =>
    marker >= 0xC0 && marker <= 0xCF && marker != kMarkerDht && marker != 0xCC;

/// 是否是 APPn 应用段。
bool isApp(int marker) => marker >= kMarkerApp0 && marker <= kMarkerApp15;

/// marker 的可读名字，用于异常信息与信息面板。
String markerName(int marker) {
  if (isApp(marker)) {
    return 'APP${marker - kMarkerApp0}';
  }
  if (isRestart(marker)) {
    return 'RST${marker - kMarkerRst0}';
  }
  return _names[marker] ?? '未知 marker 0x${marker.toRadixString(16)}';
}

const Map<int, String> _names = <int, String>{
  kMarkerSoi: 'SOI',
  kMarkerEoi: 'EOI',
  kMarkerSof0: 'SOF0（基线）',
  kMarkerSof1: 'SOF1（扩展顺序）',
  kMarkerSof2: 'SOF2（渐进式）',
  0xC3: 'SOF3（无损）',
  0xC5: 'SOF5（差分顺序）',
  0xC6: 'SOF6（差分渐进）',
  0xC7: 'SOF7（差分无损）',
  0xC8: 'JPG（保留）',
  0xC9: 'SOF9（算术扩展顺序）',
  0xCA: 'SOF10（算术渐进）',
  0xCB: 'SOF11（算术无损）',
  0xCC: 'DAC（算术条件表）',
  0xCD: 'SOF13（差分算术顺序）',
  0xCE: 'SOF14（差分算术渐进）',
  0xCF: 'SOF15（差分算术无损）',
  kMarkerDht: 'DHT',
  kMarkerDqt: 'DQT',
  kMarkerDri: 'DRI',
  kMarkerSos: 'SOS',
  kMarkerDnl: 'DNL',
  kMarkerCom: 'COM',
  kMarkerTem: 'TEM',
  0xDE: 'DHP（分层进度）',
  0xDF: 'EXP（扩展参考分量）',
};

/// 一个已定位的段。
class JpegSegment {
  const JpegSegment({
    required this.marker,
    required this.offset,
    required this.dataOffset,
    required this.length,
  });

  /// marker 的第二字节，如 `0xDB`（DQT）。
  final int marker;

  /// 段起始偏移，指向 `0xFF`。
  final int offset;

  /// 段数据起始偏移（已跳过 marker 与两字节长度）。
  ///
  /// 不带长度的 marker（[isStandalone]）这里等于 `offset + 2`，[length] 为 0。
  final int dataOffset;

  /// 段数据长度（**不含**长度字段自身的两个字节）。
  final int length;

  /// 可读名字。
  String get name => markerName(marker);

  @override
  String toString() => '$name @$offset（$length 字节）';
}

/// 段扫描器。逐个吐出 marker，遇到 `SOS` 时把控制权交回调用方。
///
/// ## 为什么不能一次扫完所有段
///
/// PNG 的做法是先把 chunk 列表读完再处理，JPEG 不行 —— `SOS` 之后是没有
/// 长度的熵编码数据，扫描器无法知道它有多长。**只有熵解码器自己知道**：
/// 它一直解到 MCU 数量够了或者撞上 marker 为止。
///
/// 所以流程必须是「扫描器读到 SOS → 熵解码器接手 → 报告它停在哪 →
/// 扫描器从那里继续」。这个来回是 JPEG 解码器写成状态机的直接原因。
class JpegSegmentScanner {
  JpegSegmentScanner(this.bytes) : _reader = ByteReader(bytes, format: 'JPEG');

  /// 原始字节。
  final Uint8List bytes;

  final ByteReader _reader;

  /// 当前扫描位置。
  int get offset => _reader.offset;

  /// 从指定位置继续扫描。熵解码器停下来之后由调用方设置。
  set offset(int value) => _reader.offset = value;

  /// 是否还有字节可读。
  bool get hasMore => !_reader.isAtEnd;

  /// 读文件头的 `SOI`。
  void readSoi() {
    if (bytes.length < 2) {
      throw ImageDecodeException('文件只有 ${bytes.length} 字节，放不下 SOI',
          format: 'JPEG');
    }
    if (bytes[0] != kMarkerPrefix || bytes[1] != kMarkerSoi) {
      throw ImageDecodeException(
        '文件不以 SOI（FF D8）开头，实际是 '
        '${_hex(bytes[0])} ${_hex(bytes[1])}',
        format: 'JPEG',
        offset: 0,
      );
    }
    _reader.offset = 2;
  }

  /// 定位下一个段。返回 null 表示已到文件末尾。
  ///
  /// ## 填充字节
  ///
  /// 规范允许 marker 之前有任意多个 `0xFF` 填充。这不是理论上的宽容 ——
  /// 真实文件里确实会出现（某些编码器用它对齐），所以这里必须循环跳过，
  /// 而不是假设 marker 恰好是两个字节。
  JpegSegment? next() {
    // 找到下一个 0xFF。中间出现的非 0xFF 字节是垃圾（上一段声明的长度
    // 有误，或者熵数据没解干净），跳过并继续找 —— 这是 JPEG 靠 0xFF
    // 重新同步的能力，报错太严格反而打不开一批只是尾部有杂字节的文件。
    int skipped = 0;
    while (!_reader.isAtEnd && bytes[_reader.offset] != kMarkerPrefix) {
      _reader.skip(1);
      skipped++;
    }
    if (_reader.isAtEnd) {
      return null;
    }

    final int start = _reader.offset;
    // 跳过连续的 0xFF 填充，停在 marker 的第二字节上。
    while (!_reader.isAtEnd && bytes[_reader.offset] == kMarkerPrefix) {
      _reader.skip(1);
    }
    if (_reader.isAtEnd) {
      // 文件以 0xFF 结尾。当作正常结束 —— 已经解出的图像不该因为
      // 尾部多一个字节被丢掉。
      return null;
    }

    final int marker = _reader.u8('marker');
    if (marker == 0x00) {
      // `FF 00` 是数据里的转义 0xFF，出现在这里说明位置错了。
      throw ImageDecodeException(
        '在段边界上遇到 FF 00（这是熵数据里的转义序列，'
        '不是 marker）${skipped > 0 ? '，此前已跳过 $skipped 个杂字节' : ''}',
        format: 'JPEG',
        offset: start,
      );
    }

    if (isStandalone(marker)) {
      return JpegSegment(
        marker: marker,
        offset: start,
        dataOffset: _reader.offset,
        length: 0,
      );
    }

    final int declared = _reader.u16be('${markerName(marker)} 段长度');
    // 长度字段把自己那两个字节也算在内，所以合法值至少是 2。
    if (declared < 2) {
      throw ImageDecodeException(
        '${markerName(marker)} 的长度字段是 $declared，'
        '而长度含自身两字节，合法值不小于 2',
        format: 'JPEG',
        offset: start,
      );
    }
    final int dataLength = declared - 2;
    _reader.ensureAvailable(dataLength, '${markerName(marker)} 段数据');
    final JpegSegment segment = JpegSegment(
      marker: marker,
      offset: start,
      dataOffset: _reader.offset,
      length: dataLength,
    );
    _reader.skip(dataLength);
    return segment;
  }

  /// 取某段的数据视图。
  Uint8List dataOf(JpegSegment segment) =>
      Uint8List.sublistView(bytes, segment.dataOffset,
          segment.dataOffset + segment.length);

  static String _hex(int b) =>
      b.toRadixString(16).toUpperCase().padLeft(2, '0');
}
