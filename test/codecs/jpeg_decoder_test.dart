/// JPEG 解码器的端到端测试：从字节到像素，走完整条管线。
///
/// 载荷一律是纯色。这不是偷懒 —— 纯色的期望值能闭式算出来，而且**管线上任何
/// 一环出错都会改变结果**：量化表用错亮度就偏，MCU 顺序错了分量就串，块网格
/// 走错图像就斜切，升采样边界错了边缘就花。子模块的精度由各自的单测负责，
/// 这里负责的是「接线对不对」。
library;

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_decoder.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

import '../support/jpeg_builders.dart';

const JpegDecoder decoder = JpegDecoder();

/// 把若干片段接成一个文件。错误路径得手工拼，[buildFlatJpeg] 只造合法文件。
Uint8List assemble(List<Uint8List> parts) {
  final BytesBuilder b = BytesBuilder();
  for (final Uint8List p in parts) {
    b.add(p);
  }
  return b.toBytes();
}

/// 断言整张图只有一种像素，且等于 [expected]。
///
/// 把图像塌缩成「出现过的像素集合」再比对：任何一个像素不对，集合就多一个元素，
/// 失败信息里直接能看到跑出来的是什么值，不用逐点断言。
void expectUniform(RgbaImage img, List<int> expected) {
  final Set<String> seen = <String>{};
  for (int y = 0; y < img.height; y++) {
    for (int x = 0; x < img.width; x++) {
      seen.add(img.channelsAt(x, y).join(','));
    }
  }
  expect(seen, <String>{expected.join(',')});
}

