import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_decoder.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_header.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_types.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

import '../support/bmp_builders.dart';
import '../support/pixel_matchers.dart';

const BmpDecoder decoder = BmpDecoder();

/// 在字节流的指定位置改写若干字节，用来构造畸形文件。
///
/// 比手敲一整个坏文件可读得多：一眼能看出「这个文件唯一的问题是 X」。
Uint8List patch(Uint8List src, int offset, List<int> replacement) {
  final Uint8List out = Uint8List.fromList(src);
  for (int i = 0; i < replacement.length; i++) {
    out[offset + i] = replacement[i];
  }
  return out;
}

/// 造一个尺寸/位深指定、像素全零的合法 BMP 并只取它的头部。
///
/// 专门给「只想验证头部字段」的测试用，省掉每次都算一遍像素数据。
BmpHeader headerOf(int width, int height, int bpp) {
  final int absHeight = height < 0 ? -height : height;
  final Uint8List bmp = buildInfoBmp(
    width: width,
    height: height,
    bpp: bpp,
    pixelData: List<int>.filled(bmpRowStride(width, bpp) * absHeight, 0),
  );
  return BmpHeader.parse(bmp);
}

void main() {
  group('canDecode 魔数识别', () {
    test('BM 开头且长度足够 → true', () {
      final Uint8List bmp = buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      );
      expect(decoder.canDecode(bmp), isTrue);
    });

    test('不是 BM 开头 → false', () {
      final Uint8List notBmp =
          Uint8List.fromList(List<int>.filled(20, 0x41));
      expect(decoder.canDecode(notBmp), isFalse);
    });

    test('长度不足 14 字节 → false', () {
      final Uint8List tooShort = Uint8List.fromList(<int>[0x42, 0x4D]);
      expect(decoder.canDecode(tooShort), isFalse);
    });

    test('name 与 extensions', () {
      expect(decoder.name, 'BMP');
      expect(decoder.extensions, containsAll(<String>['bmp', 'dib']));
    });
  });

  group('24bpp 与行方向、行对齐', () {
    test('2x2 自底向上：数据第一行是图像最后一行', () {
      // BMP 默认自底向上存储，这是最反直觉的一条规则。
      final Uint8List bmp = buildInfoBmp(
        width: 2,
        height: 2,
        bpp: 24,
        // 字节顺序是 BGR，不是 RGB
        pixelData: padRows(<List<int>>[
          <int>[0, 0, 255, 0, 255, 0], // 存储行 0：红、绿
          <int>[255, 0, 0, 255, 255, 255], // 存储行 1：蓝、白
        ], bmpRowStride(2, 24)),
      );

      final RgbaImage img = decoder.decode(bmp);
      expect(img.width, 2);
      expect(img.height, 2);
      // 存储行 1 翻到了顶部
      expectPixel(img, 0, 0, <int>[0, 0, 255, 255], reason: '左上应为蓝');
      expectPixel(img, 1, 0, <int>[255, 255, 255, 255], reason: '右上应为白');
      expectPixel(img, 0, 1, <int>[255, 0, 0, 255], reason: '左下应为红');
      expectPixel(img, 1, 1, <int>[0, 255, 0, 255], reason: '右下应为绿');
    });

    test('width=3 的 24bpp：行按 4 字节对齐，9 字节数据占 12 字节', () {
      // 这是 BMP 头号 bug：用 width*3 当行距，第二行开始整片错位。
      expect(bmpRowStride(3, 24), 12);

      final Uint8List bmp = buildInfoBmp(
        width: 3,
        height: 2,
        bpp: 24,
        pixelData: padRows(<List<int>>[
          <int>[30, 20, 10, 60, 50, 40, 90, 80, 70],
          <int>[120, 110, 100, 150, 140, 130, 180, 170, 160],
        ], 12),
      );

      final RgbaImage img = decoder.decode(bmp);
      // 自底向上：存储行 1 在顶部。若行距按 9 算，这里会读到填充字节变成黑色。
      expectPixel(img, 0, 0, <int>[100, 110, 120, 255]);
      expectPixel(img, 1, 0, <int>[130, 140, 150, 255]);
      expectPixel(img, 2, 0, <int>[160, 170, 180, 255]);
      expectPixel(img, 0, 1, <int>[10, 20, 30, 255]);
      expectPixel(img, 2, 1, <int>[70, 80, 90, 255]);
      expect(img.metadata.extra['行对齐后字节数'], 12);
    });

    test('负 height 表示自顶向下，行序不翻转', () {
      final List<int> pixels = padRows(<List<int>>[
        <int>[0, 0, 255, 0, 255, 0], // 存储行 0：红、绿
        <int>[255, 0, 0, 255, 255, 255], // 存储行 1：蓝、白
      ], bmpRowStride(2, 24));

      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: -2, // 负号是唯一的差别
        bpp: 24,
        pixelData: pixels,
      ));

      expect(img.height, 2, reason: 'height 应取绝对值');
      expectPixel(img, 0, 0, <int>[255, 0, 0, 255], reason: '存储行 0 留在顶部');
      expectPixel(img, 0, 1, <int>[0, 0, 255, 255]);
      expect(img.metadata.extra['行方向'], '自顶向下');
    });

    test('自底向上时元数据标明是 BMP 默认', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      ));
      expect(img.metadata.extra['行方向'], '自底向上（BMP 默认）');
    });

    test('1x1 最小图', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[10, 20, 30, 0], // BGR + 1 字节填充
      ));
      expect(img.pixels.length, 4);
      expectPixel(img, 0, 0, <int>[30, 20, 10, 255]);
    });
  });

  group('索引色：1 / 2 / 4 / 8 bpp', () {
    test('1bpp：位在字节内高位在前', () {
      // 0xA0 = 1010_0000 → 白黑白黑 + 四个黑
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 8,
        height: 1,
        bpp: 1,
        palette: testPalette2,
        pixelData: <int>[0xA0, 0, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[255, 255, 255, 255], reason: 'bit7');
      expectPixel(img, 1, 0, <int>[0, 0, 0, 255], reason: 'bit6');
      expectPixel(img, 2, 0, <int>[255, 255, 255, 255], reason: 'bit5');
      expectPixel(img, 3, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 7, 0, <int>[0, 0, 0, 255]);
    });

    test('1bpp width=9：像素跨越字节边界', () {
      // 第 9 个像素落在第二字节的最高位。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 9,
        height: 1,
        bpp: 1,
        palette: testPalette2,
        pixelData: <int>[0x00, 0x80, 0, 0],
      ));

      expectPixel(img, 7, 0, <int>[0, 0, 0, 255], reason: '第一字节末位');
      expectPixel(img, 8, 0, <int>[255, 255, 255, 255],
          reason: '第二字节最高位');
    });

    test('2bpp：每字节四个像素', () {
      // 0x1B = 00 01 10 11 → 黑红绿蓝
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 4,
        height: 1,
        bpp: 2,
        palette: testPalette4,
        pixelData: <int>[0x1B, 0, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 2, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 3, 0, <int>[0, 0, 255, 255]);
    });

    test('4bpp：半字节索引 + 行对齐 + 自底向上', () {
      expect(bmpRowStride(3, 4), 4, reason: '2 字节数据补到 4');

      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 3,
        height: 2,
        bpp: 4,
        palette: testPalette4,
        pixelData: <int>[
          0x12, 0x30, 0, 0, // 存储行 0：索引 1,2,3
          0x30, 0x10, 0, 0, // 存储行 1：索引 3,0,1
        ],
      ));

      // 存储行 1 翻到顶部
      expectPixel(img, 0, 0, <int>[0, 0, 255, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 2, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 0, 1, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 1, <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 1, <int>[0, 0, 255, 255]);
    });

    test('8bpp：一字节一个索引', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 3,
        height: 1,
        bpp: 8,
        palette: testPalette4,
        pixelData: <int>[3, 2, 1, 0],
      ));

      expectPixel(img, 0, 0, <int>[0, 0, 255, 255]);
      expectPixel(img, 1, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 0, <int>[255, 0, 0, 255]);
      expect(img.metadata.extra['调色板项数'], 4);
      expect(img.metadata.colorSpace, '调色板索引');
    });

    test('越界索引填黑并计数，而不是拒绝整个文件', () {
      // biClrUsed 声明 2 项，但像素里出现了索引 5。现实中确有这种文件。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 8,
        palette: testPalette2,
        pixelData: <int>[1, 5, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[255, 255, 255, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 0, 255], reason: '越界索引填不透明黑');
      expect(img.metadata.extra['越界调色板索引'], '1 个像素（已填黑）');
    });

    test('调色板项数正常时不报越界', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 8,
        palette: testPalette4,
        pixelData: <int>[0, 3, 0, 0],
      ));
      expect(img.metadata.extra.containsKey('越界调色板索引'), isFalse);
    });
  });

  group('16bpp 通道掩码', () {
    test('默认 RGB555（BI_RGB 不声明掩码时）', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 16,
        // 0x7C00 = 纯红；0x7FFF = 白。小端存放。
        pixelData: <int>[0x00, 0x7C, 0xFF, 0x7F],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[255, 255, 255, 255],
          reason: '5 位满值 31 必须映射到 255');
    });

    test('通道用比例缩放而非左移：5 位的 16 → 132 而不是 128', () {
      // 这是经典 bug。左移 3 位得 128，比例缩放得 (16*255+15)/31 = 132。
      // 更要紧的是满值 31：左移只能得 248，白色会发灰。
      const int raw = (16 << 10) | (31 << 5); // r=16, g=31, b=0
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 16,
        pixelData: <int>[raw & 0xFF, (raw >> 8) & 0xFF, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[132, 255, 0, 255]);
    });

    test('BI_BITFIELDS 声明 RGB565（掩码放在调色板区域）', () {
      // 40 字节头没有掩码字段，BI_BITFIELDS 时掩码借用调色板的位置。
      const int raw = (31 << 11) | (32 << 5); // r=31, g=32(6位), b=0
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 16,
        compression: 3,
        bitfieldMasks: <int>[0xF800, 0x07E0, 0x001F],
        pixelData: <int>[raw & 0xFF, (raw >> 8) & 0xFF, 0, 0],
      ));

      // 绿色 6 位：(32*255+31)/63 = 130
      expectPixel(img, 0, 0, <int>[255, 130, 0, 255]);
      expect(img.metadata.compression, '无（自定义通道掩码）');
      expect(img.metadata.extra['通道掩码'],
          'R=0xf800 G=0x7e0 B=0x1f A=0x0');
    });
  });

  group('16bpp 掩码顺序与行对齐', () {
    test('掩码可以任意顺序：BGR555 把红蓝对调', () {
      // 解码器必须真的按掩码算，不能假定「16bpp 就是 RGB555」。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 16,
        compression: 3,
        bitfieldMasks: <int>[0x001F, 0x03E0, 0x7C00],
        pixelData: <int>[0x1F, 0x00, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255],
          reason: '低 5 位声明为红');
    });

    test('4-4-4-4 掩码也能解（规范允许任意位宽）', () {
      // 0x0F00=R, 0x00F0=G, 0x000F=B。raw=0x0F0F → 红满、绿零、蓝满。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 16,
        compression: 3,
        bitfieldMasks: <int>[0x0F00, 0x00F0, 0x000F],
        pixelData: <int>[0x0F, 0x0F, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 255, 255],
          reason: '4 位满值 15 → 255');
    });

    test('width=3 的 16bpp：6 字节数据占 8 字节', () {
      expect(bmpRowStride(3, 16), 8);

      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 3,
        height: 2,
        bpp: 16,
        pixelData: padRows(<List<int>>[
          <int>[0x00, 0x7C, 0xE0, 0x03, 0x1F, 0x00], // 红绿蓝
          <int>[0xFF, 0x7F, 0xFF, 0x7F, 0xFF, 0x7F], // 白白白
        ], 8),
      ));

      // 自底向上：白行在顶部。行距算错会读到填充字节变黑。
      expectPixel(img, 0, 0, <int>[255, 255, 255, 255]);
      expectPixel(img, 2, 0, <int>[255, 255, 255, 255]);
      expectPixel(img, 0, 1, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 1, <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 1, <int>[0, 0, 255, 255]);
    });
  });

  group('32bpp 与 alpha 的启发式判断', () {
    test('BI_RGB 且第四字节全零 → 按不透明处理', () {
      // 规范说 32bpp BI_RGB 的第四字节是填充位。全零就该当填充，
      // 否则整张图会变成全透明 —— 这是个很常见的 bug。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 32,
        pixelData: <int>[0, 0, 255, 0, 255, 0, 0, 0], // BGRA：红、蓝
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 255, 255]);
      expect(img.hasTransparency, isFalse);
      expect(img.metadata.channels, 4);
    });

    test('BI_RGB 但第四字节有非零值 → 当真 alpha 用', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 32,
        pixelData: <int>[0, 0, 255, 128, 255, 0, 0, 255],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 128]);
      expectPixel(img, 1, 0, <int>[0, 0, 255, 255]);
      expect(img.hasTransparency, isTrue);
    });

    test('BI_ALPHABITFIELDS 显式声明 alpha，0 就是全透明', () {
      // 掩码显式声明时不走启发式：alpha=0 必须保留为透明。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 32,
        compression: 6,
        bitfieldMasks: <int>[
          0x00FF0000,
          0x0000FF00,
          0x000000FF,
          0xFF000000,
        ],
        pixelData: <int>[255, 0, 0, 0],
      ));

      expectPixel(img, 0, 0, <int>[0, 0, 255, 0]);
      expect(img.hasTransparency, isTrue);
      expect(img.metadata.compression, '无（自定义通道掩码含 alpha）');
    });

    test('32bpp 最高位 alpha 满值：位运算不能在 Web 上溢出', () {
      // alpha=255 时 raw 的最高位是 1。Dart 编译到 JS 后位运算按 32 位
      // 无符号处理，这条用例确保拼装与抽取都没有把它变成负数。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 32,
        pixelData: <int>[0x11, 0x22, 0x33, 0xFF],
      ));

      expectPixel(img, 0, 0, <int>[0x33, 0x22, 0x11, 255]);
    });
  });

  group('头部版本：CORE / V2 / V3 / V4 / V5', () {
    test('CORE(12)：宽高是 u16，调色板每项 3 字节', () {
      // OS/2 1.x 老格式。漏掉「调色板项 3 字节」会让颜色整体错位。
      final RgbaImage img = decoder.decode(buildCoreBmp(
        width: 2,
        height: 2,
        bpp: 4,
        palette: testPalette4,
        pixelData: <int>[
          0x12, 0, 0, 0, // 存储行 0：索引 1,2
          0x30, 0, 0, 0, // 存储行 1：索引 3,0
        ],
      ));

      expectPixel(img, 0, 0, <int>[0, 0, 255, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 0, 1, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 1, <int>[0, 255, 0, 255]);
      expect(img.metadata.variant, 'BITMAPCOREHEADER (OS/2 1.x)');
    });

    test('CORE(12) + 24bpp：无调色板', () {
      final RgbaImage img = decoder.decode(buildCoreBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[255, 0, 0, 0],
      ));
      expectPixel(img, 0, 0, <int>[0, 0, 255, 255]);
    });

    test('V2(52)：掩码是头部字段，没有 alpha 掩码', () {
      final RgbaImage img = decoder.decode(buildExtendedBmp(
        dibSize: 52,
        width: 1,
        height: 1,
        bpp: 16,
        compression: 3,
        redMask: 0xF800,
        greenMask: 0x07E0,
        blueMask: 0x001F,
        pixelData: <int>[0xE0, 0x07, 0, 0], // g=63
      ));

      expectPixel(img, 0, 0, <int>[0, 255, 0, 255]);
      expect(img.metadata.variant, 'BITMAPV2INFOHEADER');
    });

    test('V3(56)：多出 alpha 掩码字段', () {
      final RgbaImage img = decoder.decode(buildExtendedBmp(
        dibSize: 56,
        width: 1,
        height: 1,
        bpp: 32,
        compression: 6,
        redMask: 0x00FF0000,
        greenMask: 0x0000FF00,
        blueMask: 0x000000FF,
        alphaMask: 0xFF000000,
        pixelData: <int>[255, 0, 0, 64],
      ));

      expectPixel(img, 0, 0, <int>[0, 0, 255, 64]);
      expect(img.metadata.variant, 'BITMAPV3INFOHEADER');
    });
  });

  group('头部版本：V4 / V5 与未知长度', () {
    test('V4(108)：掩码可声明成 RGBA 字节序', () {
      // 掩码顺序完全由文件决定，解码器不能假定 BGRA。
      final RgbaImage img = decoder.decode(buildExtendedBmp(
        dibSize: 108,
        width: 1,
        height: 1,
        bpp: 32,
        compression: 6,
        redMask: 0x000000FF,
        greenMask: 0x0000FF00,
        blueMask: 0x00FF0000,
        alphaMask: 0xFF000000,
        pixelData: <int>[10, 20, 30, 40],
      ));

      expectPixel(img, 0, 0, <int>[10, 20, 30, 40]);
      expect(img.metadata.variant, 'BITMAPV4HEADER');
    });

    test('V5(124) + 24bpp：掩码字段为零也不影响（24bpp 不走掩码）', () {
      final RgbaImage img = decoder.decode(buildExtendedBmp(
        dibSize: 124,
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 255, 0, 0], // BGR：绿
      ));

      expectPixel(img, 0, 0, <int>[0, 255, 0, 255]);
      expect(img.metadata.variant, 'BITMAPV5HEADER');
    });

    test('V4 + BI_RGB 且掩码全零 → 退回按位深取默认掩码', () {
      // 真实文件里常见：用了新头部但掩码字段没填。
      final RgbaImage img = decoder.decode(buildExtendedBmp(
        dibSize: 108,
        width: 1,
        height: 1,
        bpp: 16,
        pixelData: <int>[0x00, 0x7C, 0, 0], // RGB555 纯红
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
    });

    test('未知的 DIB 头长度被拒绝', () {
      final Uint8List bmp = buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      );
      // DIB 头长度在偏移 14
      expect(
        () => decoder.decode(patch(bmp, 14, <int>[0xE7, 0x03, 0, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('不是已知版本'),
        )),
      );
    });
  });

  group('RLE8 游程解码', () {
    test('编码游程 + 行结束 + 绝对模式', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 4,
        height: 2,
        bpp: 8,
        compression: 1,
        palette: testPalette4,
        pixelData: <int>[
          4, 1, // 存储行 0：四个索引 1
          0, 0, // 行结束
          0, 4, 0, 1, 2, 3, // 存储行 1：绝对模式四个字面值
          0, 1, // 图像结束
        ],
      ));

      // 自底向上：存储行 1 在顶部
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 2, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 3, 0, <int>[0, 0, 255, 255]);
      for (int x = 0; x < 4; x++) {
        expectPixel(img, x, 1, <int>[255, 0, 0, 255]);
      }
      expect(img.metadata.compression, 'RLE8 游程编码');
    });

    test('绝对模式奇数像素要填充到偶数字节', () {
      // 漏掉填充字节会让后续所有命令错位 —— 这里第 4 个像素会变成黑色。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 4,
        height: 1,
        bpp: 8,
        compression: 1,
        palette: testPalette4,
        pixelData: <int>[
          0, 3, 1, 2, 3, 0x00, // 绝对模式 3 个像素 + 1 字节填充
          1, 3, // 再来一个游程：索引 3
          0, 1, // 图像结束
        ],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 0, <int>[0, 0, 255, 255]);
      expectPixel(img, 3, 0, <int>[0, 0, 255, 255],
          reason: '填充字节算错的话这里会是黑色');
    });

    test('增量跳转移动当前位置', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 4,
        height: 2,
        bpp: 8,
        compression: 1,
        palette: testPalette4,
        pixelData: <int>[
          1, 1, // (0,0) 放索引 1
          0, 2, 2, 1, // 增量跳转 dx=2, dy=1 → 当前位置 (3,1)
          1, 3, // (3,1) 放索引 3
          0, 1,
        ],
      ));

      // 存储行 0 = [1,0,0,0]，存储行 1 = [0,0,0,3]；自底向上翻转
      expectPixel(img, 0, 1, <int>[255, 0, 0, 255]);
      expectPixel(img, 3, 0, <int>[0, 0, 255, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 0, 255], reason: '跳过的像素留索引 0');
    });
  });

  group('RLE4 游程解码', () {
    test('编码游程在两个半字节间交替', () {
      // (5, 0x12) → 1 2 1 2 1，这是 RLE4 与 RLE8 唯一的实质差别。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 6,
        height: 1,
        bpp: 4,
        compression: 2,
        palette: testPalette4,
        pixelData: <int>[
          5, 0x12, // 交替输出 1,2,1,2,1
          1, 0x30, // 再来一个索引 3
          0, 1,
        ],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 3, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 4, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 5, 0, <int>[0, 0, 255, 255]);
      expect(img.metadata.compression, 'RLE4 游程编码');
    });

    test('绝对模式：5 个像素占 3 字节，再填充到 4 字节', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 6,
        height: 1,
        bpp: 4,
        compression: 2,
        palette: testPalette4,
        pixelData: <int>[
          0, 5, // 绝对模式 5 个像素
          0x12, 0x30, 0x10, // 半字节打包：1,2,3,0,1
          0x00, // 填充到偶数字节
          1, 0x30, // 第 6 个像素：索引 3
          0, 1,
        ],
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 0, <int>[0, 0, 255, 255]);
      expectPixel(img, 3, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 4, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 5, 0, <int>[0, 0, 255, 255],
          reason: '只跳 3 字节的话这里会是黑色');
    });
  });

  group('RLE 的健壮性', () {
    test('未写到的像素保持索引 0', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 4,
        height: 2,
        bpp: 8,
        compression: 1,
        palette: testPalette4,
        pixelData: <int>[2, 1, 0, 0, 0, 1], // 只写了第一行的前两个
      ));

      expectPixel(img, 0, 1, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 1, <int>[255, 0, 0, 255]);
      expectPixel(img, 2, 1, <int>[0, 0, 0, 255], reason: '行内剩余留索引 0');
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255], reason: '整行未写');
    });

    test('游程长度超出行宽：多余的静默丢弃，不崩', () {
      // 畸形文件里很常见，不值得为此拒绝整个文件。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 8,
        compression: 1,
        palette: testPalette4,
        pixelData: <int>[5, 1, 0, 1], // 声明 5 个但只有 2 列
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[255, 0, 0, 255]);
    });

    test('数据提前耗尽而没有「图像结束」标记：按已解出的部分返回', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 2,
        height: 1,
        bpp: 8,
        compression: 1,
        palette: testPalette4,
        pixelData: <int>[2, 1], // 缺 0,1
      ));

      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[255, 0, 0, 255]);
    });

    test('绝对模式声明的像素数超出剩余字节 → 报错', () {
      expect(
        () => decoder.decode(buildInfoBmp(
          width: 8,
          height: 1,
          bpp: 4,
          compression: 2,
          palette: testPalette4,
          pixelData: <int>[0, 8, 0x12],
        )),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('RLE4 绝对模式声明 8 个像素'),
        )),
      );
    });

    test('增量跳转命令后缺少 dx/dy → 报错', () {
      expect(
        () => decoder.decode(buildInfoBmp(
          width: 4,
          height: 2,
          bpp: 8,
          compression: 1,
          palette: testPalette4,
          pixelData: <int>[0, 2],
        )),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('缺少 dx/dy'),
        )),
      );
    });

    test('RLE 与位深必须匹配', () {
      expect(
        () => decoder.decode(buildInfoBmp(
          width: 2,
          height: 1,
          bpp: 4,
          compression: 1, // RLE8 配 4bpp
          palette: testPalette4,
          pixelData: <int>[0, 1],
        )),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('RLE8 压缩要求 8bpp'),
        )),
      );
      expect(
        () => decoder.decode(buildInfoBmp(
          width: 2,
          height: 1,
          bpp: 8,
          compression: 2, // RLE4 配 8bpp
          palette: testPalette4,
          pixelData: <int>[0, 1],
        )),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('RLE4 压缩要求 4bpp'),
        )),
      );
    });
  });

  group('畸形输入：不信任文件里的任何数字', () {
    // 下面这些文件都只有一处错误，其余部分完全合法 ——
    // 这样失败信息能直接指向被破坏的那个字段。
    late Uint8List valid24;

    setUp(() {
      valid24 = buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      );
    });

    test('魔数不是 BM', () {
      expect(
        () => decoder.decode(patch(valid24, 0, <int>[0x4D, 0x5A])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('魔数应为 "BM"'),
        )),
      );
    });

    test('文件短于文件头', () {
      expect(
        () => decoder.decode(Uint8List.fromList(<int>[0x42, 0x4D])),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('不支持的位深（biBitCount = 7）', () {
      expect(
        () => decoder.decode(patch(valid24, 28, <int>[7, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('每像素位数 7 不受支持'),
        )),
      );
    });

    test('biPlanes 不是 1', () {
      expect(
        () => decoder.decode(patch(valid24, 26, <int>[2, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('biPlanes 必须为 1'),
        )),
      );
    });

    test('内嵌 JPEG / PNG 明确拒绝而不是悄悄出错', () {
      expect(
        () => decoder.decode(patch(valid24, 30, <int>[4, 0, 0, 0])),
        throwsA(isA<UnsupportedImageFeature>().having(
          (UnsupportedImageFeature e) => e.message,
          'message',
          contains('内嵌 JPEG'),
        )),
      );
      expect(
        () => decoder.decode(patch(valid24, 30, <int>[5, 0, 0, 0])),
        throwsA(isA<UnsupportedImageFeature>().having(
          (UnsupportedImageFeature e) => e.message,
          'message',
          contains('内嵌 PNG'),
        )),
      );
    });

    test('未知的压缩方式代码', () {
      expect(
        () => decoder.decode(patch(valid24, 30, <int>[99, 0, 0, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('未知的压缩方式代码 99'),
        )),
      );
    });
  });

  group('畸形输入：尺寸、偏移与掩码', () {
    late Uint8List valid24;

    setUp(() {
      valid24 = buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      );
    });

    test('像素数据被截断 → 报出还差多少字节', () {
      expect(
        () => decoder.decode(buildInfoBmp(
          width: 4,
          height: 4,
          bpp: 24,
          pixelData: List<int>.filled(12, 0), // 只有一行，需要四行
        )),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          allOf(contains('像素数据不足'), contains('共需 48 字节')),
        )),
      );
    });

    test('宽度超出上限', () {
      // 70000 = 0x00011170，小端四字节
      expect(
        () => decoder.decode(patch(valid24, 18, <int>[0x70, 0x11, 0x01, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('超出上限'),
        )),
      );
    });

    test('宽度为 0', () {
      expect(
        () => decoder.decode(patch(valid24, 18, <int>[0, 0, 0, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('宽高必须为正数'),
        )),
      );
    });

    test('宽高各自合法但像素总数溢出 → 拒绝分配', () {
      // 65535x65535 每边都没超上限，但乘起来是 43 亿像素、17GB 内存。
      // 这是「先除后乘」那个检查存在的理由。
      Uint8List bad = patch(valid24, 18, <int>[0xFF, 0xFF, 0, 0]);
      bad = patch(bad, 22, <int>[0xFF, 0xFF, 0, 0]);
      expect(
        () => decoder.decode(bad),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('像素总数'),
        )),
      );
    });

    test('BI_BITFIELDS 用在 24bpp 上', () {
      expect(
        () => decoder.decode(patch(valid24, 30, <int>[3, 0, 0, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('BI_BITFIELDS 只用于 16bpp 或 32bpp'),
        )),
      );
    });

    test('不连续的通道掩码被拒绝', () {
      expect(
        () => decoder.decode(buildInfoBmp(
          width: 1,
          height: 1,
          bpp: 16,
          compression: 3,
          bitfieldMasks: <int>[0x5000, 0x03E0, 0x001F],
          pixelData: <int>[0, 0, 0, 0],
        )),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('不是连续的位段'),
        )),
      );
    });

    test('bfOffBits 指向文件之外', () {
      expect(
        () => decoder.decode(patch(valid24, 10, <int>[0x0F, 0x27, 0, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('bfOffBits 声明像素数据在偏移 9999'),
        )),
      );
    });

    test('bfOffBits 小于文件头长度', () {
      expect(
        () => decoder.decode(patch(valid24, 10, <int>[2, 0, 0, 0])),
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('超出文件范围 14..'),
        )),
      );
    });
  });

  group('元数据', () {
    test('分辨率从「像素/米」换算成 DPI', () {
      // 3780 像素/米 ≈ 96 DPI，是 Windows 的默认屏幕分辨率。
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
        xPpm: 3780,
      ));
      expect(img.metadata.extra['分辨率'], '96 DPI');
    });

    test('未声明分辨率时不显示这一项', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      ));
      expect(img.metadata.extra.containsKey('分辨率'), isFalse);
    });

    test('格式、无损标记与通道数', () {
      final RgbaImage img24 = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 24,
        pixelData: <int>[0, 0, 0, 0],
      ));
      expect(img24.metadata.format, 'BMP');
      expect(img24.metadata.isLossless, isTrue,
          reason: 'BMP 的 RLE 也是无损的');
      expect(img24.metadata.bitDepth, 24);
      expect(img24.metadata.channels, 3);
      expect(img24.metadata.colorSpace, 'BGR');
      expect(img24.metadata.variant, 'BITMAPINFOHEADER (Windows 3.0)');
    });

    test('像素数据偏移记录在元数据里', () {
      final RgbaImage img = decoder.decode(buildInfoBmp(
        width: 1,
        height: 1,
        bpp: 8,
        palette: testPalette4,
        pixelData: <int>[0, 0, 0, 0],
      ));
      // 14 文件头 + 40 DIB 头 + 4 项 x 4 字节调色板
      expect(img.metadata.extra['像素数据偏移'], 70);
    });
  });

  group('BmpHeaderVersion / BmpCompression 单元测试', () {
    test('fromSize 按头部长度分派', () {
      expect(BmpHeaderVersion.fromSize(12), BmpHeaderVersion.core);
      expect(BmpHeaderVersion.fromSize(40), BmpHeaderVersion.info);
      expect(BmpHeaderVersion.fromSize(52), BmpHeaderVersion.v2);
      expect(BmpHeaderVersion.fromSize(56), BmpHeaderVersion.v3);
      expect(BmpHeaderVersion.fromSize(108), BmpHeaderVersion.v4);
      expect(BmpHeaderVersion.fromSize(124), BmpHeaderVersion.v5);
      expect(() => BmpHeaderVersion.fromSize(64),
          throwsA(isA<ImageDecodeException>()));
    });

    test('只有 CORE 版的调色板项是 3 字节', () {
      expect(BmpHeaderVersion.core.paletteEntrySize, 3);
      for (final BmpHeaderVersion v in BmpHeaderVersion.values) {
        if (v != BmpHeaderVersion.core) {
          expect(v.paletteEntrySize, 4, reason: '${v.name} 应为 4');
        }
      }
    });

    test('掩码字段从 V2 开始有，alpha 掩码从 V3 开始有', () {
      expect(BmpHeaderVersion.info.hasInlineMasks, isFalse);
      expect(BmpHeaderVersion.v2.hasInlineMasks, isTrue);
      expect(BmpHeaderVersion.v2.hasInlineAlphaMask, isFalse);
      expect(BmpHeaderVersion.v3.hasInlineAlphaMask, isTrue);
      expect(BmpHeaderVersion.v5.hasInlineAlphaMask, isTrue);
    });

    test('压缩方式的分类判断', () {
      expect(BmpCompression.fromCode(0), BmpCompression.rgb);
      expect(BmpCompression.fromCode(2), BmpCompression.rle4);
      expect(BmpCompression.rle8.isRle, isTrue);
      expect(BmpCompression.rle4.isRle, isTrue);
      expect(BmpCompression.rgb.isRle, isFalse);
      expect(BmpCompression.bitfields.usesMasks, isTrue);
      expect(BmpCompression.alphaBitfields.usesMasks, isTrue);
      expect(BmpCompression.rgb.usesMasks, isFalse);
      expect(() => BmpCompression.fromCode(7),
          throwsA(isA<ImageDecodeException>()));
    });
  });

  group('ChannelMask 单元测试', () {
    test('从掩码算出移位量与位宽', () {
      final ChannelMask r555 = ChannelMask(0x7C00);
      expect(r555.shift, 10);
      expect(r555.width, 5);
      expect(r555.isPresent, isTrue);

      final ChannelMask g565 = ChannelMask(0x07E0);
      expect(g565.shift, 5);
      expect(g565.width, 6);

      final ChannelMask a8 = ChannelMask(0xFF000000);
      expect(a8.shift, 24);
      expect(a8.width, 8);
    });

    test('空掩码表示通道不存在，抽取时返回满值', () {
      final ChannelMask none = ChannelMask(0);
      expect(none.isPresent, isFalse);
      expect(none.extract(0x1234), 255, reason: '不存在的通道按不透明处理');
    });

    test('比例缩放：满值映射到 255，中间值四舍五入', () {
      final ChannelMask m5 = ChannelMask(0x001F);
      expect(m5.extract(31), 255, reason: '5 位满值不能是 248');
      expect(m5.extract(0), 0);
      expect(m5.extract(16), 132);
      expect(m5.extract(1), 8);

      final ChannelMask m6 = ChannelMask(0x003F);
      expect(m6.extract(63), 255);
      expect(m6.extract(32), 130);

      final ChannelMask m4 = ChannelMask(0x000F);
      expect(m4.extract(15), 255);
      expect(m4.extract(8), 136);
    });

    test('8 位通道直接透传，不做缩放', () {
      final ChannelMask m8 = ChannelMask(0x0000FF00);
      expect(m8.extract(0x00007F00), 0x7F);
      expect(m8.extract(0xFFFFFFFF), 255);
    });

    test('不连续的位段与过宽的位段都被拒绝', () {
      expect(() => ChannelMask(0x5000), throwsA(isA<ImageDecodeException>()));
      expect(() => ChannelMask(0x0101), throwsA(isA<ImageDecodeException>()));
      expect(
        () => ChannelMask(0x0001FFFF), // 连续但 17 位
        throwsA(isA<ImageDecodeException>().having(
          (ImageDecodeException e) => e.message,
          'message',
          contains('位宽 17'),
        )),
      );
    });
  });

  group('BmpHeader.rowStride 公式', () {
    test('每行都补到 4 字节的整数倍', () {
      // 公式 ((width * bpp + 31) ~/ 32) * 4。手算几个典型值对照。
      expect(headerOf(1, 1, 24).rowStride, 4, reason: '3 → 4');
      expect(headerOf(2, 1, 24).rowStride, 8, reason: '6 → 8');
      expect(headerOf(3, 1, 24).rowStride, 12, reason: '9 → 12');
      expect(headerOf(4, 1, 24).rowStride, 12, reason: '12 已对齐');
      expect(headerOf(1, 1, 32).rowStride, 4, reason: '32bpp 天然对齐');
      expect(headerOf(3, 1, 32).rowStride, 12);
      expect(headerOf(1, 1, 16).rowStride, 4, reason: '2 → 4');
      expect(headerOf(3, 1, 16).rowStride, 8, reason: '6 → 8');
      expect(headerOf(8, 1, 1).rowStride, 4, reason: '1 → 4');
      expect(headerOf(33, 1, 1).rowStride, 8, reason: '5 → 8');
      expect(headerOf(3, 1, 4).rowStride, 4, reason: '2 → 4');
      expect(headerOf(9, 1, 4).rowStride, 8, reason: '5 → 8');
      expect(headerOf(5, 1, 8).rowStride, 8);
    });

    test('uncompressedDataSize = rowStride * height', () {
      final BmpHeader h = headerOf(3, 2, 24);
      expect(h.rowStride, 12);
      expect(h.uncompressedDataSize, 24);
    });

    test('isIndexed 以 8bpp 为界', () {
      expect(headerOf(8, 1, 1).isIndexed, isTrue);
      expect(headerOf(8, 1, 8).isIndexed, isTrue);
      expect(headerOf(8, 1, 16).isIndexed, isFalse);
      expect(headerOf(8, 1, 24).isIndexed, isFalse);
    });

    test('toString 便于教学时打印头部', () {
      final String s = headerOf(3, 2, 24).toString();
      expect(s, contains('3x2'));
      expect(s, contains('24bpp'));
      expect(s, contains('自底向上'));
      expect(s, contains('stride=12'));
    });
  });
}
