import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_frame.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_markers.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_quant.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_upsample.dart';

import '../support/jpeg_builders.dart';

/// 造一个帧。分量按 `[id, h, v, tq]` 给。
JpegFrame buildFrame(int width, int height, List<List<int>> comps) => parseSof(
      sofSegmentPayload(width, height, comps),
      marker: kMarkerSof0,
      offset: 0,
    );

int planeStride(JpegComponent c) => c.blocksPerLineForMcu * kBlockDim;

/// 按**补齐后**的尺寸开一个平面：真实区域填 [fill]，补齐区填 [padding]。
///
/// [padding] 默认 255 —— 上采样要是错按平面宽度去夹邻居，它就会渗进边缘几列，
/// 一眼看得出来。
Uint8List buildPlane(
  JpegComponent c, {
  required int fill,
  int padding = 255,
}) {
  final int stride = planeStride(c);
  final int rows = c.blocksPerColumnForMcu * kBlockDim;
  final Uint8List plane = Uint8List(stride * rows)
    ..fillRange(0, stride * rows, padding);
  for (int y = 0; y < c.sampleHeight; y++) {
    plane.fillRange(y * stride, y * stride + c.sampleWidth, fill);
  }
  return plane;
}

/// 把 [values] 写进平面的第 [row] 行。
void setRow(Uint8List plane, JpegComponent c, int row, List<int> values) {
  final int stride = planeStride(c);
  plane.setRange(row * stride, row * stride + values.length, values);
}

/// 取输出图的第 [row] 行。
List<int> outRow(Uint8List out, int width, int row) =>
    out.sublist(row * width, row * width + width);