void main() {
  group('识别', () {
    test('名字和扩展名', () {
      expect(decoder.name, 'JPEG');
      expect(decoder.extensions, containsAll(<String>['jpg', 'jpeg']));
    });

    test('SOI 后面还要再看一个 FF', () {
      // 只看 FF D8 会把任意二进制误判成 JPEG —— 这两字节太短了。
      expect(decoder.canDecode(Uint8List.fromList(<int>[0xFF, 0xD8, 0xFF])),
          isTrue);
      expect(decoder.canDecode(Uint8List.fromList(<int>[0xFF, 0xD8, 0x00])),
          isFalse);
    });

    test('短缓冲区不越界', () {
      expect(decoder.canDecode(Uint8List(0)), isFalse);
      expect(decoder.canDecode(Uint8List.fromList(<int>[0xFF])), isFalse);
      expect(decoder.canDecode(Uint8List.fromList(<int>[0xFF, 0xD8])), isFalse);
    });

    test('别的格式的头一律拒绝', () {
      expect(decoder.canDecode(Uint8List.fromList(<int>[0x89, 0x50, 0x4E])),
          isFalse);
      expect(decoder.canDecode(Uint8List.fromList(<int>[0x42, 0x4D, 0xFF])),
          isFalse);
    });

    test('真文件能认出来', () {
      final Uint8List bytes = buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 128)],
      );
      expect(decoder.canDecode(bytes), isTrue);
    });
  });

  group('灰度', () {
    test('整块尺寸', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 16,
        height: 16,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 200)],
      ));
      expect(img.width, 16);
      expect(img.height, 16);
      expectUniform(img, <int>[200, 200, 200, 255]);
    });

    test('尺寸不是 8 的倍数：补齐的部分要裁掉', () {
      // 13x5 会被补成 16x8 解，多出来的行列必须不出现在结果里。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 13,
        height: 5,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 77)],
      ));
      expect(img.width, 13);
      expect(img.height, 5);
      expect(img.pixels.length, 13 * 5 * 4);
      expectUniform(img, <int>[77, 77, 77, 255]);
    });

    test('1x1', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 1,
        height: 1,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 255)],
      ));
      expectUniform(img, <int>[255, 255, 255, 255]);
    });

    test('样本值原样出来，不经过色彩变换', () {
      for (final int v in <int>[0, 1, 64, 128, 191, 254, 255]) {
        final RgbaImage img = decoder.decode(buildFlatJpeg(
          width: 8,
          height: 8,
          components: <FlatComponent>[FlatComponent(id: 1, sample: v)],
        ));
        expect(img.channelsAt(0, 0), <int>[v, v, v, 255], reason: '样本 $v');
      }
    });

    test('元数据', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 128)],
      ));
      expect(img.metadata.format, 'JPEG');
      expect(img.metadata.variant, '基线（SOF0）');
      expect(img.metadata.bitDepth, 8);
      expect(img.metadata.channels, 1);
      expect(img.metadata.colorSpace, 'Grayscale');
      expect(img.metadata.isLossless, isFalse);
      expect(img.metadata.extra['采样'], '单分量（灰度）');
      expect(img.metadata.extra['扫描趟数'], 1);
      expect(img.metadata.extra['量化表'], 1);
      expect(img.metadata.extra['码表'], 2);
      expect(img.metadata.extra.containsKey('重启间隔'), isFalse);
    });
  });

  group('三分量 YCbCr', () {
    /// 一张纯色的三分量图。[jfif] 决定色彩空间怎么判定。
    RgbaImage color(
      int y,
      int cb,
      int cr, {
      int width = 16,
      int height = 16,
      int h = 1,
      int v = 1,
      bool jfif = true,
    }) =>
        decoder.decode(buildFlatJpeg(
          width: width,
          height: height,
          components: <FlatComponent>[
            FlatComponent(id: 1, sample: y, h: h, v: v),
            FlatComponent(id: 2, sample: cb),
            FlatComponent(id: 3, sample: cr),
          ],
          extraSegments: <Uint8List>[if (jfif) jfifSegment()],
        ));

    test('4:4:4 纯红', () {
      // 定点值与 jpeg_color_test 里手算钉住的一致：Cr 到顶截断掉 1。
      expectUniform(color(76, 85, 255), <int>[254, 0, 0, 255]);
    });

    test('中性色度 → 灰', () {
      expectUniform(color(160, 128, 128), <int>[160, 160, 160, 255]);
    });

    test('4:2:0：色度平面小一半，升采样后仍然处处一致', () {
      final RgbaImage img = color(76, 85, 255, width: 17, height: 9, h: 2, v: 2);
      expect(img.width, 17);
      expect(img.height, 9);
      expectUniform(img, <int>[254, 0, 0, 255]);
      expect(img.metadata.extra['采样'], '4:2:0');
      expect(img.metadata.extra['MCU'], '16x16（2x1 个）');
    });

    test('4:2:2', () {
      final RgbaImage img = color(29, 255, 107, width: 15, height: 8, h: 2);
      expectUniform(img, <int>[0, 0, 254, 255]);
      expect(img.metadata.extra['采样'], '4:2:2');
    });

    test('没有 JFIF、分量号是 1/2/3 → 仍然按 YCbCr 解', () {
      expectUniform(color(76, 85, 255, jfif: false), <int>[254, 0, 0, 255]);
    });

    test('元数据', () {
      final RgbaImage img = color(128, 128, 128);
      expect(img.metadata.channels, 3);
      expect(img.metadata.colorSpace, 'YCbCr (BT.601)');
      expect(img.metadata.extra['采样'], '4:4:4');
      expect(img.metadata.extra['采样因子'], '1x1 1x1 1x1');
      expect(img.metadata.extra['JFIF'], '有');
    });
  });

  group('渐进', () {
    test('DC 首趟就够：纯色图的 AC 全零', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 16,
        height: 16,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 96)],
        sofMarker: 0xC2,
      ));
      expectUniform(img, <int>[96, 96, 96, 255]);
      expect(img.metadata.variant, '渐进（SOF2）');
    });

    test('交错的 DC 趟（渐进唯一允许交错的情况）', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 16,
        height: 16,
        components: const <FlatComponent>[
          FlatComponent(id: 1, sample: 76, h: 2, v: 2),
          FlatComponent(id: 2, sample: 85),
          FlatComponent(id: 3, sample: 255),
        ],
        extraSegments: <Uint8List>[jfifSegment()],
        sofMarker: 0xC2,
      ));
      expectUniform(img, <int>[254, 0, 0, 255]);
    });

    test('尺寸不整齐的渐进图', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 11,
        height: 3,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 33)],
        sofMarker: 0xC2,
      ));
      expect(img.width, 11);
      expectUniform(img, <int>[33, 33, 33, 255]);
    });
  });

  group('重启间隔', () {
    test('单分量：每 3 个块一个 RSTn', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 32,
        height: 32,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 64)],
        restartInterval: 3,
      ));
      expectUniform(img, <int>[64, 64, 64, 255]);
      expect(img.metadata.extra['重启间隔'], '3 个 MCU');
    });

    test('间隔 1：每个单元后面都有 marker，RSTn 要循环 0..7', () {
      // 32x32 的 4:2:0 是 2x2 个 MCU；间隔 1 时会跨过 RST0..RST3。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 32,
        height: 32,
        components: const <FlatComponent>[
          FlatComponent(id: 1, sample: 76, h: 2, v: 2),
          FlatComponent(id: 2, sample: 85),
          FlatComponent(id: 3, sample: 255),
        ],
        extraSegments: <Uint8List>[jfifSegment()],
        restartInterval: 1,
      ));
      expectUniform(img, <int>[254, 0, 0, 255]);
    });

    test('间隔超过单元总数：一个 marker 都不该出现', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 16,
        height: 16,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 111)],
        restartInterval: 999,
      ));
      expectUniform(img, <int>[111, 111, 111, 255]);
    });

    test('RSTn 绕回：单元数超过 8 个间隔', () {
      // 每块一个 marker，8x8=64 块 → marker 序号绕 8 圈。序号错了解码器会
      // 找不到 marker，DC 预测继承错误值，图像就出条纹。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 64,
        height: 64,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 210)],
        restartInterval: 1,
      ));
      expectUniform(img, <int>[210, 210, 210, 255]);
    });

    test('渐进 + 重启', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 24,
        height: 16,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 150)],
        sofMarker: 0xC2,
        restartInterval: 2,
      ));
      expectUniform(img, <int>[150, 150, 150, 255]);
    });
  });

  group('色彩空间判定', () {
    /// 一张纯色的四分量图，[transform] 写进 APP14。
    RgbaImage four(int transform, List<int> samples) =>
        decoder.decode(buildFlatJpeg(
          width: 16,
          height: 16,
          components: <FlatComponent>[
            for (int i = 0; i < 4; i++)
              FlatComponent(id: i + 1, sample: samples[i]),
          ],
          extraSegments: <Uint8List>[adobeSegment(transform)],
        ));

    test('APP14 transform=0 + 4 分量 → CMYK', () {
      // Adobe 反存：文件里的样本就是 255-墨量，所以 64 直接落到红通道。
      final RgbaImage img = four(0, <int>[64, 255, 128, 255]);
      expect(img.metadata.colorSpace, 'CMYK');
      expect(img.metadata.channels, 4);
      expect(img.metadata.extra['Adobe 变换'], 0);
      expectUniform(img, <int>[64, 255, 128, 255]);
    });

    test('CMYK 的两个端点', () {
      // 全 255 = 不上墨 = 白；K 那一路为 0 = 全黑覆盖。
      expectUniform(four(0, <int>[255, 255, 255, 255]),
          <int>[255, 255, 255, 255]);
      expectUniform(four(0, <int>[255, 255, 255, 0]), <int>[0, 0, 0, 255]);
    });

    test('APP14 transform=2 + 4 分量 → YCCK', () {
      final RgbaImage img = four(2, <int>[76, 85, 255, 255]);
      expect(img.metadata.colorSpace, 'YCCK');
      expectUniform(img, <int>[1, 255, 255, 255]);
    });

    test('没有 APP14 的 4 分量按 CMYK 处理，但样本不反存', () {
      // 这条和上面的 CMYK 用同样的样本值，结果必须**不同** —— 否则说明
      // adobeInverted 这个开关根本没接上。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[
          FlatComponent(id: 1, sample: 64),
          FlatComponent(id: 2, sample: 255),
          FlatComponent(id: 3, sample: 128),
          FlatComponent(id: 4, sample: 255),
        ],
      ));
      expect(img.metadata.colorSpace, 'CMYK');
      // ac = 255-64 = 191，ak = 255-255 = 0 → 全黑。
      expectUniform(img, <int>[0, 0, 0, 255]);
    });

    test('APP14 transform=0 + 3 分量 → RGB，且不反存', () {
      // 反存只对 CMYK/YCCK 成立。RGB 分支要原样透传，否则颜色会整体取反。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[
          FlatComponent(id: 1, sample: 10),
          FlatComponent(id: 2, sample: 20),
          FlatComponent(id: 3, sample: 30),
        ],
        extraSegments: <Uint8List>[adobeSegment(0)],
      ));
      expect(img.metadata.colorSpace, 'RGB');
      expectUniform(img, <int>[10, 20, 30, 255]);
    });

    test("分量号是 'R''G''B' → RGB", () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[
          FlatComponent(id: 0x52, sample: 200),
          FlatComponent(id: 0x47, sample: 100),
          FlatComponent(id: 0x42, sample: 50),
        ],
      ));
      expect(img.metadata.colorSpace, 'RGB');
      expectUniform(img, <int>[200, 100, 50, 255]);
    });

    test("JFIF 压过 'R''G''B' 分量号", () {
      // 有编码器两个都写，而数据其实还是 YCbCr。JFIF 优先才不会解错色。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[
          FlatComponent(id: 0x52, sample: 160),
          FlatComponent(id: 0x47, sample: 128),
          FlatComponent(id: 0x42, sample: 128),
        ],
        extraSegments: <Uint8List>[jfifSegment()],
      ));
      expect(img.metadata.colorSpace, 'YCbCr (BT.601)');
      expectUniform(img, <int>[160, 160, 160, 255]);
    });
  });

  group('附属段', () {
    test('EXIF 方向 6：报出来的宽高要换过来', () {
      // 纯色图看不出像素怎么转的（applyOrientation 的像素级正确性由
      // jpeg_exif_test 钉住），这里只验证「方向被读到了、宽高跟着换了」。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 16,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 90)],
        extraSegments: <Uint8List>[exifOrientationSegment(6)],
      ));
      expect(img.width, 8);
      expect(img.height, 16);
      expect(img.pixels.length, 8 * 16 * 4);
      expect(img.metadata.extra['EXIF 方向'], '6（顺时针 90°）');
      expectUniform(img, <int>[90, 90, 90, 255]);
    });

    test('EXIF 方向 2：镜像不换宽高', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 16,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 90)],
        extraSegments: <Uint8List>[exifOrientationSegment(2)],
      ));
      expect(img.width, 16);
      expect(img.height, 8);
      expect(img.metadata.extra['EXIF 方向'], '2（水平镜像）');
    });

    test('EXIF 方向 1 不进元数据', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 90)],
        extraSegments: <Uint8List>[exifOrientationSegment(1)],
      ));
      expect(img.metadata.extra.containsKey('EXIF 方向'), isFalse);
    });

    test('坏 APP1 不影响解码', () {
      // 「坏 EXIF 不能毁掉一张好图」—— 段截断到只剩 'Exif\0\0'。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 42)],
        extraSegments: <Uint8List>[
          segment(0xE1, <int>[0x45, 0x78, 0x69, 0x66, 0x00, 0x00]),
        ],
      ));
      expectUniform(img, <int>[42, 42, 42, 255]);
      expect(img.metadata.extra.containsKey('EXIF 方向'), isFalse);
    });

    test('COM 注释进元数据', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 42)],
        extraSegments: <Uint8List>[commentSegment('hello jpeg')],
      ));
      expect(img.metadata.extra['注释'], 'hello jpeg');
    });

    test('认不出的 APP 段直接跳过', () {
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 42)],
        extraSegments: <Uint8List>[
          segment(0xE5, <int>[1, 2, 3, 4, 5]),
          segment(0xEF, <int>[0xFF, 0xD8, 0xFF]), // 段内的假 marker 也不能当真
        ],
      ));
      expectUniform(img, <int>[42, 42, 42, 255]);
    });
  });

  group('错误路径', () {
    /// 合法文件的各个零件，错误路径按需拆装。
    final Uint8List soi = Uint8List.fromList(<int>[0xFF, 0xD8]);
    final Uint8List eoi = Uint8List.fromList(<int>[0xFF, 0xD9]);
    final Uint8List dqt = segment(0xDB, dqtAllOnes());
    final Uint8List dhtDc =
        segment(0xC4, flatDcSpec.dhtPayload(tableClass: 0, id: 0));
    final Uint8List dhtAc =
        segment(0xC4, flatAcSpec.dhtPayload(tableClass: 1, id: 0));
    final Uint8List sof = segment(
        0xC0, sofSegmentPayload(8, 8, <List<int>>[<int>[1, 1, 1, 0]]));
    final Uint8List sos =
        segment(0xDA, sosSegmentPayload(<List<int>>[<int>[1, 0, 0]]));
    final Uint8List entropy = encodeFlatScan(
        8, 8, const <FlatComponent>[FlatComponent(id: 1, sample: 128)]);

    test('不以 SOI 开头', () {
      expect(
        () => decoder.decode(Uint8List.fromList(<int>[0x89, 0x50, 0x4E, 0x47])),
        throwsA(isA<ImageDecodeException>()
            .having((ImageDecodeException e) => e.message, 'message',
                contains('不以 SOI'))),
      );
    });

    test('空文件', () {
      expect(() => decoder.decode(Uint8List(0)),
          throwsA(isA<ImageDecodeException>()));
    });

    test('只有 SOI 和 EOI：没有 SOF', () {
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, eoi])),
        throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message, 'message',
            contains('没有 SOF'))),
      );
    });

    test('有 SOF 没 SOS', () {
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, dqt, sof, eoi])),
        throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message, 'message',
            contains('没有 SOS'))),
      );
    });

    test('SOS 出现在 SOF 之前', () {
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, dqt, sos, eoi])),
        throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message, 'message',
            contains('SOS 出现在 SOF 之前'))),
      );
    });

    test('第二个 SOF → 不支持多帧', () {
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, dqt, sof, sof, eoi])),
        throwsA(isA<UnsupportedImageFeature>()),
      );
    });

    test('引用没定义过的量化表', () {
      // 量化表在渲染阶段才用到，所以这个错误发生在熵解码之后。
      expect(
        () => decoder.decode(assemble(
            <Uint8List>[soi, dhtDc, dhtAc, sof, sos, entropy, eoi])),
        throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message, 'message',
            contains('量化表'))),
      );
    });

    test('引用没定义过的霍夫曼表', () {
      expect(
        () => decoder
            .decode(assemble(<Uint8List>[soi, dqt, sof, sos, entropy, eoi])),
        throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message, 'message',
            contains('霍夫曼表'))),
      );
    });

    test('尺寸大到装不下：SOF 合法但缓冲区会爆', () {
      // 65535x65535 是合法的 SOF 编码，但 RGBA 缓冲区要 17GB。必须在读到
      // 宽高的那一刻就拒绝，而不是等到分配的时候。
      final Uint8List huge = segment(
          0xC0, sofSegmentPayload(65535, 65535, <List<int>>[<int>[1, 1, 1, 0]]));
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, dqt, huge, sos, eoi])),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('零尺寸', () {
      final Uint8List zero = segment(
          0xC0, sofSegmentPayload(0, 8, <List<int>>[<int>[1, 1, 1, 0]]));
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, dqt, zero, eoi])),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('DRI 段装不下两字节', () {
      final Uint8List shortDri = segment(0xDD, <int>[0]);
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, shortDri, eoi])),
        throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message, 'message',
            contains('DRI'))),
      );
    });

    test('DRI 段多出来的字节被容忍', () {
      // 只要前两字节读得到就往下走。段长带冗余的文件真实存在，为此拒绝解码
      // 是不划算的 —— 多余字节不影响间隔值。
      final Uint8List longDri = segment(0xDD, <int>[0, 1, 0xAB]);
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi, dqt, dhtDc, dhtAc, longDri, sof, sos, entropy, eoi,
      ]));
      expect(img.metadata.extra['重启间隔'], '1 个 MCU');
      expectUniform(img, <int>[128, 128, 128, 255]);
    });

    test('五个分量：超出 CMYK 的上限', () {
      final Uint8List five = segment(
          0xC0,
          sofSegmentPayload(8, 8, <List<int>>[
            for (int i = 1; i <= 5; i++) <int>[i, 1, 1, 0],
          ]));
      expect(
        () => decoder.decode(assemble(<Uint8List>[soi, dqt, five, eoi])),
        throwsA(anyOf(
            isA<ImageDecodeException>(), isA<UnsupportedImageFeature>())),
      );
    });
  });

  group('状态机', () {
    final Uint8List soi = Uint8List.fromList(<int>[0xFF, 0xD8]);
    final Uint8List eoi = Uint8List.fromList(<int>[0xFF, 0xD9]);
    final Uint8List dhtDc =
        segment(0xC4, flatDcSpec.dhtPayload(tableClass: 0, id: 0));
    final Uint8List dhtAc =
        segment(0xC4, flatAcSpec.dhtPayload(tableClass: 1, id: 0));

    /// 单分量 16x16 的 SOF / SOS / 熵数据，量化表号可选。
    Uint8List sofOf(int tq) => segment(
        0xC0, sofSegmentPayload(16, 16, <List<int>>[<int>[1, 1, 1, tq]]));
    final Uint8List sos =
        segment(0xDA, sosSegmentPayload(<List<int>>[<int>[1, 0, 0]]));
    Uint8List entropyOf(int sample) => encodeFlatScan(
        16, 16, <FlatComponent>[FlatComponent(id: 1, sample: sample)]);

    test('后面的 DQT 覆盖前面的同号表', () {
      // DQT 不是「读一次就定了」的头部字段，而是可变的当前状态。这里两张表
      // 的乘数差一倍：取错哪一张，亮度立刻就偏。
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi,
        segment(0xDB, dqtAllOnes(fill: 2)),
        segment(0xDB, dqtAllOnes()),
        dhtDc, dhtAc, sofOf(0), sos, entropyOf(160), eoi,
      ]));
      expectUniform(img, <int>[160, 160, 160, 255]);
    });

    test('反过来放：证明第一张表不是被无条件忽略', () {
      // 量化值 2 → DC 放大一倍 → (160-128)*2+128 = 192。
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi,
        segment(0xDB, dqtAllOnes()),
        segment(0xDB, dqtAllOnes(fill: 2)),
        dhtDc, dhtAc, sofOf(0), sos, entropyOf(160), eoi,
      ]));
      expectUniform(img, <int>[192, 192, 192, 255]);
    });

    test('一个 DQT 段里塞两张表', () {
      // 段长决定能装几张，parseDqt 要一直读到段尾。只读第一张的实现会让
      // 引用 #1 的分量报「表没定义」。
      final Uint8List both = segment(0xDB, <int>[
        ...dqtAllOnes(fill: 2),
        ...dqtAllOnes(id: 1),
      ]);
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi, both, dhtDc, dhtAc, sofOf(1), sos, entropyOf(160), eoi,
      ]));
      expect(img.metadata.extra['量化表'], 2);
      expectUniform(img, <int>[160, 160, 160, 255]);
    });

    test('顺序模式的三趟非交错扫描', () {
      // 基线不一定是「一趟传完」：每个分量各占一趟也是合法的。熵数据没有长度
      // 字段，所以这条同时验证了扫描器是否从 decodeScan 的返回值恢复偏移 ——
      // 恢复错了第二趟的 SOS 就找不到。
      final List<Uint8List> scans = <Uint8List>[];
      for (int i = 0; i < 3; i++) {
        scans.add(segment(
            0xDA, sosSegmentPayload(<List<int>>[<int>[i + 1, 0, 0]])));
        scans.add(encodeFlatScan(16, 16,
            <FlatComponent>[FlatComponent(id: i + 1, sample: <int>[76, 85, 255][i])]));
      }
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi,
        segment(0xDB, dqtAllOnes()),
        dhtDc,
        dhtAc,
        jfifSegment(),
        segment(
            0xC0,
            sofSegmentPayload(16, 16, <List<int>>[
              for (int i = 0; i < 3; i++) <int>[i + 1, 1, 1, 0],
            ])),
        ...scans,
        eoi,
      ]));
      expect(img.metadata.extra['扫描趟数'], 3);
      expectUniform(img, <int>[254, 0, 0, 255]);
    });

    test('marker 前的 FF 填充要跳过', () {
      // 规范允许 marker 前有任意多个 FF。真实文件里确实出现过（用来对齐）。
      final Uint8List fill = Uint8List.fromList(<int>[0xFF, 0xFF, 0xFF]);
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi, fill, segment(0xDB, dqtAllOnes()), fill, dhtDc, dhtAc,
        sofOf(0), sos, entropyOf(88), eoi,
      ]));
      expectUniform(img, <int>[88, 88, 88, 255]);
    });

    test('熵数据被截断：不该抛，尽力解出一张图', () {
      // 部分解码比整体失败有用 —— 看图工具遇到半张图应该显示半张，
      // 读不到的块系数保持 0，渲染成中性灰。
      final Uint8List full = entropyOf(200);
      final RgbaImage img = decoder.decode(assemble(<Uint8List>[
        soi, segment(0xDB, dqtAllOnes()), dhtDc, dhtAc, sofOf(0), sos,
        Uint8List.sublistView(full, 0, 2),
      ]));
      expect(img.width, 16);
      expect(img.height, 16);
      expect(img.channelsAt(0, 0), <int>[200, 200, 200, 255]);
    });

    test('EOI 之后的垃圾字节不影响结果', () {
      final Uint8List bytes = buildFlatJpeg(
        width: 8,
        height: 8,
        components: const <FlatComponent>[FlatComponent(id: 1, sample: 55)],
      );
      final RgbaImage img = decoder.decode(
          assemble(<Uint8List>[bytes, Uint8List.fromList(<int>[1, 2, 3, 4])]));
      expectUniform(img, <int>[55, 55, 55, 255]);
    });

    test('单分量但采样因子是 2x2：走真实块网格，不是补齐后的', () {
      // 唯一区分两套块数的场合。走错网格图像会整体斜切 —— 纯色图看不出斜切，
      // 但块数不对会让位流提前读完或读越界，所以仍然是有效的判别。
      final RgbaImage img = decoder.decode(buildFlatJpeg(
        width: 20,
        height: 12,
        components: const <FlatComponent>[
          FlatComponent(id: 1, sample: 175, h: 2, v: 2),
        ],
      ));
      expect(img.width, 20);
      expect(img.height, 12);
      expectUniform(img, <int>[175, 175, 175, 255]);
    });
  });
}
