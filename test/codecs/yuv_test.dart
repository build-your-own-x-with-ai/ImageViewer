import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_color.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_decoder.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_format.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_options.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

import '../support/pixel_matchers.dart';

const YuvDecoder decoder = YuvDecoder();

/// 一组「色彩转换等于恒等映射」的参数。
///
/// 全范围下 `yScale=1, yOffset=0`，再让 `U=V=128` 使 `cb=cr=0`，于是
/// `R = G = B = Y` 精确成立。这样就能把**平面布局对不对**和**色彩数学对不对**
/// 分开测：布局测试用这组参数，颜色一旦不是灰的就说明字节读错了位置。
YuvOptions lumaOnly(int width, int height, YuvFormat format) => YuvOptions(
      width: width,
      height: height,
      format: format,
      range: YuvRange.full,
    );

/// 断言某像素是灰阶值 [value]（R=G=B=value，不透明）。
void expectGray(RgbaImage img, int x, int y, int value, {String? reason}) {
  expectPixel(img, x, y, <int>[value, value, value, 255], reason: reason);
}

Uint8List bytesOf(List<int> values) => Uint8List.fromList(values);

void main() {
  group('canDecode / decode：裸数据不能自动识别', () {
    test('canDecode 对任何字节都返回 false', () {
      // 关键设计点：YUV 没有魔数。如果这里返回 true，YUV 就会接管所有
      // 认不出来的文件，把「未知格式」变成一堆彩色噪点。
      expect(decoder.canDecode(bytesOf(<int>[])), isFalse);
      expect(decoder.canDecode(bytesOf(<int>[0, 1, 2, 3])), isFalse);
      // 连真正的 PNG 头也不认 —— 它本来就不该认。
      expect(
        decoder.canDecode(bytesOf(<int>[0x89, 0x50, 0x4E, 0x47])),
        isFalse,
      );
      // 一份合法的 I420 数据同样返回 false。
      expect(
        decoder.canDecode(bytesOf(<int>[128, 128, 128, 128, 128, 128])),
        isFalse,
      );
    });

    test('decode 抛异常并说明缺哪些参数', () {
      expect(
        () => decoder.decode(bytesOf(List<int>.filled(6, 128))),
        throwsA(
          isA<ImageDecodeException>()
              .having((ImageDecodeException e) => e.message, 'message',
                  allOf(contains('没有头部'), contains('decodeWith')))
              .having((ImageDecodeException e) => e.message, '带上文件长度',
                  contains('6 字节')),
        ),
      );
    });

    test('defaultOptions 是空参数，isComplete 为 false', () {
      expect(decoder.defaultOptions, YuvOptions.empty);
      expect(decoder.defaultOptions.isComplete, isFalse);
    });

    test('name 与 extensions', () {
      expect(decoder.name, 'YUV');
      expect(decoder.extensions, contains('yuv'));
      expect(decoder.extensions, contains('nv21'));
    });
  });

  group('平面格式：亮度平面索引', () {
    test('I420 4x2 亮度按行主序展开，色度中性时输出等于 Y', () {
      // U=V=128 + 全范围 ⇒ 灰阶。任何一个像素不是自己的 Y 值，
      // 就说明亮度平面的行偏移算错了。
      final Uint8List bytes = bytesOf(<int>[
        10, 20, 30, 40, // Y 第 0 行
        50, 60, 70, 80, // Y 第 1 行
        128, 128, // U 平面（2x1）
        128, 128, // V 平面（2x1）
      ]);
      final RgbaImage img =
          decoder.decodeWith(bytes, lumaOnly(4, 2, YuvFormat.i420));

      expect(img.width, 4);
      expect(img.height, 2);
      const List<int> expected = <int>[10, 20, 30, 40, 50, 60, 70, 80];
      for (int i = 0; i < expected.length; i++) {
        expectGray(img, i % 4, i ~/ 4, expected[i],
            reason: '亮度平面第 $i 个字节');
      }
    });

    test('I444 每个像素有独立色度', () {
      // 4:4:4 不抽样，相邻两个像素可以是完全不同的颜色。
      final Uint8List bytes = bytesOf(<int>[
        128, 128, // Y
        255, 128, // U 平面（逐像素）
        128, 255, // V 平面（逐像素）
      ]);
      final RgbaImage img =
          decoder.decodeWith(bytes, lumaOnly(2, 1, YuvFormat.i444));

      expectPixel(img, 0, 0, <int>[128, 84, 255, 255], reason: 'U=255,V=128');
      expectPixel(img, 1, 0, <int>[255, 37, 128, 255], reason: 'U=128,V=255');
    });

    test('4:2:0 的一个色度样本被上下两行共用', () {
      // 2x4：色度平面 1x2，第 0 行覆盖 y=0/1，第 1 行覆盖 y=2/3。
      final Uint8List bytes = bytesOf(<int>[
        ...List<int>.filled(8, 128), // Y 2x4
        255, 128, // U 平面 1x2
        128, 128, // V 平面 1x2
      ]);
      final RgbaImage img =
          decoder.decodeWith(bytes, lumaOnly(2, 4, YuvFormat.i420));

      for (int x = 0; x < 2; x++) {
        expectPixel(img, x, 0, <int>[128, 84, 255, 255], reason: 'y=0 用 U=255');
        expectPixel(img, x, 1, <int>[128, 84, 255, 255], reason: 'y=1 共用同一个色度样本');
        expectGray(img, x, 2, 128, reason: 'y=2 换到色度第 1 行 U=128');
        expectGray(img, x, 3, 128, reason: 'y=3 共用第 1 行');
      }
    });
  });

  group('U/V 平面顺序：只差一个 uFirst', () {
    // 同一份字节，用配对的两种格式解出来颜色必须互换 —— 这才证明
    // uFirst 真的在起作用，而不是碰巧两边都读了同一个平面。
    final Uint8List planar2x2 = bytesOf(<int>[
      128, 128, 128, 128, // Y
      255, // 前一个色度平面
      128, // 后一个色度平面
    ]);

    test('I420 先 U 后 V → 偏蓝', () {
      final RgbaImage img =
          decoder.decodeWith(planar2x2, lumaOnly(2, 2, YuvFormat.i420));
      expectSolidColor(img, <int>[128, 84, 255, 255]);
    });

    test('YV12 先 V 后 U → 偏红（同一份字节）', () {
      final RgbaImage img =
          decoder.decodeWith(planar2x2, lumaOnly(2, 2, YuvFormat.yv12));
      expectSolidColor(img, <int>[255, 37, 128, 255]);
    });

    test('NV12 色度交织，U 在偶字节 → 偏蓝', () {
      final RgbaImage img =
          decoder.decodeWith(planar2x2, lumaOnly(2, 2, YuvFormat.nv12));
      expectSolidColor(img, <int>[128, 84, 255, 255]);
    });

    test('NV21 色度交织，V 在偶字节 → 偏红（同一份字节）', () {
      final RgbaImage img =
          decoder.decodeWith(planar2x2, lumaOnly(2, 2, YuvFormat.nv21));
      expectSolidColor(img, <int>[255, 37, 128, 255]);
    });

    test('I420 与 NV12 的区别是平面 vs 交织，不只是顺序', () {
      // 4x2 才能看出来：色度四个字节在 I420 里是「UU|VV」，
      // 在 NV12 里是「UV|UV」。2x2 时两者恰好等价，测不出差别。
      final Uint8List bytes = bytesOf(<int>[
        ...List<int>.filled(8, 128), // Y 4x2
        255, 128, 200, 100, // 色度四字节
      ]);

      final RgbaImage asI420 =
          decoder.decodeWith(bytes, lumaOnly(4, 2, YuvFormat.i420));
      // I420：U=[255,128]，V=[200,100]
      expectPixel(asI420, 0, 0, <int>[229, 33, 255, 255], reason: 'U=255,V=200');
      expectPixel(asI420, 2, 0, <int>[89, 148, 128, 255], reason: 'U=128,V=100');

      final RgbaImage asNv12 =
          decoder.decodeWith(bytes, lumaOnly(4, 2, YuvFormat.nv12));
      // NV12：(U,V)=(255,128) 与 (200,100)
      expectPixel(asNv12, 0, 0, <int>[128, 84, 255, 255], reason: 'U=255,V=128');
      expectPixel(asNv12, 2, 0, <int>[89, 123, 255, 255], reason: 'U=200,V=100');
    });
  });

  group('打包格式：三种字节序', () {
    // 一份字节，三种打包格式解出三种不同结果。这是最能说明「打包格式的
    // 差别纯粹在字节顺序」的一组测试。
    //
    //   YUY2  Y0 U  Y1 V  → Y0=128 U=255 Y1=128 V=128
    //   YVYU  Y0 V  Y1 U  → Y0=128 V=255 Y1=128 U=128
    //   UYVY  U  Y0 V  Y1 → U=128 Y0=255 V=128 Y1=128
    final Uint8List packed2x1 = bytesOf(<int>[128, 255, 128, 128]);

    test('YUY2：Y U Y V', () {
      final RgbaImage img =
          decoder.decodeWith(packed2x1, lumaOnly(2, 1, YuvFormat.yuy2));
      // 一个宏像素内两个像素共用同一组 U/V。
      expectPixel(img, 0, 0, <int>[128, 84, 255, 255]);
      expectPixel(img, 1, 0, <int>[128, 84, 255, 255]);
    });

    test('YVYU：Y V Y U（同一份字节，颜色互换）', () {
      final RgbaImage img =
          decoder.decodeWith(packed2x1, lumaOnly(2, 1, YuvFormat.yvyu));
      expectPixel(img, 0, 0, <int>[255, 37, 128, 255]);
      expectPixel(img, 1, 0, <int>[255, 37, 128, 255]);
    });

    test('UYVY：U Y V Y（色度在前，亮度落在奇字节）', () {
      final RgbaImage img =
          decoder.decodeWith(packed2x1, lumaOnly(2, 1, YuvFormat.uyvy));
      // 这里 Y0=255、Y1=128，色度中性 ⇒ 一白一灰，跟上面两个结果都不一样。
      expectGray(img, 0, 0, 255, reason: 'Y0 在第 1 字节');
      expectGray(img, 1, 0, 128, reason: 'Y1 在第 3 字节');
    });

    test('YUY2 4x2 逐宏像素推进，亮度不串行', () {
      final Uint8List bytes = bytesOf(<int>[
        10, 128, 20, 128, 30, 128, 40, 128, // 第 0 行两个宏像素
        50, 128, 60, 128, 70, 128, 80, 128, // 第 1 行
      ]);
      final RgbaImage img =
          decoder.decodeWith(bytes, lumaOnly(4, 2, YuvFormat.yuy2));
      const List<int> expected = <int>[10, 20, 30, 40, 50, 60, 70, 80];
      for (int i = 0; i < expected.length; i++) {
        expectGray(img, i % 4, i ~/ 4, expected[i]);
      }
    });
  });

  group('奇数尺寸：色度平面向上取整', () {
    test('3x1 I422 需要 7 字节（向下取整会算成 5）', () {
      // 色度宽 = ceil(3/2) = 2。第 3 列必须能取到色度第 1 列，
      // 否则要么越界，要么读到 V 平面的头上。
      final Uint8List bytes = bytesOf(<int>[
        128, 128, 128, // Y
        128, 255, // U（2 列）
        128, 128, // V（2 列）
      ]);
      expect(YuvFormat.i422.frameSize(3, 1), 7);

      final RgbaImage img =
          decoder.decodeWith(bytes, lumaOnly(3, 1, YuvFormat.i422));
      expectGray(img, 0, 0, 128);
      expectGray(img, 1, 0, 128, reason: 'x=1 仍落在色度第 0 列');
      expectPixel(img, 2, 0, <int>[128, 84, 255, 255],
          reason: 'x=2 落在色度第 1 列，U=255');
    });

    test('3x3 I420 需要 17 字节，九个像素各自的 Y 都对', () {
      expect(YuvFormat.i420.frameSize(3, 3), 17); // 9 + 2*2*2
      final Uint8List bytes = bytesOf(<int>[
        1, 2, 3, 4, 5, 6, 7, 8, 9, // Y 3x3
        128, 128, 128, 128, // U 2x2
        128, 128, 128, 128, // V 2x2
      ]);
      final RgbaImage img =
          decoder.decodeWith(bytes, lumaOnly(3, 3, YuvFormat.i420));
      for (int i = 0; i < 9; i++) {
        expectGray(img, i % 3, i ~/ 3, i + 1);
      }
    });

    test('chromaWidth / chromaHeight 是向上取整', () {
      expect(YuvFormat.i420.chromaWidth(5), 3);
      expect(YuvFormat.i420.chromaHeight(3), 2);
      expect(YuvFormat.i420.chromaWidth(4), 2);
      expect(YuvFormat.i422.chromaHeight(3), 3, reason: 'subY=1 不抽样');
      expect(YuvFormat.i444.chromaWidth(5), 5);
      expect(YuvFormat.i444.chromaHeight(5), 5);
    });
  });

  group('色彩矩阵 × 取值范围', () {
    /// 一份 2x2 的 I420，Y 全 128，U=255，V=128。
    /// 换矩阵时只有 G 通道会明显变化，正好当判别器。
    final Uint8List blueish =
        bytesOf(<int>[128, 128, 128, 128, 255, 128]);

    RgbaImage decodeAs(YuvMatrix m, YuvRange r) => decoder.decodeWith(
          blueish,
          YuvOptions(width: 2, height: 2, matrix: m, range: r),
        );

    test('三种矩阵在 G 通道上互不相同', () {
      // G 系数：BT.601 0.3441 / BT.709 0.1873 / BT.2020 0.1646，
      // 乘 cb=127 之后差距足够大，不会被四舍五入吃掉。
      expect(decodeAs(YuvMatrix.bt601, YuvRange.full).channelsAt(0, 0)[1], 84);
      expect(decodeAs(YuvMatrix.bt709, YuvRange.full).channelsAt(0, 0)[1], 104);
      expect(decodeAs(YuvMatrix.bt2020, YuvRange.full).channelsAt(0, 0)[1], 107);
    });

    test('limited 范围下 Y=16 是黑，Y=235 是白', () {
      final Uint8List black =
          bytesOf(<int>[16, 16, 16, 16, 128, 128]);
      final Uint8List white =
          bytesOf(<int>[235, 235, 235, 235, 128, 128]);
      expectSolidColor(
        decoder.decodeWith(black, const YuvOptions(width: 2, height: 2)),
        <int>[0, 0, 0, 255],
      );
      expectSolidColor(
        decoder.decodeWith(white, const YuvOptions(width: 2, height: 2)),
        <int>[255, 255, 255, 255],
      );
    });

    test('limited 范围把 16 以下 / 235 以上的超范围值夹住', () {
      // 广播信号里 Y 可以落在 16~235 之外（headroom / footroom），
      // 解码器必须夹住而不是溢出成花屏。
      final Uint8List below = bytesOf(<int>[0, 0, 0, 0, 128, 128]);
      final Uint8List above =
          bytesOf(<int>[255, 255, 255, 255, 128, 128]);
      expectSolidColor(
        decoder.decodeWith(below, const YuvOptions(width: 2, height: 2)),
        <int>[0, 0, 0, 255],
      );
      expectSolidColor(
        decoder.decodeWith(above, const YuvOptions(width: 2, height: 2)),
        <int>[255, 255, 255, 255],
      );
    });

    test('full 范围下 Y=0 是黑、Y=255 是白（不做 16 偏移）', () {
      final Uint8List black = bytesOf(<int>[0, 0, 0, 0, 128, 128]);
      final Uint8List white =
          bytesOf(<int>[255, 255, 255, 255, 128, 128]);
      expectSolidColor(
        decoder.decodeWith(black, lumaOnly(2, 2, YuvFormat.i420)),
        <int>[0, 0, 0, 255],
      );
      expectSolidColor(
        decoder.decodeWith(white, lumaOnly(2, 2, YuvFormat.i420)),
        <int>[255, 255, 255, 255],
      );
    });

    test('同一份字节，limited 与 full 解出不同的灰阶', () {
      // Y=126：full 下就是 126；limited 下要拉伸成 (126-16)*255/219 ≈ 128。
      final Uint8List gray =
          bytesOf(<int>[126, 126, 126, 126, 128, 128]);
      expectSolidColor(
        decoder.decodeWith(gray, lumaOnly(2, 2, YuvFormat.i420)),
        <int>[126, 126, 126, 255],
      );
      expectSolidColor(
        decoder.decodeWith(gray, const YuvOptions(width: 2, height: 2)),
        <int>[128, 128, 128, 255],
      );
    });

    test('合法 YUV 可以落在 RGB 色域外，必须夹住', () {
      // Y=235 U=V=16 在 limited BT.601 下算出 G≈390 —— 每个通道都得夹。
      // 这不是防御性代码，是数学上必然会发生的情况。
      final Uint8List outOfGamut =
          bytesOf(<int>[235, 235, 235, 235, 16, 16]);
      expectSolidColor(
        decoder.decodeWith(outOfGamut, const YuvOptions(width: 2, height: 2)),
        <int>[76, 255, 29, 255],
      );
    });

    test('full 范围的两个极端都会触发夹取', () {
      final Uint8List lo = bytesOf(<int>[0, 0, 0, 0, 0, 0]);
      final Uint8List hi =
          bytesOf(<int>[255, 255, 255, 255, 255, 255]);
      expectSolidColor(
        decoder.decodeWith(lo, lumaOnly(2, 2, YuvFormat.i420)),
        <int>[0, 135, 0, 255],
      );
      expectSolidColor(
        decoder.decodeWith(hi, lumaOnly(2, 2, YuvFormat.i420)),
        <int>[255, 121, 255, 255],
      );
    });
  });

  group('帧大小与多帧', () {
    test('九种格式在 4x2 下的帧大小', () {
      // 抽样比一样的格式帧大小必然相同 —— 它们的差别只在字节摆放。
      expect(YuvFormat.i420.frameSize(4, 2), 12);
      expect(YuvFormat.yv12.frameSize(4, 2), 12);
      expect(YuvFormat.nv12.frameSize(4, 2), 12);
      expect(YuvFormat.nv21.frameSize(4, 2), 12);
      expect(YuvFormat.i422.frameSize(4, 2), 16);
      expect(YuvFormat.i444.frameSize(4, 2), 24);
      expect(YuvFormat.yuy2.frameSize(4, 2), 16);
      expect(YuvFormat.yvyu.frameSize(4, 2), 16);
      expect(YuvFormat.uyvy.frameSize(4, 2), 16);
    });

    test('planeCount 按布局分类', () {
      expect(YuvFormat.i420.planeCount, 3);
      expect(YuvFormat.i444.planeCount, 3);
      expect(YuvFormat.nv12.planeCount, 2);
      expect(YuvFormat.nv21.planeCount, 2);
      expect(YuvFormat.yuy2.planeCount, 1);
      expect(YuvFormat.uyvy.planeCount, 1);
    });

    // ffmpeg 导出的 .yuv 是所有帧首尾相接、没有任何分隔符的，
    // 所以取第 N 帧只能靠「帧大小 × N」算偏移。
    final Uint8List twoFrames = bytesOf(<int>[
      10, 10, 10, 10, 128, 128, // 第 0 帧
      200, 200, 200, 200, 128, 128, // 第 1 帧
    ]);

    test('frameIndex 定位到对应的帧', () {
      expectSolidColor(
        decoder.decodeWith(twoFrames, lumaOnly(2, 2, YuvFormat.i420)),
        <int>[10, 10, 10, 255],
      );
      expectSolidColor(
        decoder.decodeWith(
          twoFrames,
          const YuvOptions(
              width: 2, height: 2, range: YuvRange.full, frameIndex: 1),
        ),
        <int>[200, 200, 200, 255],
      );
    });

    test('帧号越界时报出文件里到底有几帧', () {
      expect(
        () => decoder.decodeWith(
          twoFrames,
          const YuvOptions(width: 2, height: 2, frameIndex: 2),
        ),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          allOf(contains('只有 2 帧'), contains('取不到第 2 帧')),
        )),
      );
    });

    test('帧号为负直接拒绝', () {
      expect(
        () => decoder.decodeWith(
          twoFrames,
          const YuvOptions(width: 2, height: 2, frameIndex: -1),
        ),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('帧号不能为负'),
        )),
      );
    });

    test('frameCountIn 数出完整帧数，不算残帧', () {
      const YuvOptions o = YuvOptions(width: 2, height: 2);
      expect(o.frameSize, 6);
      expect(o.frameCountIn(12), 2);
      expect(o.frameCountIn(13), 2, reason: '多出的 1 字节不构成一帧');
      expect(o.frameCountIn(5), 0);
    });
  });

  group('参数错配：给出可操作的提示', () {
    test('字节数对不上时反推出正确的高度', () {
      // 这是裸 YUV 最常见的坑：尺寸猜错但字节数够的话，解出来是一张
      // 斜纹图**而且不报错**。所以字节数不够时要顺便把正确尺寸算出来。
      final Uint8List bytes = bytesOf(List<int>.filled(12, 128));
      expect(
        () => decoder.decodeWith(
          bytes,
          const YuvOptions(width: 4, height: 3),
        ),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          allOf(
            contains('每帧需 20 字节'),
            contains('文件共 12 字节'),
            contains('高度应是 2'),
          ),
        )),
      );
    });

    test('反推不出整数高度时报还差多少字节', () {
      // 13 字节：h=2 要 12、h=3 要 20，没有一个高度能刚好对上。
      final Uint8List bytes = bytesOf(List<int>.filled(13, 128));
      expect(
        () => decoder.decodeWith(
          bytes,
          const YuvOptions(width: 4, height: 3),
        ),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('还差 7 字节'),
        )),
      );
    });

    test('打包格式拒绝奇数宽度', () {
      // 一个宏像素装两个像素，宽度是奇数的话最后一个像素凑不出宏像素。
      expect(
        () => decoder.decodeWith(
          bytesOf(List<int>.filled(16, 128)),
          const YuvOptions(width: 3, height: 2, format: YuvFormat.yuy2),
        ),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          allOf(contains('YUY2'), contains('宽度必须是偶数'), contains('实际 3')),
        )),
      );
      // 平面格式的奇数宽度是合法的。
      expect(
        () => decoder.decodeWith(
          bytesOf(List<int>.filled(7, 128)),
          const YuvOptions(width: 3, height: 1, format: YuvFormat.i422),
        ),
        returnsNormally,
      );
    });

    test('宽或高为 0 时提示缺参数', () {
      for (final YuvOptions o in <YuvOptions>[
        YuvOptions.empty,
        const YuvOptions(width: 0, height: 2),
        const YuvOptions(width: 2, height: 0),
      ]) {
        expect(
          () => decoder.decodeWith(bytesOf(List<int>.filled(6, 128)), o),
          throwsA(isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('缺少必需参数'),
          )),
          reason: '$o',
        );
      }
    });

    test('尺寸超上限在算字节数之前就被拦住', () {
      // 先查尺寸再算字节数，否则 70000x70000 的乘法会先把内存吃光。
      expect(
        () => decoder.decodeWith(
          bytesOf(List<int>.filled(6, 128)),
          const YuvOptions(width: 70000, height: 1),
        ),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('超出上限'),
        )),
      );
    });
  });

  group('YuvOptions', () {
    test('empty 不完整，填上宽高就完整', () {
      expect(YuvOptions.empty.isComplete, isFalse);
      expect(const YuvOptions(width: 2, height: 2).isComplete, isTrue);
      expect(const YuvOptions(width: 2, height: 0).isComplete, isFalse);
    });

    test('byteOffset = 帧大小 × 帧号', () {
      const YuvOptions o =
          YuvOptions(width: 4, height: 2, frameIndex: 2);
      expect(o.frameSize, 12);
      expect(o.byteOffset, 24);
      expect(const YuvOptions(width: 4, height: 2).byteOffset, 0);
    });

    test('copyWith 只改指定字段', () {
      const YuvOptions base = YuvOptions(width: 4, height: 2);
      final YuvOptions changed =
          base.copyWith(format: YuvFormat.nv21, frameIndex: 3);
      expect(changed.width, 4);
      expect(changed.height, 2);
      expect(changed.format, YuvFormat.nv21);
      expect(changed.frameIndex, 3);
      expect(changed.matrix, YuvMatrix.bt601, reason: '没指定就保持原值');
      expect(changed.range, YuvRange.limited);
    });

    test('== 与 hashCode 按值比较', () {
      const YuvOptions a = YuvOptions(width: 4, height: 2);
      const YuvOptions b = YuvOptions(width: 4, height: 2);
      const YuvOptions c =
          YuvOptions(width: 4, height: 2, format: YuvFormat.nv12);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a, isNot(c));
    });
  });

  group('YuvColorConverter：系数对照教科书', () {
    /// 这一组是整个 YUV 解码器里最容易悄悄算错的地方 —— 系数错了图仍然
    /// 能出来，只是颜色偏一点，肉眼很难发现。所以直接跟教科书常数对。
    void expectCoefficients(
      YuvMatrix m,
      YuvRange r, {
      required double yScale,
      required int yOffset,
      required double rV,
      required double gU,
      required double gV,
      required double bU,
    }) {
      final YuvColorConverter c = YuvColorConverter(m, r);
      expect(c.yScale, closeTo(yScale, 5e-4), reason: '$m $r yScale');
      expect(c.yOffset, yOffset, reason: '$m $r yOffset');
      expect(c.rV, closeTo(rV, 5e-4), reason: '$m $r R←V');
      expect(c.gU, closeTo(gU, 5e-4), reason: '$m $r G←U');
      expect(c.gV, closeTo(gV, 5e-4), reason: '$m $r G←V');
      expect(c.bU, closeTo(bU, 5e-4), reason: '$m $r B←U');
    }

    test('BT.601 limited（最常被引用的那组数）', () {
      expectCoefficients(
        YuvMatrix.bt601,
        YuvRange.limited,
        yScale: 1.1644,
        yOffset: 16,
        rV: 1.5960,
        gU: 0.3918,
        gV: 0.8130,
        bU: 2.0172,
      );
    });

    test('BT.601 full（JPEG 用的就是这组）', () {
      expectCoefficients(
        YuvMatrix.bt601,
        YuvRange.full,
        yScale: 1.0,
        yOffset: 0,
        rV: 1.4020,
        gU: 0.3441,
        gV: 0.7141,
        bU: 1.7720,
      );
    });

    test('BT.709 limited', () {
      expectCoefficients(
        YuvMatrix.bt709,
        YuvRange.limited,
        yScale: 1.1644,
        yOffset: 16,
        rV: 1.7927,
        gU: 0.2132,
        gV: 0.5329,
        bU: 2.1124,
      );
    });

    test('BT.709 full', () {
      expectCoefficients(
        YuvMatrix.bt709,
        YuvRange.full,
        yScale: 1.0,
        yOffset: 0,
        rV: 1.5748,
        gU: 0.1873,
        gV: 0.4681,
        bU: 1.8556,
      );
    });

    test('BT.2020 full', () {
      expectCoefficients(
        YuvMatrix.bt2020,
        YuvRange.full,
        yScale: 1.0,
        yOffset: 0,
        rV: 1.4746,
        gU: 0.1646,
        gV: 0.5714,
        bU: 1.8814,
      );
    });

    test('kg 由 kr / kb 推出，三者之和为 1', () {
      for (final YuvMatrix m in YuvMatrix.values) {
        expect(m.kr + m.kg + m.kb, closeTo(1.0, 1e-12), reason: '$m');
      }
      expect(YuvMatrix.bt601.kg, closeTo(0.587, 1e-12));
      expect(YuvMatrix.bt709.kg, closeTo(0.7152, 1e-12));
      expect(YuvMatrix.bt2020.kg, closeTo(0.678, 1e-12));
    });

    test('limited 的系数正好是 full 的系数乘上拉伸比', () {
      // 这条是结构性断言：limited 不是另一套魔法数字，而是 full 乘
      // 255/219（亮度）与 255/224（色度）。
      for (final YuvMatrix m in YuvMatrix.values) {
        final YuvColorConverter full = YuvColorConverter(m, YuvRange.full);
        final YuvColorConverter lim = YuvColorConverter(m, YuvRange.limited);
        const double chroma = 255.0 / 224.0;
        expect(lim.yScale, closeTo(255.0 / 219.0, 1e-12), reason: '$m');
        expect(lim.rV, closeTo(full.rV * chroma, 1e-12), reason: '$m R←V');
        expect(lim.gU, closeTo(full.gU * chroma, 1e-12), reason: '$m G←U');
        expect(lim.gV, closeTo(full.gV * chroma, 1e-12), reason: '$m G←V');
        expect(lim.bU, closeTo(full.bU * chroma, 1e-12), reason: '$m B←U');
      }
    });

    test('describeCoefficients 的字符串带符号、留四位小数', () {
      final Map<String, String> d =
          YuvColorConverter(YuvMatrix.bt601, YuvRange.limited)
              .describeCoefficients();
      expect(d['Y 缩放'], '1.1644');
      expect(d['Y 偏移'], '16');
      expect(d['R ← V'], '1.5960');
      expect(d['G ← U'], '-0.3918', reason: 'G 的两项是减号');
      expect(d['G ← V'], '-0.8130');
      expect(d['B ← U'], '2.0172');
    });

    test('convert 写满四个通道且 A 恒为 255', () {
      final List<int> out = List<int>.filled(8, 0);
      YuvColorConverter(YuvMatrix.bt601, YuvRange.full)
          .convert(200, 128, 128, out, 4);
      expect(out.sublist(0, 4), <int>[0, 0, 0, 0], reason: '不越界写前一个像素');
      expect(out.sublist(4), <int>[200, 200, 200, 255]);
    });
  });

  group('元数据', () {
    test('I420 的元数据把抽样、矩阵、系数都写清楚', () {
      final RgbaImage img = decoder.decodeWith(
        bytesOf(<int>[128, 128, 128, 128, 128, 128]),
        const YuvOptions(width: 2, height: 2),
      );
      final ImageMetadata m = img.metadata;

      expect(m.format, 'YUV');
      expect(m.variant, 'I420');
      expect(m.bitDepth, 8);
      expect(m.channels, 3);
      expect(m.colorSpace, 'BT601 YCbCr');
      expect(m.compression, contains('裸采样'));
      expect(m.isLossless, isFalse, reason: '4:2:0 有抽样损失');

      expect(m.extra['平面布局'], '三平面分离');
      expect(m.extra['色度抽样'], '4:2:0');
      expect(m.extra['取值范围'], contains('limited'));
      expect(m.extra['每帧字节数'], 6);
      expect(m.extra['色度平面尺寸'], '1x1');
      expect(m.extra['色度上采样'], '最近邻');
      expect(m.extra['别名'], 'YU12');
      expect(m.extra['转换系数'], contains('R ← V=1.5960'));
      expect(m.extra.containsKey('帧'), isFalse, reason: '单帧不显示帧号');
    });

    test('只有 4:4:4 标记为无损', () {
      final RgbaImage i444 = decoder.decodeWith(
        bytesOf(List<int>.filled(12, 128)),
        const YuvOptions(width: 2, height: 2, format: YuvFormat.i444),
      );
      expect(i444.metadata.isLossless, isTrue);

      final RgbaImage i422 = decoder.decodeWith(
        bytesOf(List<int>.filled(8, 128)),
        const YuvOptions(width: 2, height: 2, format: YuvFormat.i422),
      );
      expect(i422.metadata.isLossless, isFalse, reason: '4:2:2 水平抽样了');
    });

    test('多帧时标出第几帧', () {
      final RgbaImage img = decoder.decodeWith(
        bytesOf(List<int>.filled(18, 128)),
        const YuvOptions(width: 2, height: 2, frameIndex: 1),
      );
      expect(img.metadata.extra['帧'], '第 2 / 3 帧');
    });

    test('没有别名的格式不显示别名字段', () {
      final RgbaImage img = decoder.decodeWith(
        bytesOf(<int>[128, 128, 128, 128, 128, 128]),
        const YuvOptions(width: 2, height: 2, format: YuvFormat.yv12),
      );
      expect(img.metadata.extra.containsKey('别名'), isFalse);
    });
  });

  group('文档里的字节级实例', () {
    /// 这一组把 `docs/formats/yuv.md` 的十六进制实例钉住。
    /// 文档里的每个数字都在这里被断言，改代码改坏了文档也会跟着红。
    ///
    /// 4x2 I420，左半红右半绿，BT.601 full range：
    ///   00  4C 4C 96 96   Y 第 0 行（红 76 / 绿 150）
    ///   04  4C 4C 96 96   Y 第 1 行
    ///   08  55 2C         U 平面 2x1（红 85 / 绿 44）
    ///   0A  FF 15         V 平面 2x1（红 255 / 绿 21）
    final Uint8List sample = bytesOf(<int>[
      0x4C, 0x4C, 0x96, 0x96, //
      0x4C, 0x4C, 0x96, 0x96, //
      0x55, 0x2C, //
      0xFF, 0x15, //
    ]);

    test('按 I420 解出左红右绿', () {
      final RgbaImage img =
          decoder.decodeWith(sample, lumaOnly(4, 2, YuvFormat.i420));
      expect(sample.length, 12, reason: '文档说共 12 字节');

      for (int y = 0; y < 2; y++) {
        // 红：R = 76 + 1.402*127   = 254.05 → 254（不是 255）
        //     B = 76 - 1.772*43    = -0.20  → 0（夹住）
        expectPixel(img, 0, y, <int>[254, 0, 0, 255], reason: '红块');
        expectPixel(img, 1, y, <int>[254, 0, 0, 255], reason: '红块共用色度');
        // 绿：B = 150 - 1.772*84 = 1.15 → 1（不是 0）
        expectPixel(img, 2, y, <int>[0, 255, 1, 255], reason: '绿块');
        expectPixel(img, 3, y, <int>[0, 255, 1, 255]);
      }
    });

    test('RGB → YUV → RGB 不是恒等变换', () {
      // 上一个用例里红回来是 254 而不是 255、绿的 B 回来是 1 而不是 0。
      // 这不是 bug，是 8 bit 量化 + 系数是无理数的必然结果：
      // 纯红的 Cr 算出来 255.0 已经贴着上界，纯绿的 Cb/Cr 都落在小数上。
      // 教学上值得强调 —— YUV 即使不抽样（I444）也不是无损的。
      final Uint8List i444 = bytesOf(<int>[
        0x4C, 0x96, // Y：红 76、绿 150
        0x55, 0x2C, // U 逐像素
        0xFF, 0x15, // V 逐像素
      ]);
      final RgbaImage img =
          decoder.decodeWith(i444, lumaOnly(2, 1, YuvFormat.i444));
      expectPixel(img, 0, 0, <int>[254, 0, 0, 255], reason: '纯红回不到 255');
      expectPixel(img, 1, 0, <int>[0, 255, 1, 255], reason: '纯绿的 B 回不到 0');
      // 但元数据仍标 isLossless=true —— 那说的是「没有抽样损失」，
      // 不是「往返无误差」。两者是不同的东西。
      expect(img.metadata.isLossless, isTrue);
    });

    test('同一份字节按 NV12 解出来第一块是绿的', () {
      // 色度 55 2C FF 15 被当成交织的 (85,44) 与 (255,21)，
      // 第一个像素的 cr 从 +127 变成 -84 —— 红变绿。
      final RgbaImage img =
          decoder.decodeWith(sample, lumaOnly(4, 2, YuvFormat.nv12));
      expectPixel(img, 0, 0, <int>[0, 151, 0, 255],
          reason: '一个参数选错，整张图的颜色全变');
    });

    test('编码侧：纯红纯绿算出来正是这些字节', () {
      // 反向验证文档里的 4C / 96 / 55 / 2C / FF / 15 不是编出来的。
      // Y  = kr*R + kg*G + kb*B
      // Cb = (B-Y)/(2(1-kb)) + 128,  Cr = (R-Y)/(2(1-kr)) + 128
      const double kr = 0.299;
      const double kb = 0.114;
      const double kg = 1 - kr - kb;

      List<int> encode(int r, int g, int b) {
        final double y = kr * r + kg * g + kb * b;
        final double cb = (b - y) / (2 * (1 - kb)) + 128;
        final double cr = (r - y) / (2 * (1 - kr)) + 128;
        return <int>[
          y.round(),
          cb.round().clamp(0, 255),
          cr.round().clamp(0, 255),
        ];
      }

      expect(encode(255, 0, 0), <int>[0x4C, 0x55, 0xFF], reason: '纯红');
      expect(encode(0, 255, 0), <int>[0x96, 0x2C, 0x15], reason: '纯绿');
    });
  });

  group('枚举本身', () {
    test('九种格式的布局分类与抽样标签', () {
      expect(YuvFormat.values.length, 9);
      for (final YuvFormat f in YuvFormat.values) {
        expect(f.label, isNotEmpty);
        expect(f.samplingLabel, matches(RegExp(r'^4:[024]:[024]$')));
        expect(f.subX, anyOf(1, 2));
        expect(f.subY, anyOf(1, 2));
        // 4:4:4 才允许 subX==1，其余格式水平都抽样了。
        expect(f.subX == 1, f.samplingLabel == '4:4:4', reason: '$f');
      }
    });

    test('配对格式只差 uFirst', () {
      expect(YuvFormat.i420.uFirst, isTrue);
      expect(YuvFormat.yv12.uFirst, isFalse);
      expect(YuvFormat.nv12.uFirst, isTrue);
      expect(YuvFormat.nv21.uFirst, isFalse);
      expect(YuvFormat.yuy2.uFirst, isTrue);
      expect(YuvFormat.yvyu.uFirst, isFalse);
      // 除了 uFirst，配对的两个格式其余参数完全一致。
      expect(YuvFormat.i420.subX, YuvFormat.yv12.subX);
      expect(YuvFormat.i420.subY, YuvFormat.yv12.subY);
      expect(YuvFormat.i420.layout, YuvFormat.yv12.layout);
    });

    test('lumaFirst 区分 YUY2 系与 UYVY', () {
      expect(YuvFormat.yuy2.lumaFirst, isTrue);
      expect(YuvFormat.yvyu.lumaFirst, isTrue);
      expect(YuvFormat.uyvy.lumaFirst, isFalse);
    });

    test('YuvRange.isFull', () {
      expect(YuvRange.full.isFull, isTrue);
      expect(YuvRange.limited.isFull, isFalse);
      expect(YuvRange.limited.description, contains('16'));
    });

    test('YuvLayout 的说明文字非空', () {
      for (final YuvLayout l in YuvLayout.values) {
        expect(l.description, isNotEmpty);
      }
    });

    test('validateFor 只管打包格式的宽度', () {
      expect(() => YuvFormat.yuy2.validateFor(3, 2), throwsA(isA<ImageDecodeException>()));
      expect(() => YuvFormat.yuy2.validateFor(4, 3), returnsNormally);
      expect(() => YuvFormat.i420.validateFor(3, 3), returnsNormally,
          reason: '平面格式的奇数宽高都合法');
    });
  });
}
