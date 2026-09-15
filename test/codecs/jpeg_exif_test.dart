import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_exif.dart';
import 'package:image_viewer/src/core/errors.dart';

/// TIFF 头相对 APP1 载荷起点的偏移。
const int tiffBase = 6;

void put16(List<int> out, int v, bool little) {
  if (little) {
    out.add(v & 0xFF);
    out.add((v >> 8) & 0xFF);
  } else {
    out.add((v >> 8) & 0xFF);
    out.add(v & 0xFF);
  }
}

void put32(List<int> out, int v, bool little) {
  if (little) {
    put16(out, v & 0xFFFF, true);
    put16(out, (v >> 16) & 0xFFFF, true);
  } else {
    put16(out, (v >> 16) & 0xFFFF, false);
    put16(out, v & 0xFFFF, false);
  }
}

/// 一条 IFD 条目。
class IfdEntry {
  const IfdEntry(this.tag, this.type, this.count, this.value);

  /// SHORT 型、count=1 的方向标记，也就是规范要求的写法。
  const IfdEntry.orientation(int value) : this(0x0112, 3, 1, value);

  final int tag;
  final int type;
  final int count;
  final int value;
}

/// 写条目的 value 字段。
///
/// 不满 4 字节的值是**左对齐**的：SHORT 占前两字节，后两字节是填充。
void putValue(List<int> out, IfdEntry e, bool little) {
  switch (e.type) {
    case 1: // BYTE
      out.add(e.value & 0xFF);
      out.addAll(<int>[0, 0, 0]);
    case 3: // SHORT
      put16(out, e.value, little);
      out.addAll(<int>[0, 0]);
    default: // LONG 及其它，占满四字节
      put32(out, e.value, little);
  }
}

/// 拼一份 APP1 载荷：`'Exif' 00 00` + TIFF 头 + IFD0。
Uint8List exifPayload({
  List<IfdEntry> entries = const <IfdEntry>[IfdEntry.orientation(6)],
  bool little = true,
  int magic = 42,
  int ifdOffset = 8,
  int? entryCount,
  List<int> prefix = const <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00],
  List<int>? byteOrder,
  int? truncateTo,
}) {
  final List<int> out = <int>[...prefix];
  out.addAll(byteOrder ?? (little ? <int>[0x49, 0x49] : <int>[0x4D, 0x4D]));
  put16(out, magic, little);
  put32(out, ifdOffset, little);
  // TIFF 头本身 8 字节，ifdOffset 更大时中间补零。
  while (out.length - tiffBase < ifdOffset) {
    out.add(0);
  }
  put16(out, entryCount ?? entries.length, little);
  for (final IfdEntry e in entries) {
    put16(out, e.tag, little);
    put16(out, e.type, little);
    put32(out, e.count, little);
    putValue(out, e, little);
  }
  put32(out, 0, little); // 没有下一个 IFD
  final Uint8List bytes = Uint8List.fromList(out);
  return truncateTo == null
      ? bytes
      : Uint8List.sublistView(bytes, 0, truncateTo);
}

/// 测试图：R 通道存 `y*10 + x`，另三个通道跟着一起编码 —— 用来验证四个
/// 通道是整体搬家，而不是各搬各的。
Uint8List testImage(int width, int height) {
  final Uint8List px = Uint8List(width * height * 4);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final int v = y * 10 + x;
      final int o = (y * width + x) * 4;
      px[o] = v;
      px[o + 1] = 100 + v;
      px[o + 2] = 200 - v;
      px[o + 3] = 255;
    }
  }
  return px;
}

/// 只取 R 通道，方便和期望的排布逐个比。
List<int> reds(Uint8List px) =>
    <int>[for (int i = 0; i < px.length; i += 4) px[i]];

