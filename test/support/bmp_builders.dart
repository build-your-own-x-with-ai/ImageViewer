/// 手写 BMP 字节的构造器。
///
/// BMP 的头部有六个版本，手敲十六进制很容易出错，所以把「拼头部」这件事
/// 抽出来，测试里只需要关心真正要验证的字段。
library;

import 'dart:typed_data';

import 'byte_builders.dart';

/// 每行像素占多少字节（含 4 字节对齐填充）。
///
/// 测试里独立算一遍，而不是调用被测代码的 `BmpHeader.rowStride` ——
/// 否则公式写错时测试会跟着一起错，等于没测。
int bmpRowStride(int width, int bpp) => ((width * bpp + 31) ~/ 32) * 4;

/// 把若干行数据按 [rowStride] 补齐填充字节后拼接。
List<int> padRows(List<List<int>> rows, int rowStride) {
  final List<int> out = <int>[];
  for (final List<int> row in rows) {
    out.addAll(row);
    for (int i = row.length; i < rowStride; i++) {
      out.add(0);
    }
  }
  return out;
}

/// 构造 BITMAPINFOHEADER（40 字节）的 BMP —— 绝大多数真实文件是这一版。
///
/// [height] 为负表示自顶向下。
/// [palette] 每项是 `[r, g, b]`，写入时会转成 BMP 的 BGRA 顺序。
/// [bitfieldMasks] 是 `BI_BITFIELDS` 的掩码，按规范放在**调色板区域**。
Uint8List buildInfoBmp({
  required int width,
  required int height,
  required int bpp,
  required List<int> pixelData,
  int compression = 0,
  List<List<int>> palette = const <List<int>>[],
  List<int>? bitfieldMasks,
  int? sizeImage,
  int? clrUsed,
  int planes = 1,
  int xPpm = 0,
}) {
  final List<int> maskBytes = <int>[];
  for (final int m in bitfieldMasks ?? const <int>[]) {
    maskBytes.addAll(u32le(m));
  }
  final List<int> paletteBytes = _paletteToBgra(palette);
  final int offBits = 14 + 40 + maskBytes.length + paletteBytes.length;

  return concat(<List<int>>[
    _fileHeader(offBits, offBits + pixelData.length),
    u32le(40),
    i32le(width),
    i32le(height),
    u16le(planes),
    u16le(bpp),
    u32le(compression),
    u32le(sizeImage ?? pixelData.length),
    i32le(xPpm),
    i32le(0),
    u32le(clrUsed ?? palette.length),
    u32le(0),
    maskBytes,
    paletteBytes,
    pixelData,
  ]);
}

/// 构造 BITMAPCOREHEADER（12 字节）的 BMP —— OS/2 1.x 老格式。
///
/// 两个关键差异：宽高是 **u16**（所以没有自顶向下），
/// 调色板每项 **3 字节**（没有保留字节）。
Uint8List buildCoreBmp({
  required int width,
  required int height,
  required int bpp,
  required List<int> pixelData,
  List<List<int>> palette = const <List<int>>[],
}) {
  final List<int> paletteBytes = <int>[];
  for (final List<int> c in palette) {
    paletteBytes.addAll(<int>[c[2], c[1], c[0]]); // BGR，无保留字节
  }
  final int offBits = 14 + 12 + paletteBytes.length;

  return concat(<List<int>>[
    _fileHeader(offBits, offBits + pixelData.length),
    u32le(12),
    u16le(width),
    u16le(height),
    u16le(1),
    u16le(bpp),
    paletteBytes,
    pixelData,
  ]);
}

/// 构造 V2/V3/V4/V5 头部的 BMP。
///
/// 这些版本的掩码是**头部自身的字段**（不像 40 字节头那样借用调色板区），
/// 头部剩余部分（色彩空间、端点、gamma、渲染意图）用零填充。
///
/// [dibSize] 取 52 / 56 / 108 / 124。
Uint8List buildExtendedBmp({
  required int dibSize,
  required int width,
  required int height,
  required int bpp,
  required List<int> pixelData,
  int compression = 0,
  int redMask = 0,
  int greenMask = 0,
  int blueMask = 0,
  int alphaMask = 0,
}) {
  // 掩码字段：52 字节版只有 RGB 三个，56 及以上还有 alpha。
  final List<int> maskBytes = <int>[
    ...u32le(redMask),
    ...u32le(greenMask),
    ...u32le(blueMask),
    if (dibSize >= 56) ...u32le(alphaMask),
  ];
  // 头部剩余字节补零：40（基础字段）+ 掩码 之后的部分。
  final int tailLength = dibSize - 40 - maskBytes.length;
  final int offBits = 14 + dibSize;

  return concat(<List<int>>[
    _fileHeader(offBits, offBits + pixelData.length),
    u32le(dibSize),
    i32le(width),
    i32le(height),
    u16le(1),
    u16le(bpp),
    u32le(compression),
    u32le(pixelData.length),
    i32le(0),
    i32le(0),
    u32le(0),
    u32le(0),
    maskBytes,
    List<int>.filled(tailLength, 0),
    pixelData,
  ]);
}

/// BITMAPFILEHEADER，14 字节。
List<int> _fileHeader(int offBits, int fileSize) => <int>[
      ...ascii('BM'),
      ...u32le(fileSize),
      ...u16le(0), // bfReserved1
      ...u16le(0), // bfReserved2
      ...u32le(offBits),
    ];

/// 调色板项 `[r, g, b]` → BMP 的 BGRA 字节。
List<int> _paletteToBgra(List<List<int>> palette) {
  final List<int> out = <int>[];
  for (final List<int> c in palette) {
    out.addAll(<int>[c[2], c[1], c[0], 0]);
  }
  return out;
}

/// 测试里常用的四色调色板：黑、红、绿、蓝。
const List<List<int>> testPalette4 = <List<int>>[
  <int>[0, 0, 0],
  <int>[255, 0, 0],
  <int>[0, 255, 0],
  <int>[0, 0, 255],
];

/// 两色调色板：黑、白。
const List<List<int>> testPalette2 = <List<int>>[
  <int>[0, 0, 0],
  <int>[255, 255, 255],
];