void main() {
  group('JPEG 上采样：裁剪与最近邻', () {
    test('满分辨率分量只裁掉补齐区', () {
      final JpegFrame frame = buildFrame(17, 17, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent y = frame.components[0];
      expect(y.sampleWidth, 17);
      expect(planeStride(y), 32); // 补齐到 4 个块宽

      final Uint8List plane = buildPlane(y, fill: 60);
      setRow(plane, y, 0, List<int>.generate(17, (int i) => i));
      setRow(plane, y, 1, List<int>.filled(17, 99));

      final Uint8List out = upsampleComponent(plane, y, frame);
      expect(out, hasLength(17 * 17));
      expect(outRow(out, 17, 0), List<int>.generate(17, (int i) => i));
      expect(outRow(out, 17, 1), List<int>.filled(17, 99));
      expect(outRow(out, 17, 2), List<int>.filled(17, 60));
    });
    test('4:1:1 横向 4 倍：每个样本复制四份', () {
      final JpegFrame frame = buildFrame(32, 8, <List<int>>[
        <int>[1, 4, 1, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 8);

      final Uint8List plane = buildPlane(cb, fill: 0);
      setRow(plane, cb, 0, <int>[10, 20, 30, 40, 50, 60, 70, 80]);

      final Uint8List out = upsampleComponent(plane, cb, frame);
      expect(
        outRow(out, 32, 0),
        List<int>.generate(32, (int x) => (x >> 2) * 10 + 10),
      );
    });

    test('倍数不是整数（4/3）也算得出来', () {
      final JpegFrame frame = buildFrame(32, 8, <List<int>>[
        <int>[1, 4, 1, 0],
        <int>[2, 3, 1, 0],
        <int>[3, 3, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 24);

      // 样本值 = 列号，于是输出直接暴露列映射。
      final Uint8List plane = buildPlane(cb, fill: 0);
      setRow(plane, cb, 0, List<int>.generate(24, (int i) => i));

      final Uint8List out = upsampleComponent(plane, cb, frame);
      // 源列间距忽 0 忽 1：每 4 列里有一列是重复的。
      expect(outRow(out, 32, 0), <int>[
        0, 0, 1, 2, 3, 3, 4, 5, 6, 6, 7, 8, //
        9, 9, 10, 11, 12, 12, 13, 14, 15, 15, 16, 17, //
        18, 18, 19, 20, 21, 21, 22, 23, //
      ]);
    });
    test('fancy: false 时 4:2:0 退回最近邻', () {
      final JpegFrame frame = buildFrame(16, 16, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      final Uint8List plane = buildPlane(cb, fill: 0);
      setRow(plane, cb, 0, <int>[10, 20, 30, 40, 50, 60, 70, 80]);

      final Uint8List nearest =
          upsampleComponent(plane, cb, frame, fancy: false);
      expect(outRow(nearest, 16, 0), <int>[
        10, 10, 20, 20, 30, 30, 40, 40, //
        50, 50, 60, 60, 70, 70, 80, 80, //
      ]);
      // 同一份数据走三角滤波会平滑掉台阶 —— 两条路真的不一样。
      final Uint8List fancy = upsampleComponent(plane, cb, frame);
      expect(outRow(fancy, 16, 0)[1], isNot(10));
    });

    test('只在竖向抽样（4:4:0）也走最近邻 —— libjpeg 没有这一路的三角滤波', () {
      final JpegFrame frame = buildFrame(8, 16, <List<int>>[
        <int>[1, 1, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 8);
      expect(cb.sampleHeight, 8);

      final Uint8List plane = buildPlane(cb, fill: 99);
      setRow(plane, cb, 0, List<int>.filled(8, 11));
      setRow(plane, cb, 1, List<int>.filled(8, 22));

      final Uint8List out = upsampleComponent(plane, cb, frame);
      expect(out, hasLength(8 * 16));
      expect(outRow(out, 8, 0), List<int>.filled(8, 11));
      expect(outRow(out, 8, 1), List<int>.filled(8, 11));
      expect(outRow(out, 8, 2), List<int>.filled(8, 22));
      expect(outRow(out, 8, 3), List<int>.filled(8, 22));
      expect(outRow(out, 8, 4), List<int>.filled(8, 99));
    });
  });

  group('JPEG 上采样：h2v1 三角滤波', () {
    test('4:2:2 横向 2 倍：3/4 近 + 1/4 远', () {
      final JpegFrame frame = buildFrame(16, 8, <List<int>>[
        <int>[1, 2, 1, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 8);

      final Uint8List plane = buildPlane(cb, fill: 0);
      setRow(plane, cb, 0, <int>[10, 20, 30, 40, 50, 60, 70, 80]);

      final Uint8List out = upsampleComponent(plane, cb, frame);
      expect(outRow(out, 16, 0), <int>[
        10, 13, 17, 23, 27, 33, 37, 43, //
        47, 53, 57, 63, 67, 73, 77, 80, //
      ]);
      // 首末两列等于源样本本身：远邻夹回自己，(4a + 1) / 4 == a。
      expect(outRow(out, 16, 0).first, 10);
      expect(outRow(out, 16, 0).last, 80);
    });
    test('补齐列不参与插值 —— 边缘取邻居要夹在真实样本数上', () {
      // 20 宽的 4:2:2：色度真实宽度 10，但平面补齐到 16，第 10..15 列是垃圾。
      final JpegFrame frame = buildFrame(20, 8, <List<int>>[
        <int>[1, 2, 1, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 10);
      expect(planeStride(cb), 16);

      for (final int padding in <int>[255, 0]) {
        final Uint8List plane = buildPlane(cb, fill: 60, padding: padding);
        final Uint8List out = upsampleComponent(plane, cb, frame);
        expect(out, hasLength(20 * 8));
        // 按平面宽度去夹的话，末列会解成 (3×60 + padding + 2) / 4，
        // padding=255 时是 109，padding=0 时是 45。
        expect(out.every((int v) => v == 60), isTrue,
            reason: '补齐值 $padding 渗进了输出');
      }
    });
  });

  group('JPEG 上采样：h2v2 三角滤波', () {
    test('4:2:0 竖向也是 3:1 —— 一级台阶摊成四级', () {
      final JpegFrame frame = buildFrame(16, 16, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 8);
      expect(cb.sampleHeight, 8);

      // 每行内部是平的，所以横向滤波原样透过，只剩竖向的权重。
      final Uint8List plane = buildPlane(cb, fill: 200);
      setRow(plane, cb, 0, List<int>.filled(8, 100));

      final Uint8List out = upsampleComponent(plane, cb, frame);
      expect(out, hasLength(16 * 16));
      expect(outRow(out, 16, 0), List<int>.filled(16, 100));
      expect(outRow(out, 16, 1), List<int>.filled(16, 125));
      expect(outRow(out, 16, 2), List<int>.filled(16, 175));
      expect(outRow(out, 16, 3), List<int>.filled(16, 200));
      expect(outRow(out, 16, 15), List<int>.filled(16, 200));
    });
    test('横向权重和是 16、偏置 8/7 —— 结果和 h2v1 不一样', () {
      final JpegFrame frame = buildFrame(16, 16, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];

      // 八行完全一样，竖向滤波这一步就什么都不做，只剩横向。
      final Uint8List plane = buildPlane(cb, fill: 0);
      for (int row = 0; row < 8; row++) {
        setRow(plane, cb, row, <int>[10, 20, 30, 40, 50, 60, 70, 80]);
      }

      final Uint8List out = upsampleComponent(plane, cb, frame);
      const List<int> expected = <int>[
        10, 12, 18, 22, 28, 32, 38, 42, //
        48, 52, 58, 62, 68, 72, 78, 80, //
      ];
      expect(outRow(out, 16, 0), expected);
      expect(outRow(out, 16, 7), expected);
      expect(outRow(out, 16, 15), expected);
      // 同一行数据走 h2v1 会解成 13/17/23…… 分母不同，中间值就不同。
      expect(expected[1], isNot(13));
    });
    test('补齐的行和列都不参与插值，平色不漂', () {
      // 20×20 的 4:2:0：色度真实 10×10，平面补齐到 16×16。
      final JpegFrame frame = buildFrame(20, 20, <List<int>>[
        <int>[1, 2, 2, 0],
        <int>[2, 1, 1, 0],
        <int>[3, 1, 1, 0],
      ]);
      final JpegComponent cb = frame.components[1];
      expect(cb.sampleWidth, 10);
      expect(cb.sampleHeight, 10);
      expect(planeStride(cb), 16);

      // 权重和 16、偏置 8/7 → (16L + 8) >> 4 == L，两端也不用夹。
      for (final int level in <int>[0, 1, 60, 255]) {
        for (final int padding in <int>[0, 255]) {
          final Uint8List plane =
              buildPlane(cb, fill: level, padding: padding);
          final Uint8List out = upsampleComponent(plane, cb, frame);
          expect(out, hasLength(20 * 20));
          expect(out.every((int v) => v == level), isTrue,
              reason: '平色 $level 在补齐值 $padding 下漂了');
        }
      }
    });
  });
}