void main() {
  group('EXIF 方向标记解析', () {
    test('小端与大端解出同一个方向', () {
      // 同一份逻辑内容，两种字节序，结果必须一致 —— 这是动态字节序那段
      // 代码唯一的正确性判据。
      expect(parseExifOrientation(exifPayload(little: true)),
          JpegOrientation.rotate90);
      expect(parseExifOrientation(exifPayload(little: false)),
          JpegOrientation.rotate90);
    });

    test('八个取值都能解出来', () {
      for (final JpegOrientation want in JpegOrientation.values) {
        for (final bool little in <bool>[true, false]) {
          expect(
            parseExifOrientation(exifPayload(
              entries: <IfdEntry>[IfdEntry.orientation(want.exifValue)],
              little: little,
            )),
            want,
            reason: '值 ${want.exifValue}，小端=$little',
          );
        }
      }
    });

    test('不是 Exif 段就返回 null', () {
      // 装 XMP 的 APP1 长这样，很常见，不能把它当 EXIF 去解。
      expect(
        parseExifOrientation(exifPayload(
          prefix: <int>[0x68, 0x74, 0x74, 0x70, 0x3A, 0x2F], // 'http:/'
        )),
        isNull,
      );
    });

    test('字节序标记不是 II 或 MM 就返回 null', () {
      expect(
        parseExifOrientation(exifPayload(byteOrder: <int>[0x49, 0x4D])),
        isNull,
      );
    });

    test('魔数不是 42 就返回 null', () {
      // 魔数的唯一用途就是复核字节序判断：读反了会得到 0x2A00 = 10752。
      expect(parseExifOrientation(exifPayload(magic: 10752)), isNull);
      expect(parseExifOrientation(exifPayload(magic: 0)), isNull);
    });

    test('IFD 里没有方向标记就返回 null', () {
      // 0x011A 是 XResolution，一个真实存在但跟方向无关的 tag。
      expect(
        parseExifOrientation(exifPayload(
          entries: <IfdEntry>[const IfdEntry(0x011A, 5, 1, 72)],
        )),
        isNull,
      );
    });

    test('方向标记在一堆条目中间也能找到', () {
      // 条目按 tag 升序排列（规范要求），方向标记不一定是第一条。
      expect(
        parseExifOrientation(exifPayload(entries: <IfdEntry>[
          const IfdEntry(0x010F, 2, 6, 100), // Make
          const IfdEntry(0x0110, 2, 6, 200), // Model
          const IfdEntry.orientation(8),
          const IfdEntry(0x011A, 5, 1, 72), // XResolution
        ])),
        JpegOrientation.rotate270,
      );
    });

    test('越界的方向值（0 和 9）返回 null', () {
      for (final int bad in <int>[0, 9, 255, 0xFFFF]) {
        expect(
          parseExifOrientation(exifPayload(
            entries: <IfdEntry>[IfdEntry.orientation(bad)],
          )),
          isNull,
          reason: '值 $bad',
        );
      }
    });

    test('BYTE 和 LONG 型的方向标记也认', () {
      // 规范规定是 SHORT，但确实有固件写成这两种。既然值的位置和语义都
      // 明确，认下来比丢掉方向信息好。
      for (final int type in <int>[1, 4]) {
        expect(
          parseExifOrientation(exifPayload(
            entries: <IfdEntry>[IfdEntry(0x0112, type, 1, 6)],
            little: true,
          )),
          JpegOrientation.rotate90,
          reason: 'type=$type 小端',
        );
        expect(
          parseExifOrientation(exifPayload(
            entries: <IfdEntry>[IfdEntry(0x0112, type, 1, 6)],
            little: false,
          )),
          JpegOrientation.rotate90,
          reason: 'type=$type 大端',
        );
      }
    });

    test('大端 SHORT 的值取前两字节，不是后两字节', () {
      // 这条单独立出来是因为它是最隐蔽的一个坑：值不满 4 字节时左对齐，
      // 所以大端下 6 写成 `00 06 00 00`。整个读成 u32 再取低 16 位会得到
      // 0（值被左移了 16 位），方向就被静默丢掉。
      final Uint8List payload = exifPayload(
        entries: <IfdEntry>[const IfdEntry.orientation(6)],
        little: false,
      );
      // 条目的 value 字段：'Exif\0\0'(6) + TIFF 头(8) + 条目数(2) + 8。
      const int valueAt = 6 + 8 + 2 + 8;
      expect(
        <int>[payload[valueAt], payload[valueAt + 1]],
        <int>[0x00, 0x06],
        reason: '左对齐的 SHORT',
      );
      expect(parseExifOrientation(payload), JpegOrientation.rotate90);
    });

    test('RATIONAL 之类的类型当没写', () {
      expect(
        parseExifOrientation(exifPayload(
          entries: <IfdEntry>[const IfdEntry(0x0112, 5, 1, 6)],
        )),
        isNull,
      );
    });

    test('count 不是 1 就返回 null', () {
      expect(
        parseExifOrientation(exifPayload(
          entries: <IfdEntry>[const IfdEntry(0x0112, 3, 2, 6)],
        )),
        isNull,
      );
    });

    test('IFD 偏移落在 TIFF 头里（< 8）就返回 null', () {
      expect(parseExifOrientation(exifPayload(ifdOffset: 4)), isNull);
      expect(parseExifOrientation(exifPayload(ifdOffset: 0)), isNull);
    });

    test('IFD 偏移超出载荷就返回 null，而不是越界崩掉', () {
      // 声明偏移 100000 但载荷只剩 TIFF 头 —— 相机固件写坏偏移表就是这样。
      expect(
        parseExifOrientation(
            exifPayload(ifdOffset: 100000, truncateTo: tiffBase + 8)),
        isNull,
      );
      // 偏移合法但数据被截掉了，连条目数都读不出来。
      expect(parseExifOrientation(exifPayload(truncateTo: tiffBase + 8)),
          isNull);
    });

    test('条目数声明得比实际多也不崩', () {
      expect(
        parseExifOrientation(exifPayload(
          entries: <IfdEntry>[const IfdEntry.orientation(6)],
          entryCount: 50,
        )),
        // 方向标记是第一条，越界之前就找到了。
        JpegOrientation.rotate90,
      );
      expect(
        parseExifOrientation(exifPayload(
          entries: <IfdEntry>[const IfdEntry(0x010F, 2, 6, 1)],
          entryCount: 50,
        )),
        isNull,
      );
    });

    test('载荷太短一律返回 null', () {
      for (int n = 0; n < tiffBase + 8; n++) {
        expect(parseExifOrientation(Uint8List(n)), isNull, reason: 'n=$n');
      }
    });
  });

  group('方向枚举', () {
    test('八个取值按 1..8 排列', () {
      expect(JpegOrientation.values.length, 8);
      for (int i = 0; i < 8; i++) {
        expect(JpegOrientation.values[i].exifValue, i + 1);
      }
    });

    test('只有 5..8 换宽高', () {
      // swapsDimensions 等价于"要不要转置"，而转置正是 5..8 这一半。
      for (final JpegOrientation o in JpegOrientation.values) {
        expect(o.swapsDimensions, o.exifValue >= 5, reason: '${o.exifValue}');
      }
    });

    test('orientationFromExif 拒绝 0 和 9', () {
      expect(orientationFromExif(0), isNull);
      expect(orientationFromExif(9), isNull);
      expect(orientationFromExif(-1), isNull);
      expect(orientationFromExif(1), JpegOrientation.normal);
      expect(orientationFromExif(8), JpegOrientation.rotate270);
    });

    test('每个取值都有可读的名字', () {
      for (final JpegOrientation o in JpegOrientation.values) {
        expect(o.label, isNotEmpty);
      }
    });
  });

  group('应用方向', () {
    // 3×2 的图，R 通道存 y*10+x：
    //     0  1  2
    //     10 11 12
    final Uint8List src = testImage(3, 2);

    test('八种取值各自的排布', () {
      // 期望值是照着 applyOrientation 文档里那张目标→源映射表逐格算的，
      // 不是跑一遍再抄回来 —— 否则表和实现一起错了也测不出来。
      const Map<int, List<int>> want = <int, List<int>>{
        1: <int>[0, 1, 2, 10, 11, 12],
        2: <int>[2, 1, 0, 12, 11, 10],
        3: <int>[12, 11, 10, 2, 1, 0],
        4: <int>[10, 11, 12, 0, 1, 2],
        5: <int>[0, 10, 1, 11, 2, 12],
        6: <int>[10, 0, 11, 1, 12, 2],
        7: <int>[12, 2, 11, 1, 10, 0],
        8: <int>[2, 12, 1, 11, 0, 10],
      };
      for (final JpegOrientation o in JpegOrientation.values) {
        expect(
          reds(applyOrientation(src, 3, 2, o)),
          want[o.exifValue],
          reason: '${o.exifValue}（${o.label}）',
        );
      }
    });

    test('顺时针 90° 把左列自下而上转成首行', () {
      // 把上面那张表里最常用的一格单独讲清楚：竖拍照片就靠这一格摆正。
      //     0  1  2         10 0
      //     10 11 12   →    11 1
      //                     12 2
      expect(reds(applyOrientation(src, 3, 2, JpegOrientation.rotate90)),
          <int>[10, 0, 11, 1, 12, 2]);
      expect(reds(applyOrientation(src, 3, 2, JpegOrientation.rotate270)),
          <int>[2, 12, 1, 11, 0, 10]);
    });

    test('四个通道整体搬家', () {
      // R 对了不代表 G/B/A 也对：分量各搬各的会让颜色错位而排布正确。
      final Uint8List out =
          applyOrientation(src, 3, 2, JpegOrientation.rotate90);
      for (int i = 0; i < 6; i++) {
        final int r = out[i * 4];
        expect(out[i * 4 + 1], 100 + r, reason: '像素 $i 的 G');
        expect(out[i * 4 + 2], 200 - r, reason: '像素 $i 的 B');
        expect(out[i * 4 + 3], 255, reason: '像素 $i 的 A');
      }
    });

    test('normal 原样返回同一个对象，不复制', () {
      expect(
        applyOrientation(src, 3, 2, JpegOrientation.normal),
        same(src),
      );
    });

    test('输出长度不变，宽高按 swapsDimensions 互换', () {
      for (final JpegOrientation o in JpegOrientation.values) {
        expect(applyOrientation(src, 3, 2, o).length, src.length,
            reason: '${o.exifValue}');
      }
    });

    test('转置类操作作用两次回到原图', () {
      // 2/3/4/5/7 是对合（自己是自己的逆），6 和 8 互为逆 —— 这八种取值
      // 构成的正是正方形的二面体群 D4，这条断言顺手把群结构验了。
      for (final JpegOrientation o in JpegOrientation.values) {
        if (o == JpegOrientation.rotate90 ||
            o == JpegOrientation.rotate270) {
          continue;
        }
        final int w = o.swapsDimensions ? 2 : 3;
        final int h = o.swapsDimensions ? 3 : 2;
        final Uint8List once = applyOrientation(src, 3, 2, o);
        expect(reds(applyOrientation(once, w, h, o)), reds(src),
            reason: '${o.exifValue}（${o.label}）');
      }
    });

    test('顺时针 90° 做两次等于 180°', () {
      final Uint8List once =
          applyOrientation(src, 3, 2, JpegOrientation.rotate90);
      // 一次之后是 2×3，第二次要按新尺寸传。
      final Uint8List twice =
          applyOrientation(once, 2, 3, JpegOrientation.rotate90);
      expect(reds(twice),
          reds(applyOrientation(src, 3, 2, JpegOrientation.rotate180)));
    });

    test('像素缓冲与宽高不符时抛异常', () {
      expect(
        () => applyOrientation(src, 4, 2, JpegOrientation.rotate90),
        throwsA(isA<ImageDecodeException>()),
      );
      // normal 的快捷路径也要先校验，不能因为不重排就放过去。
      expect(
        () => applyOrientation(src, 4, 2, JpegOrientation.normal),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('1×N 和 N×1 这类退化尺寸也正确', () {
      // 转置会把 1×4 变成 4×1，是最容易在下标上写错的形状。
      final Uint8List strip = testImage(4, 1);
      expect(reds(applyOrientation(strip, 4, 1, JpegOrientation.rotate90)),
          <int>[0, 1, 2, 3]);
      expect(reds(applyOrientation(strip, 4, 1, JpegOrientation.transpose)),
          <int>[0, 1, 2, 3]);
      expect(reds(applyOrientation(strip, 4, 1, JpegOrientation.rotate180)),
          <int>[3, 2, 1, 0]);
    });
  });
}
