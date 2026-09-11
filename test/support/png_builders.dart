/// 手写 PNG 字节的构造器。
///
/// PNG 的每个 chunk 都要算 CRC，手敲十六进制不现实，所以把「拼 chunk」
/// 抽出来。CRC 用的是 `deflate_builders.dart` 里逐位计算的朴素实现，
/// 与被测的查表版彼此独立。
library;

import 'dart:typed_data';

import 'byte_builders.dart';
import 'deflate_builders.dart';

/// PNG 的八字节签名。
const List<int> pngSignature = <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A];

/// 拼一个 chunk：`长度(4) + 类型(4) + 数据 + CRC(4)`。
///
/// 注意 CRC 覆盖**类型 + 数据**，不含长度字段。这个范围划分容易记错，
/// 而错了以后所有 chunk 的 CRC 都不对，症状是「文件完全打不开」。
List<int> pngChunk(String type, List<int> data) {
  final List<int> typeAndData = <int>[...ascii(type), ...data];
  return <int>[
    ...u32be(data.length),
    ...typeAndData,
    ...u32be(bitwiseCrc32(typeAndData)),
  ];
}

/// 拼 `IHDR` 的 13 字节数据。
List<int> ihdrData({
  required int width,
  required int height,
  required int bitDepth,
  required int colorType,
  int compression = 0,
  int filter = 0,
  int interlace = 0,
}) =>
    <int>[
      ...u32be(width),
      ...u32be(height),
      bitDepth,
      colorType,
      compression,
      filter,
      interlace,
    ];

/// 给每行数据加上滤波器类型字节，拼成 inflate 应输出的原始流。
///
/// [rows] 的每一项是一行**已滤波**的图像字节。测试里多数用滤波器 0
/// （不滤波），这样期望像素就等于写进去的字节，一眼能对上。
List<int> rawWithFilters(List<List<int>> rows, {int filterType = 0}) {
  final List<int> out = <int>[];
  for (final List<int> row in rows) {
    out.add(filterType);
    out.addAll(row);
  }
  return out;
}

/// 组装一个完整 PNG。
///
/// [raw] 是「滤波类型字节 + 行数据」的完整序列，会被存储块压缩后放进
/// 单个 `IDAT`。默认用存储块是刻意的：PNG 各层的测试不该依赖 Huffman
/// 路径是否正确。
Uint8List buildPng({
  required int width,
  required int height,
  required int bitDepth,
  required int colorType,
  required List<int> raw,
  int interlace = 0,
  List<int>? palette,
  List<int>? transparency,
  List<List<int>>? extraChunksBeforeIdat,
  List<List<int>>? extraChunksAfterIdat,
  int idatSplit = 1,
  bool includeEnd = true,
  Uint8List? compressedOverride,
}) {
  final Uint8List compressed = compressedOverride ?? storedZlib(raw);

  final List<int> out = <int>[
    ...pngSignature,
    ...pngChunk(
      'IHDR',
      ihdrData(
        width: width,
        height: height,
        bitDepth: bitDepth,
        colorType: colorType,
        interlace: interlace,
      ),
    ),
  ];

  if (palette != null) {
    out.addAll(pngChunk('PLTE', palette));
  }
  if (transparency != null) {
    out.addAll(pngChunk('tRNS', transparency));
  }
  for (final List<int> c in extraChunksBeforeIdat ?? const <List<int>>[]) {
    out.addAll(c);
  }

  // 切成多个 IDAT，用来验证「解码方必须先拼接再解压」。
  final int per = (compressed.length + idatSplit - 1) ~/ idatSplit;
  for (int at = 0; at < compressed.length; at += per) {
    final int end =
        at + per > compressed.length ? compressed.length : at + per;
    out.addAll(pngChunk('IDAT', compressed.sublist(at, end)));
  }

  for (final List<int> c in extraChunksAfterIdat ?? const <List<int>>[]) {
    out.addAll(c);
  }
  if (includeEnd) {
    out.addAll(pngChunk('IEND', const <int>[]));
  }
  return Uint8List.fromList(out);
}

/// 最常用的快捷方式：8 位 RGB，逐行给出 RGB 三元组，不滤波。
Uint8List buildRgb8Png(List<List<int>> rows, {int interlace = 0}) {
  final int height = rows.length;
  final int width = rows.first.length ~/ 3;
  return buildPng(
    width: width,
    height: height,
    bitDepth: 8,
    colorType: 2,
    raw: rawWithFilters(rows),
    interlace: interlace,
  );
}

/// 8 位灰度快捷方式。
Uint8List buildGray8Png(List<List<int>> rows) => buildPng(
      width: rows.first.length,
      height: rows.length,
      bitDepth: 8,
      colorType: 0,
      raw: rawWithFilters(rows),
    );
