import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/png/png_chunk.dart';
import 'package:image_viewer/src/codecs/png/png_decoder.dart';
import 'package:image_viewer/src/codecs/png/png_filters.dart';
import 'package:image_viewer/src/codecs/png/png_header.dart';
import 'package:image_viewer/src/codecs/png/png_interlace.dart';
import 'package:image_viewer/src/codecs/png/png_types.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

import '../support/byte_builders.dart';
import '../support/deflate_builders.dart';
import '../support/pixel_matchers.dart';
import '../support/png_builders.dart';

const PngDecoder decoder = PngDecoder();

/// PNG 是无损格式，所以所有断言的容差都必须是 0。差一个数值就是错。
RgbaImage decode(Uint8List bytes) => decoder.decode(bytes);

void main() {
  group('识别', () {
    test('认得自己的签名', () {
      expect(decoder.canDecode(buildRgb8Png(const <List<int>>[<int>[1, 2, 3]])),
          isTrue);
      expect(decoder.name, 'PNG');
      expect(decoder.extensions, contains('png'));
    });

    test('不认别的格式', () {
      // BMP 的 'BM'、JPEG 的 FFD8、GIF 的 'GIF87a'。
      expect(decoder.canDecode(Uint8List.fromList(const <int>[0x42, 0x4D])),
          isFalse);
      expect(decoder.canDecode(Uint8List.fromList(const <int>[0xFF, 0xD8, 0xFF])),
          isFalse);
      expect(
        decoder.canDecode(Uint8List.fromList(
            const <int>[0x47, 0x49, 0x46, 0x38, 0x37, 0x61, 0, 0])),
        isFalse,
      );
    });

    test('比签名还短的输入不会越界', () {
      for (int n = 0; n < 8; n++) {
        expect(decoder.canDecode(Uint8List(n)), isFalse, reason: '长度 $n');
      }
    });
  });

  group('尺寸', () {
    test('1×1 是合法的最小图', () {
      final RgbaImage img = decode(buildRgb8Png(const <List<int>>[
        <int>[255, 0, 0],
      ]));
      expect(img.width, 1);
      expect(img.height, 1);
      expectPixel(img, 0, 0, const <int>[255, 0, 0, 255]);
    });

    test('奇数宽高，行末没有填充', () {
      // PNG 的行长是 ceil(width × bpp / 8)，字节内可能有填充位，但**行与
      // 行之间没有** —— 这和 BMP 的四字节对齐正好相反，是最容易写错的地方。
      final RgbaImage img = decode(buildRgb8Png(const <List<int>>[
        <int>[1, 2, 3, 4, 5, 6, 7, 8, 9],
        <int>[10, 11, 12, 13, 14, 15, 16, 17, 18],
        <int>[19, 20, 21, 22, 23, 24, 25, 26, 27],
      ]));
      expect(img.width, 3);
      expect(img.height, 3);
      expectPixel(img, 2, 2, const <int>[25, 26, 27, 255]);
    });

    test('单行与单列', () {
      final RgbaImage row = decode(buildRgb8Png(const <List<int>>[
        <int>[1, 1, 1, 2, 2, 2, 3, 3, 3],
      ]));
      expect(<int>[row.width, row.height], <int>[3, 1]);
      expectPixel(row, 2, 0, const <int>[3, 3, 3, 255]);

      final RgbaImage col = decode(buildRgb8Png(const <List<int>>[
        <int>[1, 1, 1],
        <int>[2, 2, 2],
        <int>[3, 3, 3],
      ]));
      expect(<int>[col.width, col.height], <int>[1, 3]);
      expectPixel(col, 0, 2, const <int>[3, 3, 3, 255]);
    });
  });

  group('颜色类型 × 位深', () {
    /// 组装一张不滤波的图，[rows] 的每一项是该行的原始字节。
    RgbaImage build(
      List<List<int>> rows, {
      required int width,
      required int bitDepth,
      required int colorType,
      List<int>? palette,
      List<int>? transparency,
    }) =>
        decode(buildPng(
          width: width,
          height: rows.length,
          bitDepth: bitDepth,
          colorType: colorType,
          raw: rawWithFilters(rows),
          palette: palette,
          transparency: transparency,
        ));

    test('灰度 8 位：一个样本铺满 R/G/B', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0, 128, 255],
        ],
        width: 3,
        bitDepth: 8,
        colorType: 0,
      );
      expectPixel(img, 0, 0, const <int>[0, 0, 0, 255]);
      expectPixel(img, 1, 0, const <int>[128, 128, 128, 255]);
      expectPixel(img, 2, 0, const <int>[255, 255, 255, 255]);
    });

    test('灰度 16 位：大端两字节，四舍五入缩到 8 位', () {
      // 缩放公式是 (v × 255 + 32767) ÷ 65535，不是「取高字节」。
      // 0x00FF 正好能区分两者：四舍五入得 1，截断高字节得 0。
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0x00, 0x00, 0x00, 0xFF, 0x80, 0x00, 0xFF, 0xFF],
        ],
        width: 4,
        bitDepth: 16,
        colorType: 0,
      );
      expect(img.channelsAt(0, 0).first, 0);
      expect(img.channelsAt(1, 0).first, 1, reason: '0x00FF 应四舍五入到 1');
      expect(img.channelsAt(2, 0).first, 128);
      expect(img.channelsAt(3, 0).first, 255);
    });

    test('灰度 1 位：字节内高位先出', () {
      // 0xA0 = 0b1010_0000，宽 3 只取前三位 → 1, 0, 1。
      // 注意这与 deflate 位流的低位先出**方向相反**。同一个文件里两种
      // 位序并存：Huffman 码字高位先出、数据字段低位先出、而这里的像素
      // 样本又是高位先出。写解码器时最容易在这上面栽跟头。
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0xA0],
        ],
        width: 3,
        bitDepth: 1,
        colorType: 0,
      );
      expectPixel(img, 0, 0, const <int>[255, 255, 255, 255]);
      expectPixel(img, 1, 0, const <int>[0, 0, 0, 255]);
      expectPixel(img, 2, 0, const <int>[255, 255, 255, 255]);
    });

    test('灰度 1 位：行末的填充位被忽略', () {
      // 宽 3 只用一个字节的前 3 位，后 5 位是填充。把填充位全置 1 也
      // 不该改变任何像素 —— 解码方必须按宽度停下，不能读满整字节。
      for (final int b in <int>[0xA0, 0xBF]) {
        final RgbaImage img = build(
          <List<int>>[
            <int>[b],
          ],
          width: 3,
          bitDepth: 1,
          colorType: 0,
        );
        expect(
          <int>[
            img.channelsAt(0, 0).first,
            img.channelsAt(1, 0).first,
            img.channelsAt(2, 0).first,
          ],
          <int>[255, 0, 255],
          reason: '填充字节 0x${b.toRadixString(16)}',
        );
      }
    });

    test('灰度 2 位：四级灰阶乘 85 铺满值域', () {
      // 0x1B = 0b00_01_10_11 → 0,1,2,3。缩放要让最大值映射到 255，
      // 所以是 ×85（= 255/3），不是 ×64。
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0x1B],
        ],
        width: 4,
        bitDepth: 2,
        colorType: 0,
      );
      expect(
        List<int>.generate(4, (int x) => img.channelsAt(x, 0).first),
        <int>[0, 85, 170, 255],
      );
    });

    test('灰度 4 位：十六级灰阶乘 17', () {
      // 0x0F, 0x80 → 样本 0, 15, 8（末尾 4 位是填充）。×17 = 255/15。
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0x0F, 0x80],
        ],
        width: 3,
        bitDepth: 4,
        colorType: 0,
      );
      expect(
        List<int>.generate(3, (int x) => img.channelsAt(x, 0).first),
        <int>[0, 255, 136],
      );
    });

    test('真彩色 8 位', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[255, 0, 0, 0, 255, 0],
          <int>[0, 0, 255, 10, 20, 30],
        ],
        width: 2,
        bitDepth: 8,
        colorType: 2,
      );
      expectPixel(img, 0, 0, const <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, const <int>[0, 255, 0, 255]);
      expectPixel(img, 0, 1, const <int>[0, 0, 255, 255]);
      expectPixel(img, 1, 1, const <int>[10, 20, 30, 255]);
    });

    test('真彩色 16 位：每像素六字节', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00],
        ],
        width: 1,
        bitDepth: 16,
        colorType: 2,
      );
      expectPixel(img, 0, 0, const <int>[255, 128, 0, 255]);
    });

    test('灰度 + alpha 8 位', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[100, 255, 200, 0, 50, 128],
        ],
        width: 3,
        bitDepth: 8,
        colorType: 4,
      );
      expectPixel(img, 0, 0, const <int>[100, 100, 100, 255]);
      expectPixel(img, 1, 0, const <int>[200, 200, 200, 0]);
      expectPixel(img, 2, 0, const <int>[50, 50, 50, 128]);
    });

    test('灰度 + alpha 16 位', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0x80, 0x00, 0xFF, 0xFF, 0xFF, 0xFF, 0x00, 0x00],
        ],
        width: 2,
        bitDepth: 16,
        colorType: 4,
      );
      expectPixel(img, 0, 0, const <int>[128, 128, 128, 255]);
      expectPixel(img, 1, 0, const <int>[255, 255, 255, 0]);
    });

    test('真彩色 + alpha 8 位：与输出格式天然对齐', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[1, 2, 3, 4, 250, 251, 252, 253],
        ],
        width: 2,
        bitDepth: 8,
        colorType: 6,
      );
      expectPixel(img, 0, 0, const <int>[1, 2, 3, 4]);
      expectPixel(img, 1, 0, const <int>[250, 251, 252, 253]);
    });

    test('真彩色 + alpha 16 位：每像素八字节', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0xFF, 0xFF, 0x80, 0x00, 0x00, 0x00, 0x40, 0x00],
        ],
        width: 1,
        bitDepth: 16,
        colorType: 6,
      );
      expectPixel(img, 0, 0, const <int>[255, 128, 0, 64]);
    });

    test('调色板 8 位', () {
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0, 1, 2],
        ],
        width: 3,
        bitDepth: 8,
        colorType: 3,
        palette: const <int>[255, 0, 0, 0, 255, 0, 0, 0, 255],
      );
      expectPixel(img, 0, 0, const <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, const <int>[0, 255, 0, 255]);
      expectPixel(img, 2, 0, const <int>[0, 0, 255, 255]);
    });

    test('调色板 4 位：索引不缩放', () {
      // 这是调色板最容易写错的一点：位深指的是**索引的位数**，索引本身
      // 是查表用的序号，不是颜色值，绝不能像灰度那样 ×17 铺满值域。
      // 0x01 → 索引 0, 1。要是错缩放成 0, 17，就会查到第 17 项去 ——
      // 这里刻意只给 2 项调色板，缩放的实现会当场越界。
      final RgbaImage img = build(
        const <List<int>>[
          <int>[0x01],
        ],
        width: 2,
        bitDepth: 4,
        colorType: 3,
        palette: const <int>[10, 20, 30, 40, 50, 60],
      );
      expectPixel(img, 0, 0, const <int>[10, 20, 30, 255]);
      expectPixel(img, 1, 0, const <int>[40, 50, 60, 255]);
    });

    test('调色板 2 位与 1 位', () {
      // 0x1B = 0b00_01_10_11 → 0,1,2,3。
      final RgbaImage two = build(
        const <List<int>>[
          <int>[0x1B],
        ],
        width: 4,
        bitDepth: 2,
        colorType: 3,
        palette: const <int>[0, 0, 0, 1, 1, 1, 2, 2, 2, 3, 3, 3],
      );
      expect(
        List<int>.generate(4, (int x) => two.channelsAt(x, 0).first),
        <int>[0, 1, 2, 3],
      );

      // 0x80 = 0b1000_0000，宽 2 取前两位 → 1, 0。
      final RgbaImage one = build(
        const <List<int>>[
          <int>[0x80],
        ],
        width: 2,
        bitDepth: 1,
        colorType: 3,
        palette: const <int>[9, 9, 9, 7, 7, 7],
      );
      expectPixel(one, 0, 0, const <int>[7, 7, 7, 255]);
      expectPixel(one, 1, 0, const <int>[9, 9, 9, 255]);
    });

    test('索引超出调色板项数被拒', () {
      // 只给 2 项，却用索引 5。这类文件真实存在（多为编码器 bug），
      // 必须给出明确错误，而不是读到调色板数组外面去。
      expect(
        () => build(
          const <List<int>>[
            <int>[0, 5],
          ],
          width: 2,
          bitDepth: 8,
          colorType: 3,
          palette: const <int>[1, 1, 1, 2, 2, 2],
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('滤波器', () {
    /// 每行自带滤波类型的图。[rows] 的每一项是 `[滤波类型, ...该行字节]`。
    RgbaImage filtered(
      List<List<int>> rows, {
      required int width,
      int bitDepth = 8,
      int colorType = 2,
    }) =>
        decode(buildPng(
          width: width,
          height: rows.length,
          bitDepth: bitDepth,
          colorType: colorType,
          raw: <int>[for (final List<int> r in rows) ...r],
        ));

    test('0 = None，原样通过', () {
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[0, 10, 20, 30],
        ],
        width: 1,
      );
      expectPixel(img, 0, 0, const <int>[10, 20, 30, 255]);
    });

    test('1 = Sub，减左边同通道的字节', () {
      // Recon(x) = Filt(x) + Recon(x - bpp)。第一个像素左边没有邻居，
      // 按 0 算 —— 不是「跳过」，而是真的加 0。
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[1, 10, 20, 30, 5, 5, 5],
        ],
        width: 2,
      );
      expectPixel(img, 0, 0, const <int>[10, 20, 30, 255]);
      expectPixel(img, 1, 0, const <int>[15, 25, 35, 255]);
    });

    test('2 = Up，减上一行同位置的字节', () {
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[0, 10, 20, 30],
          <int>[2, 1, 2, 3],
        ],
        width: 1,
      );
      expectPixel(img, 0, 0, const <int>[10, 20, 30, 255]);
      expectPixel(img, 0, 1, const <int>[11, 22, 33, 255]);
    });

    test('3 = Average，加左边与上边的均值', () {
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[0, 10, 20, 30],
          <int>[3, 1, 2, 3],
        ],
        width: 1,
      );
      expectPixel(img, 0, 0, const <int>[10, 20, 30, 255]);
      // 左边没有邻居按 0 算：1+⌊10/2⌋=6, 2+⌊20/2⌋=12, 3+⌊30/2⌋=18。
      expectPixel(img, 0, 1, const <int>[6, 12, 18, 255]);
    });

    test('3 = Average，左右都有邻居时先相加再折半', () {
      // 关键：a + b 要在**除法之前**保持完整精度，不能先对 256 取模。
      // 200 + 200 = 400，⌊400/2⌋ = 200；要是先截成 8 位（400 & 0xFF = 144）
      // 再折半就得 72。这是 Average 唯一会溢出 8 位的地方。
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[0, 200, 200],
          <int>[3, 0, 0],
        ],
        width: 2,
        colorType: 0,
      );
      expect(img.channelsAt(0, 1).first, 100, reason: '0 + ⌊(0+200)/2⌋');
      expect(
        img.channelsAt(1, 1).first,
        150,
        reason: '0 + ⌊(100+200)/2⌋ = 150，不是 ⌊(300 & 0xFF)/2⌋ = 22',
      );
    });

    test('4 = Paeth，挑最接近线性预测的那个邻居', () {
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[0, 10, 20],
          <int>[4, 5, 5],
        ],
        width: 2,
        colorType: 0,
      );
      // 第 0 字节：a=0, b=10, c=0 → p=10，pb=0 最小 → 预测 b=10 → 15。
      // 第 1 字节：a=15, b=20, c=10 → p=25，pb=5 最小 → 预测 b=20 → 25。
      expect(img.channelsAt(0, 1).first, 15);
      expect(img.channelsAt(1, 1).first, 25);
    });

    test('Paeth 预测器的平局规则：a 优先，其次 b，最后 c', () {
      // 规范写的是「pa <= pb && pa <= pc 取 a，否则 pb <= pc 取 b，否则 c」。
      // 三个都用 <=，平局时的优先级就是 a > b > c。把任何一个 <= 写成 <
      // 都会在平局处偏一格，而平局在真实图片里非常常见（纯色块、渐变）。
      expect(paethPredictor(5, 5, 5), 5, reason: '三者相等');
      // a=b=10, c=0：p=20, pa=pb=10, pc=20 → a 与 b 平局，取 a。
      expect(paethPredictor(10, 10, 0), 10);
      // a=0, b=3, c=1：p=2, pa=2, pb=1, pc=1 → b 与 c 平局，取 b。
      expect(paethPredictor(0, 3, 1), 3);
      // a=0, b=3, c=5：p=-2, pa=2, pb=5, pc=7 → pa 最小，取 a。
      expect(paethPredictor(0, 3, 5), 0);
      // a=10, b=10, c=20：p=0, pa=10, pb=10, pc=20 → 取 a。
      expect(paethPredictor(10, 10, 20), 10);
    });

    test('Paeth 的中间值可以超出 0..255，不能提前截断', () {
      // p = a + b - c 会跑到 [-255, 510]，三个距离也随之变大。要是把 p
      // 先钳到 0..255，挑出来的邻居就变了。
      expect(paethPredictor(0, 0, 255), 0, reason: 'p = -255');
      expect(paethPredictor(255, 255, 0), 255, reason: 'p = 510');
      // a=255, b=0, c=0：p=255, pa=0 → 取 a。
      expect(paethPredictor(255, 0, 0), 255);
    });

    test('滤波按字节算，不按像素 —— 位深小于 8 时 bpp 记 1', () {
      // 1 位灰度、宽 16 时一行两个字节，每字节装 8 个像素。Sub 滤波器的
      // 步长是 max(1, 每像素字节数) = 1，所以第二个字节减的是第一个字节，
      // 而不是「左边那个像素」。
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[1, 0xF0, 0x0F],
        ],
        width: 16,
        bitDepth: 1,
        colorType: 0,
      );
      // 第二字节 = 0x0F + 0xF0 = 0xFF → 后 8 个像素全白。
      for (int x = 8; x < 16; x++) {
        expect(img.channelsAt(x, 0).first, 255, reason: 'x=$x');
      }
      // 第一字节 0xF0 → 前 4 白、后 4 黑。
      expect(img.channelsAt(0, 0).first, 255);
      expect(img.channelsAt(4, 0).first, 0);
    });

    test('重建结果对 256 取模', () {
      // Recon 的加法是 8 位环绕的。200 + 100 = 300 → 44。滤波器靠这个
      // 环绕才能无损还原：编码方减出来的差值也是环绕的。
      final RgbaImage img = filtered(
        const <List<int>>[
          <int>[1, 200, 100],
        ],
        width: 2,
        colorType: 0,
      );
      expect(img.channelsAt(0, 0).first, 200);
      expect(img.channelsAt(1, 0).first, 44);
    });

    test('滤波类型 5 被拒', () {
      // 只定义了 0..4。第 5 个值往往意味着行长算错了、把像素字节当成了
      // 滤波类型字节 —— 报错比猜测好。
      expect(
        () => filtered(
          const <List<int>>[
            <int>[5, 1, 2, 3],
          ],
          width: 1,
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('tRNS 的三种形态', () {
    test('调色板：每项一个 alpha 字节', () {
      final RgbaImage img = decode(buildPng(
        width: 3,
        height: 1,
        bitDepth: 8,
        colorType: 3,
        raw: rawWithFilters(const <List<int>>[
          <int>[0, 1, 2],
        ]),
        palette: const <int>[10, 10, 10, 20, 20, 20, 30, 30, 30],
        transparency: const <int>[0, 128, 255],
      ));
      expectPixel(img, 0, 0, const <int>[10, 10, 10, 0]);
      expectPixel(img, 1, 0, const <int>[20, 20, 20, 128]);
      expectPixel(img, 2, 0, const <int>[30, 30, 30, 255]);
    });

    test('调色板：tRNS 比调色板短，缺的项按不透明算', () {
      // 规范允许 tRNS 只覆盖前几项 —— 编码方通常只把真正透明的那几项
      // 写进去。缺失的项默认 255，不是 0。要是默认成 0，整张图会全透明。
      final RgbaImage img = decode(buildPng(
        width: 3,
        height: 1,
        bitDepth: 8,
        colorType: 3,
        raw: rawWithFilters(const <List<int>>[
          <int>[0, 1, 2],
        ]),
        palette: const <int>[10, 10, 10, 20, 20, 20, 30, 30, 30],
        transparency: const <int>[0], // 只声明第 0 项透明
      ));
      expect(img.channelsAt(0, 0)[3], 0);
      expect(img.channelsAt(1, 0)[3], 255);
      expect(img.channelsAt(2, 0)[3], 255);
    });

    test('调色板：tRNS 比调色板长被拒', () {
      // 反过来不允许：alpha 多过颜色，说明两个块对不上。
      expect(
        () => decode(buildPng(
          width: 1,
          height: 1,
          bitDepth: 8,
          colorType: 3,
          raw: rawWithFilters(const <List<int>>[
            <int>[0],
          ]),
          palette: const <int>[10, 10, 10],
          transparency: const <int>[0, 0],
        )),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('灰度：两字节的关键色', () {
      // tRNS 里的灰度关键色恒为 16 位大端，哪怕图是 8 位的 —— 所以
      // 8 位图的关键色 128 要写成 0x00 0x80。
      final RgbaImage img = decode(buildPng(
        width: 3,
        height: 1,
        bitDepth: 8,
        colorType: 0,
        raw: rawWithFilters(const <List<int>>[
          <int>[0, 128, 255],
        ]),
        transparency: const <int>[0x00, 0x80],
      ));
      expect(img.channelsAt(0, 0)[3], 255);
      expect(img.channelsAt(1, 0)[3], 0, reason: '灰度 128 应被判为透明');
      expect(img.channelsAt(2, 0)[3], 255);
    });

    test('灰度 16 位：关键色比的是原始样本，不是缩放后的 8 位值', () {
      // 0x00FF 和 0x0100 缩到 8 位都是 1 —— 两个像素的灰度输出完全一样。
      // 但关键色只等于 0x00FF，所以只有第一个透明。要是拿缩放后的值去比，
      // 两个都会变透明，凭输出的灰度值根本看不出错。
      final RgbaImage img = decode(buildPng(
        width: 2,
        height: 1,
        bitDepth: 16,
        colorType: 0,
        raw: rawWithFilters(const <List<int>>[
          <int>[0x00, 0xFF, 0x01, 0x00],
        ]),
        transparency: const <int>[0x00, 0xFF],
      ));
      expect(img.channelsAt(0, 0).first, 1);
      expect(img.channelsAt(1, 0).first, 1, reason: '两个样本缩放后应相同');
      expect(img.channelsAt(0, 0)[3], 0);
      expect(img.channelsAt(1, 0)[3], 255, reason: '0x0100 不等于关键色');
    });

    test('真彩色：六字节的关键色，三个通道必须全中', () {
      final RgbaImage img = decode(buildPng(
        width: 3,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[
          <int>[255, 0, 0, 0, 255, 0, 255, 0, 1],
        ]),
        transparency: const <int>[0x00, 0xFF, 0x00, 0x00, 0x00, 0x00],
      ));
      expect(img.channelsAt(0, 0)[3], 0, reason: '(255,0,0) 正是关键色');
      expect(img.channelsAt(1, 0)[3], 255);
      expect(
        img.channelsAt(2, 0)[3],
        255,
        reason: '(255,0,1) 只中了两个通道，不算透明',
      );
    });

    test('长度不对的 tRNS 被拒', () {
      for (final List<Object> c in <List<Object>>[
        <Object>[0, <int>[0x00], '灰度要 2 字节'],
        <Object>[0, <int>[0, 0, 0], '灰度不能是 3 字节'],
        <Object>[2, <int>[0, 0, 0, 0], '真彩色要 6 字节'],
      ]) {
        final int colorType = c[0] as int;
        final List<int> trns = c[1] as List<int>;
        expect(
          () => decode(buildPng(
            width: 1,
            height: 1,
            bitDepth: 8,
            colorType: colorType,
            raw: rawWithFilters(<List<int>>[
              List<int>.filled(colorType == 0 ? 1 : 3, 0),
            ]),
            transparency: trns,
          )),
          throwsA(isA<ImageDecodeException>()),
          reason: c[2] as String,
        );
      }
    });

    test('已有 alpha 通道的图不该再有 tRNS', () {
      // 颜色类型 4 和 6 自带 alpha，tRNS 在规范里被明确禁止 —— 两种
      // 透明度来源同时存在的话，谁优先是没有定义的。
      for (final int colorType in <int>[4, 6]) {
        expect(
          () => decode(buildPng(
            width: 1,
            height: 1,
            bitDepth: 8,
            colorType: colorType,
            raw: rawWithFilters(<List<int>>[
              List<int>.filled(colorType == 4 ? 2 : 4, 0),
            ]),
            transparency: const <int>[0, 0],
          )),
          throwsA(isA<ImageDecodeException>()),
          reason: '颜色类型 $colorType',
        );
      }
    });
  });

  group('Adam7 隔行扫描', () {
    /// 七趟的起点与步长，照规范手抄一遍，刻意不引用被测代码里的那份表。
    const List<List<int>> passes = <List<int>>[
      <int>[0, 0, 8, 8],
      <int>[4, 0, 8, 8],
      <int>[0, 4, 4, 8],
      <int>[2, 0, 4, 4],
      <int>[0, 2, 2, 4],
      <int>[1, 0, 2, 2],
      <int>[0, 1, 1, 2],
    ];

    /// 把 8 位灰度图 [px] 按 Adam7 拆成七趟，拼出 IDAT 该解出来的原始流。
    ///
    /// 每趟自己算行长、每行自带滤波类型字节。空趟一个字节都不占 ——
    /// 连滤波类型字节都没有，这点很容易写成「占一个空行」。
    List<int> interlace(List<List<int>> px) {
      final int h = px.length;
      final int w = px.first.length;
      final List<int> out = <int>[];
      for (final List<int> p in passes) {
        if (w <= p[0] || h <= p[1]) {
          continue;
        }
        for (int y = p[1]; y < h; y += p[3]) {
          out.add(0); // 滤波类型 None
          for (int x = p[0]; x < w; x += p[2]) {
            out.add(px[y][x]);
          }
        }
      }
      return out;
    }

    /// 值等于 `y × 宽 + x` 的灰度图，每个像素都不一样，错位一格就能发现。
    List<List<int>> ramp(int w, int h) => List<List<int>>.generate(
          h,
          (int y) => List<int>.generate(w, (int x) => y * w + x),
        );

    test('8×8：七趟都非空，逐像素还原', () {
      final List<List<int>> px = ramp(8, 8);
      final RgbaImage img = decode(buildPng(
        width: 8,
        height: 8,
        bitDepth: 8,
        colorType: 0,
        raw: interlace(px),
        interlace: 1,
      ));
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          expect(img.channelsAt(x, y).first, y * 8 + x, reason: '($x, $y)');
        }
      }
    });

    test('隔行与非隔行解出同一张图', () {
      // 同样的像素、两种排布方式，结果必须逐像素相同。容差 0 —— PNG
      // 是无损格式，隔行只改变字节顺序，不该改变任何一个数值。
      final List<List<int>> px = ramp(5, 3);
      final RgbaImage plain = decode(buildPng(
        width: 5,
        height: 3,
        bitDepth: 8,
        colorType: 0,
        raw: rawWithFilters(px),
      ));
      final RgbaImage woven = decode(buildPng(
        width: 5,
        height: 3,
        bitDepth: 8,
        colorType: 0,
        raw: interlace(px),
        interlace: 1,
      ));
      expectImageMatches(woven, plain);
    });

    test('1×1：七趟里有六趟是空的', () {
      // 只有第一趟落得下这个像素，其余六趟的起点都已越界。空趟必须
      // **一个字节都不占** —— 连滤波类型字节也没有。要是每趟都留一个
      // 空行，原始流长度就会算错，解压结果对不上，整张图直接解不出来。
      final RgbaImage img = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 0,
        raw: interlace(const <List<int>>[
          <int>[42],
        ]),
        interlace: 1,
      ));
      expect(img.channelsAt(0, 0).first, 42);
    });

    test('3×1：只有第 1、4、6 趟有内容，且顺序不是从左到右', () {
      // 三个像素分属三趟，写进文件的顺序是 x=0、x=2、x=1 —— 隔行图的
      // 字节顺序和像素的空间顺序没有关系。
      final RgbaImage img = decode(buildPng(
        width: 3,
        height: 1,
        bitDepth: 8,
        colorType: 0,
        raw: interlace(const <List<int>>[
          <int>[10, 11, 12],
        ]),
        interlace: 1,
      ));
      expect(
        List<int>.generate(3, (int x) => img.channelsAt(x, 0).first),
        <int>[10, 11, 12],
      );
    });

    test('每趟开头的「上一行」必须清零，不能沿用前一趟的末行', () {
      // 8×8 时第 1、2 趟各只有一行一字节。第 2 趟用 Up 滤波：它的「上一行」
      // 应当是全 0（本趟还没有行），于是重建值 = 滤波值 = 7。
      // 要是把第 1 趟的末行留在缓冲里当上一行，就会算成 200 + 7 = 207。
      // 两趟在空间上根本不相邻，沿用是没有意义的。
      final List<int> raw = <int>[
        0, 200, // 第 1 趟：None，像素 (0,0)
        2, 7, // 第 2 趟：Up，像素 (4,0)
        0, 0, 0, // 第 3 趟：1 行 2 字节
        0, 0, 0, 0, 0, 0, // 第 4 趟：2 行 2 字节
        for (int i = 0; i < 2; i++) ...<int>[0, 0, 0, 0, 0], // 第 5 趟
        for (int i = 0; i < 4; i++) ...<int>[0, 0, 0, 0, 0], // 第 6 趟
        for (int i = 0; i < 4; i++) ...<int>[0, 0, 0, 0, 0, 0, 0, 0, 0], // 第 7 趟
      ];
      final RgbaImage img = decode(buildPng(
        width: 8,
        height: 8,
        bitDepth: 8,
        colorType: 0,
        raw: raw,
        interlace: 1,
      ));
      expect(img.channelsAt(0, 0).first, 200);
      expect(
        img.channelsAt(4, 0).first,
        7,
        reason: '第 2 趟的上一行应为全 0，否则会得到 207',
      );
    });

    test('隔行图每趟各自补齐行末，总字节数比非隔行还多', () {
      // 1 位 8×8：非隔行是 8 行 × (1 字节 + 1 滤波字节) = 16 字节。
      // 隔行时七趟各自补齐到整字节，最窄的趟一行只有 1 个像素也要占满
      // 一个字节，于是总共 30 字节 —— 比不隔行差不多多了一倍。
      // 「隔行图更小」是个常见误解，实际正相反。
      final int woven = expectedRawSize(PngHeader.parse(ihdrData(
        width: 8,
        height: 8,
        bitDepth: 1,
        colorType: 0,
        interlace: 1,
      )));
      final int plain = expectedRawSize(PngHeader.parse(ihdrData(
        width: 8,
        height: 8,
        bitDepth: 1,
        colorType: 0,
      )));
      expect(plain, 16);
      expect(woven, 30);
    });
  });

  group('chunk 结构', () {
    /// 一张 2×2 红绿蓝白图，各种 chunk 花样都拿它当底子。
    Uint8List base({
      int idatSplit = 1,
      List<List<int>>? before,
      List<List<int>>? after,
      bool includeEnd = true,
    }) =>
        buildPng(
          width: 2,
          height: 2,
          bitDepth: 8,
          colorType: 2,
          raw: rawWithFilters(const <List<int>>[
            <int>[255, 0, 0, 0, 255, 0],
            <int>[0, 0, 255, 255, 255, 255],
          ]),
          idatSplit: idatSplit,
          extraChunksBeforeIdat: before,
          extraChunksAfterIdat: after,
          includeEnd: includeEnd,
        );

    void expectBase(RgbaImage img) {
      expectPixel(img, 0, 0, const <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, const <int>[0, 255, 0, 255]);
      expectPixel(img, 0, 1, const <int>[0, 0, 255, 255]);
      expectPixel(img, 1, 1, const <int>[255, 255, 255, 255]);
    }

    test('单个 IDAT', () {
      expectBase(decode(base()));
    });

    test('多个 IDAT：先拼接再解压', () {
      // 压缩流被切成 N 段分放在 N 个 IDAT 里。切点落在 deflate 流中间，
      // 所以必须先把所有 IDAT 的数据首尾相接，再整体交给 inflate ——
      // 逐个 IDAT 单独解压是解不出来的。真实的 PNG 编码器普遍分块输出。
      for (final int n in <int>[2, 3, 5]) {
        expectBase(decode(base(idatSplit: n)));
      }
    });

    test('IDAT 之间插了别的 chunk 被拒', () {
      // 规范要求所有 IDAT 连续。中间插东西意味着文件结构被改动过，
      // 拼接出来的字节流未必还是完整的 deflate 流。
      final Uint8List good = base(idatSplit: 2);
      // 手工重组：签名 + IHDR + 第一个 IDAT + tEXt + 第二个 IDAT + IEND。
      final List<int> parts = <int>[
        ...good.sublist(0, 8 + 25), // 签名 + IHDR（12 + 13）
      ];
      const int at = 8 + 25;
      final int len1 = good[at] * 16777216 +
          good[at + 1] * 65536 +
          good[at + 2] * 256 +
          good[at + 3];
      parts.addAll(good.sublist(at, at + 12 + len1)); // 第一个 IDAT
      parts.addAll(pngChunk('tEXt', const <int>[0x41, 0x00, 0x42]));
      parts.addAll(good.sublist(at + 12 + len1)); // 余下的 IDAT + IEND
      expect(
        () => decode(Uint8List.fromList(parts)),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('不连续'),
          ),
        ),
      );
    });

    test('认得的辅助 chunk 放在 IDAT 前后都行', () {
      final List<List<int>> aux = <List<int>>[
        pngChunk('gAMA', const <int>[0x00, 0x00, 0x0B, 0x13]),
        pngChunk('pHYs', const <int>[0, 0, 0x0B, 0x13, 0, 0, 0x0B, 0x13, 1]),
        pngChunk('tEXt', const <int>[0x41, 0x00, 0x42]), // "A\0B"
      ];
      expectBase(decode(base(before: aux)));
      expectBase(decode(base(after: aux)));
    });

    test('不认得的**辅助** chunk 跳过就好', () {
      // chunk 名第一个字母的大小写就是「关键/辅助」这一位：小写＝辅助，
      // 解码方不认识也能安全跳过。PNG 靠这个设计做到了向前兼容 ——
      // 后来新增的 iCCP、sRGB 之类都能被老解码器忽略。
      expectBase(decode(base(before: <List<int>>[
        pngChunk('bOgU', const <int>[1, 2, 3]),
        pngChunk('zzzz', const <int>[]),
      ])));
    });

    test('不认得的**关键** chunk 必须拒绝', () {
      // 大写＝关键：不认识就没法正确显示这张图，只能报错。硬跳过会
      // 悄悄画出一张错的图，比报错糟糕得多。
      expect(
        () => decode(base(before: <List<int>>[
          pngChunk('BOgU', const <int>[1, 2, 3]),
        ])),
        throwsA(isA<UnsupportedImageFeature>()),
      );
    });

    test('第二个 IHDR 被拒', () {
      expect(
        () => decode(base(before: <List<int>>[
          pngChunk(
            'IHDR',
            ihdrData(width: 2, height: 2, bitDepth: 8, colorType: 2),
          ),
        ])),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('第二个 IHDR'),
          ),
        ),
      );
    });

    test('第一个 chunk 不是 IHDR 被拒', () {
      // IHDR 必须第一个到 —— 后面所有 chunk 的解释都依赖它给出的宽高、
      // 位深、颜色类型。先读到别的 chunk 就无从下手。
      final Uint8List good = base();
      final List<int> parts = <int>[
        ...good.sublist(0, 8),
        ...pngChunk('tEXt', const <int>[0x41, 0x00, 0x42]),
        ...good.sublist(8),
      ];
      expect(
        () => decode(Uint8List.fromList(parts)),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('IHDR'),
          ),
        ),
      );
    });

    test('PLTE 出现在 IDAT 之后被拒', () {
      expect(
        () => decode(buildPng(
          width: 1,
          height: 1,
          bitDepth: 8,
          colorType: 3,
          raw: rawWithFilters(const <List<int>>[
            <int>[0],
          ]),
          extraChunksAfterIdat: <List<int>>[
            pngChunk('PLTE', const <int>[1, 2, 3]),
          ],
        )),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('IDAT 之前'),
          ),
        ),
      );
    });

    test('chunk 名的四个大小写位', () {
      // 四个字母各自的大小写是四个独立的标志位，不只是命名风格：
      //   第 1 位：大写＝关键，小写＝辅助
      //   第 2 位：大写＝公有，小写＝私有
      //   第 3 位：保留，规范要求必须大写
      //   第 4 位：大写＝改图后不可复制，小写＝可安全复制
      final PngChunkReader r = PngChunkReader(Uint8List.fromList(<int>[
        ...pngSignature,
        ...pngChunk('IHDR', ihdrData(width: 1, height: 1, bitDepth: 8, colorType: 0)),
        ...pngChunk('tEXt', const <int>[0x41]),
        ...pngChunk('prVt', const <int>[]),
      ]));

      final PngChunk ihdr = r.next();
      expect(ihdr.type, 'IHDR');
      expect(ihdr.isCritical, isTrue);
      expect(ihdr.isPrivate, isFalse);

      final PngChunk text = r.next();
      expect(text.type, 'tEXt');
      expect(text.isCritical, isFalse, reason: '首字母小写＝辅助');
      expect(text.isPrivate, isFalse, reason: '第二个字母大写＝公有');

      final PngChunk priv = r.next();
      expect(priv.isCritical, isFalse);
      expect(priv.isPrivate, isTrue, reason: '第二个字母小写＝私有');
      expect(r.hasMore, isFalse);
    });

    test('chunk 类型含非字母字符被拒', () {
      // 长度字段错了一位，读取位置就会错位，接着把像素数据当成 chunk
      // 类型读进来 —— 那几个字节几乎不可能全是字母。这个检查能把「错位」
      // 这件事在第一时间报出来，而不是继续读出一堆无意义的 chunk。
      expect(
        () => decode(base(before: <List<int>>[
          pngChunk('a1\x00!', const <int>[]),
        ])),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('非字母'),
          ),
        ),
      );
    });
  });

  group('残缺与损坏的输入', () {
    Uint8List good() => buildRgb8Png(const <List<int>>[
          <int>[1, 2, 3, 4, 5, 6],
          <int>[7, 8, 9, 10, 11, 12],
        ]);

    test('签名的八个字节逐个改坏都能被发现', () {
      for (int i = 0; i < 8; i++) {
        final Uint8List b = Uint8List.fromList(good());
        b[i] ^= 0xFF;
        expect(
          () => decode(b),
          throwsA(isA<ImageDecodeException>()),
          reason: '第 $i 个签名字节',
        );
      }
    });

    test('签名后半段是四种换行损坏的探针', () {
      // 0D 0A 1A 0A 不是随便挑的：CRLF→LF 会把 0D 吃掉，LF→CRLF 会
      // 多插一个 0D，0x1A 是 DOS 的文件结束符。以文本模式传输过的 PNG
      // 一定会在这四个字节上露出马脚。
      expect(good().sublist(0, 8),
          <int>[0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A]);

      // 模拟 CRLF→LF：删掉 0x0D。
      final List<int> stripped = <int>[...good()]..removeAt(4);
      expect(() => decode(Uint8List.fromList(stripped)),
          throwsA(isA<ImageDecodeException>()));

      // 模拟 LF→CRLF：在 0x0A 前插一个 0x0D。
      final List<int> inserted = <int>[...good()]..insert(5, 0x0D);
      expect(() => decode(Uint8List.fromList(inserted)),
          throwsA(isA<ImageDecodeException>()));
    });

    test('CRC 与数据不符被拒', () {
      // IHDR 的数据区在偏移 16 起（8 签名 + 4 长度 + 4 类型）。改掉一个
      // 字节但不重算 CRC —— 这正是 CRC 要抓的情况。
      final Uint8List b = Uint8List.fromList(good());
      b[16 + 3] ^= 0x01; // 宽度的最低字节
      expect(
        () => decode(b),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('CRC'),
          ),
        ),
      );
    });

    test('任意一个字节被改坏都不会静默出错', () {
      // 整个文件逐字节翻转，每一次都必须抛异常 —— 不能出现「读出一张
      // 看起来正常但其实是错的图」。CRC 覆盖了 chunk 的类型与数据，签名
      // 校验覆盖开头八字节，Adler-32 覆盖解压产物，三者合起来没有缝隙。
      final Uint8List src = good();
      for (int i = 0; i < src.length; i++) {
        final Uint8List b = Uint8List.fromList(src);
        b[i] ^= 0xFF;
        expect(
          () => decode(b),
          throwsA(isA<ImageDecodeException>()),
          reason: '第 $i 个字节（共 ${src.length} 字节）',
        );
      }
    });

    test('在任意位置截断都会被发现', () {
      final Uint8List src = good();
      for (int n = 1; n < src.length; n++) {
        expect(
          () => decode(Uint8List.fromList(src.sublist(0, n))),
          throwsA(isA<ImageDecodeException>()),
          reason: '截断到 $n 字节',
        );
      }
    });

    test('缺 IEND 被拒', () {
      // IEND 是文件完整性的标记。没有它说明传输或写入中断了 ——
      // 前面的数据也许能解，但不能假装文件是完整的。
      expect(
        () => decode(buildPng(
          width: 1,
          height: 1,
          bitDepth: 8,
          colorType: 2,
          raw: rawWithFilters(const <List<int>>[
            <int>[1, 2, 3],
          ]),
          includeEnd: false,
        )),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('IEND'),
          ),
        ),
      );
    });

    test('缺 IDAT 被拒', () {
      // 结构完整但没有任何图像数据。合法的 PNG 至少要有一个 IDAT，
      // 哪怕是 0×0 也不行 —— 宽高本身就不允许为 0。
      final Uint8List b = Uint8List.fromList(<int>[
        ...pngSignature,
        ...pngChunk('IHDR',
            ihdrData(width: 1, height: 1, bitDepth: 8, colorType: 2)),
        ...pngChunk('IEND', const <int>[]),
      ]);
      expect(
        () => decode(b),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('IDAT'),
          ),
        ),
      );
    });

    test('调色板图缺 PLTE 被拒', () {
      // 颜色类型 3 的像素只是索引，没有 PLTE 就无从知道每个索引是什么
      // 颜色。这是 PLTE 唯一必须存在的场合。
      expect(
        () => decode(buildPng(
          width: 1,
          height: 1,
          bitDepth: 8,
          colorType: 3,
          raw: rawWithFilters(const <List<int>>[
            <int>[0],
          ]),
        )),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('PLTE'),
          ),
        ),
      );
    });

  });

  group('IHDR 字段校验', () {
    /// 用任意 IHDR 字节组一张图，方便造各种非法头部。
    ///
    /// IDAT 里塞的原始数据是随便给的 —— 这些用例都该死在解析 IHDR 的
    /// 阶段，根本走不到解压那一步。
    Uint8List withIhdr(List<int> ihdr) => Uint8List.fromList(<int>[
          ...pngSignature,
          ...pngChunk('IHDR', ihdr),
          ...pngChunk('IDAT', storedZlib(const <int>[0, 0, 0, 0])),
          ...pngChunk('IEND', const <int>[]),
        ]);

    test('每种颜色类型只接受规范允许的位深', () {
      // 这张表是硬约束，不是建议值：
      //   0 灰度      1 2 4 8 16
      //   2 真彩色          8 16
      //   3 调色板    1 2 4 8
      //   4 灰度+A          8 16
      //   6 真彩+A          8 16
      // 真彩色没有低位深，因为三个通道各自低于 8 位没有实际意义；
      // 调色板没有 16 位，因为索引超过 256 项就失去了调色板的意义。
      const Map<int, List<int>> allowed = <int, List<int>>{
        0: <int>[1, 2, 4, 8, 16],
        2: <int>[8, 16],
        3: <int>[1, 2, 4, 8],
        4: <int>[8, 16],
        6: <int>[8, 16],
      };
      for (final int colorType in allowed.keys) {
        for (final int bitDepth in <int>[1, 2, 4, 8, 16]) {
          final bool ok = allowed[colorType]!.contains(bitDepth);
          final Uint8List b = withIhdr(ihdrData(
            width: 1,
            height: 1,
            bitDepth: bitDepth,
            colorType: colorType,
          ));
          if (ok) {
            // 合法组合不该死在 IHDR 上。数据量对不上是另一回事，
            // 所以这里只要求错误信息不提位深。
            try {
              decode(b);
            } on ImageDecodeException catch (e) {
              expect(e.message, isNot(contains('位深')),
                  reason: '颜色类型 $colorType + 位深 $bitDepth 应被接受');
            }
          } else {
            expect(
              () => decode(b),
              throwsA(isA<ImageDecodeException>()),
              reason: '颜色类型 $colorType + 位深 $bitDepth 应被拒',
            );
          }
        }
      }
    });

    test('颜色类型 1 和 5 不存在', () {
      // 颜色类型是三个标志位的组合：bit0 调色板、bit1 彩色、bit2 alpha。
      //   1 = 只有调色板位  → 调色板却没有颜色，讲不通
      //   5 = 调色板 + alpha → alpha 靠 tRNS 表达，不用第四个样本
      // 所以能用的只有 0、2、3、4、6，中间的空缺不是随意留的。
      for (final int colorType in <int>[1, 5, 7, 8, 255]) {
        expect(
          () => decode(withIhdr(ihdrData(
            width: 1,
            height: 1,
            bitDepth: 8,
            colorType: colorType,
          ))),
          throwsA(isA<ImageDecodeException>()),
          reason: '颜色类型 $colorType',
        );
      }
    });

    test('位深不是 2 的幂被拒', () {
      for (final int bitDepth in <int>[0, 3, 5, 6, 7, 9, 12, 32]) {
        expect(
          () => decode(withIhdr(ihdrData(
            width: 1,
            height: 1,
            bitDepth: bitDepth,
            colorType: 0,
          ))),
          throwsA(isA<ImageDecodeException>()),
          reason: '位深 $bitDepth',
        );
      }
    });

    test('压缩方法与滤波方法只能是 0', () {
      // 这两个字节三十年来始终只允许填 0。预留的扩展从没发生过，
      // 但解码方仍必须检查 —— 填了别的值说明文件不是这个规范的产物。
      expect(
        () => decode(withIhdr(ihdrData(
          width: 1,
          height: 1,
          bitDepth: 8,
          colorType: 0,
          compression: 1,
        ))),
        throwsA(isA<UnsupportedImageFeature>()),
      );
      expect(
        () => decode(withIhdr(ihdrData(
          width: 1,
          height: 1,
          bitDepth: 8,
          colorType: 0,
          filter: 1,
        ))),
        throwsA(isA<UnsupportedImageFeature>()),
      );
    });

    test('隔行方式只能是 0 或 1', () {
      for (final int interlace in <int>[2, 3, 255]) {
        expect(
          () => decode(withIhdr(ihdrData(
            width: 1,
            height: 1,
            bitDepth: 8,
            colorType: 0,
            interlace: interlace,
          ))),
          throwsA(isA<ImageDecodeException>()),
          reason: '隔行方式 $interlace',
        );
      }
    });

    test('IHDR 长度不是 13 被拒', () {
      // 长度对不上就没法按固定偏移取字段。多出来的字节也不能当扩展
      // 忽略 —— IHDR 是关键 chunk，它的语义不允许解码方猜。
      final List<int> ok = ihdrData(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 0,
      );
      expect(() => decode(withIhdr(ok.sublist(0, 12))),
          throwsA(isA<ImageDecodeException>()));
      expect(() => decode(withIhdr(<int>[...ok, 0])),
          throwsA(isA<ImageDecodeException>()));
      expect(() => decode(withIhdr(const <int>[])),
          throwsA(isA<ImageDecodeException>()));
    });

    test('宽或高为 0 被拒', () {
      // 0×0 的 PNG 在语法上完全合法：IHDR 长度对、CRC 对、IDAT 能解压出
      // 0 字节。但它没有像素，后面每一步除法都会出问题，所以在读到宽高
      // 的那一刻就拒掉。
      for (final List<int> wh in <List<int>>[
        <int>[0, 1],
        <int>[1, 0],
        <int>[0, 0],
      ]) {
        expect(
          () => decode(withIhdr(ihdrData(
            width: wh[0],
            height: wh[1],
            bitDepth: 8,
            colorType: 0,
          ))),
          throwsA(isA<ImageDecodeException>()),
          reason: '${wh[0]}x${wh[1]}',
        );
      }
    });

    test('声称的尺寸过大时立刻拒绝，不试图分配', () {
      // 这条用例的意义不在「拒绝」，而在「拒绝得足够早」。
      // 65535×65535 = 42.9 亿像素，×4 字节就是 17GB。若解码器先分配
      // 缓冲再校验，这个测试会把整个测试进程拖死而不是失败。
      //
      // 文件本身只有几十字节 —— 谎报尺寸的成本对攻击者几乎为零。
      final Uint8List bomb = withIhdr(ihdrData(
        width: kMaxImageDimension,
        height: kMaxImageDimension,
        bitDepth: 8,
        colorType: 6,
      ));
      expect(bomb.length, lessThan(100));
      expect(
        () => decode(bomb),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('像素总数'),
          ),
        ),
      );

      // 单边越界与总量越界是两条独立的判断，各有各的错误信息。
      expect(
        () => decode(withIhdr(ihdrData(
          width: kMaxImageDimension + 1,
          height: 1,
          bitDepth: 8,
          colorType: 0,
        ))),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('上限'),
          ),
        ),
      );
    });
  });

  group('数据量与校验和', () {
    // 一张 2×2 的 RGB8 图：每行 6 字节 + 1 字节滤波类型，共 14 字节。
    // 下面几个用例都围着这个 14 打转。
    List<int> rowsOf(int count) => List<List<int>>.generate(
          count,
          (int y) => <int>[1, 2, 3, 4, 5, 6],
        ).fold<List<int>>(<int>[], (List<int> acc, List<int> row) {
          acc.add(0);
          acc.addAll(row);
          return acc;
        });

    test('解压结果少于 IHDR 声称的字节数被拒', () {
      // 少了一行。这是「IHDR 说谎」的一种：宽高和数据量对不上。
      // 若不检查就会在读第二行时越界，或者更糟 —— 把上一行的残留
      // 当成图像内容，解出一张看似正常的图。
      expect(
        () => decode(buildPng(
          width: 2,
          height: 2,
          bitDepth: 8,
          colorType: 2,
          raw: rowsOf(1),
        )),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            allOf(contains('解压后数据量不符'), contains('应得 14 字节')),
          ),
        ),
      );
    });

    test('解压结果多于声称的字节数会撞上上限', () {
      // 多出来的数据不会被「宽容地忽略」。因为 sizeLimit 传的是精确值，
      // 解压在写第 15 个字节时就停了 —— 报的是解压炸弹，而不是数据量
      // 不符。两条错误信息不同，但拦截的是同一类畸形文件。
      expect(
        () => decode(buildPng(
          width: 2,
          height: 2,
          bitDepth: 8,
          colorType: 2,
          raw: rowsOf(3),
        )),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('解压炸弹'),
          ),
        ),
      );
    });

    test('Adler-32 与解压产物不符被拒', () {
      // 构造手法：deflate 流本身是对的、chunk 的 CRC 也是对的，只有
      // zlib 尾部的 Adler-32 算错了（这里故意拿另一串字节去算）。
      //
      // 于是这张图能通过签名检查、通过每个 chunk 的 CRC、解压出正好
      // 14 个字节 —— 唯一发现问题的是 Adler-32。这正是它存在的理由：
      // CRC 保护的是**压缩后**的字节，Adler-32 保护的是**解压后**的
      // 结果。压缩器自己出错时，只有后者能发现。
      final List<int> raw = rowsOf(2);
      final Uint8List badAdler = zlibWrap(
        storedDeflate(raw),
        <int>[...raw.sublist(0, raw.length - 1), raw.last ^ 0x01],
      );
      expect(
        () => decode(buildPng(
          width: 2,
          height: 2,
          bitDepth: 8,
          colorType: 2,
          raw: raw,
          compressedOverride: badAdler,
        )),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('Adler-32 校验失败'),
          ),
        ),
      );

      // 对照：同样的 deflate 流配上正确的 Adler-32 就能解开。
      // 两个用例只差尾部 4 字节，这样才能确认失败原因就是校验和。
      final RgbaImage img = decode(buildPng(
        width: 2,
        height: 2,
        bitDepth: 8,
        colorType: 2,
        raw: raw,
        compressedOverride: zlibWrap(storedDeflate(raw), raw),
      ));
      expectPixel(img, 0, 0, const <int>[1, 2, 3, 255]);
    });

    test('zlib 头部字段被校验', () {
      final List<int> raw = rowsOf(2);
      final Uint8List good = storedZlib(raw);

      Uint8List withHead(int cmf, int flg) => Uint8List.fromList(<int>[
            cmf,
            flg,
            ...good.sublist(2),
          ]);

      // CM 必须是 8。PNG 的压缩方法字段已经说了是 deflate，zlib 头里
      // 再写一遍 —— 两处冗余，但都得检查。
      expect(
        () => decode(buildPng(
          width: 2,
          height: 2,
          bitDepth: 8,
          colorType: 2,
          raw: raw,
          compressedOverride: withHead(0x79, 0x01),
        )),
        throwsA(isA<ImageDecodeException>()),
      );

      // (CMF*256 + FLG) 必须能被 31 整除。这是个校验位设计：改动头部
      // 任一字节，几乎必然破坏整除关系。
      expect(good[0] * 256 + good[1], (good[0] * 256 + good[1]) ~/ 31 * 31);
      expect(
        () => decode(buildPng(
          width: 2,
          height: 2,
          bitDepth: 8,
          colorType: 2,
          raw: raw,
          compressedOverride: withHead(good[0], good[1] ^ 0x02),
        )),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('元数据', () {
    test('基本字段照 IHDR 填写', () {
      final ImageMetadata m = decode(buildRgb8Png(const <List<int>>[
        <int>[1, 2, 3, 4, 5, 6],
        <int>[7, 8, 9, 10, 11, 12],
      ])).metadata;

      expect(m.format, 'PNG');
      expect(m.variant, '真彩色 RGB');
      expect(m.bitDepth, 8); // 每**采样**的位数，不是每像素的 24
      expect(m.channels, 3);
      expect(m.colorSpace, 'sRGB');
      expect(m.compression, 'deflate');
      expect(m.isLossless, isTrue);
    });

    test('位深与通道数取自采样而非像素', () {
      // 容易搞混的一对：RGBA16 的 bitDepth 是 16、channels 是 4，
      // 每像素 64 位。信息面板要显示的是前两个数字，不是 64。
      final ImageMetadata m = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 16,
        colorType: 6,
        raw: rawWithFilters(const <List<int>>[
          <int>[0, 1, 0, 2, 0, 3, 0, 4],
        ]),
      )).metadata;
      expect(m.bitDepth, 16);
      expect(m.channels, 4);
      expect(m.variant, '真彩色 RGBA');
    });

    test('调色板图的色彩空间注明来自调色板', () {
      final ImageMetadata m = decode(buildPng(
        width: 2,
        height: 1,
        bitDepth: 8,
        colorType: 3,
        raw: rawWithFilters(const <List<int>>[<int>[0, 1]]),
        palette: const <int>[10, 20, 30, 40, 50, 60],
      )).metadata;
      expect(m.colorSpace, '调色板（sRGB）');
      expect(m.channels, 1); // 一个索引就是一个采样
      expect(m.extra['调色板'], '2 项');
    });

    test('滤波器用量逐行统计', () {
      // 每行的滤波器是独立选的，所以摘要是「哪种用了几行」。
      // 真实编码器会逐行试五种、挑最省的，摘要因此往往是混合的。
      final ImageMetadata m = decode(buildPng(
        width: 3,
        height: 4,
        bitDepth: 8,
        colorType: 0,
        raw: <int>[
          0, 10, 20, 30, // none
          1, 10, 10, 10, // sub
          2, 0, 0, 0, //   up
          4, 0, 0, 0, //   paeth
        ],
      )).metadata;
      expect(m.extra['滤波器用量'], 'none×1, sub×1, up×1, paeth×1');
    });

    test('滤波器用量与 FilterStats 的摘要一致', () {
      // 单独测一遍 FilterStats，确认摘要格式不是解码器拼出来的。
      final FilterStats stats = FilterStats();
      stats.record(PngFilterType.none);
      for (int i = 0; i < 15; i++) {
        stats.record(PngFilterType.paeth);
      }
      expect(stats.summary, 'none×1, paeth×15');
      expect(stats.total, 16);
      expect(FilterStats().summary, '无'); // 零行时不该是空字符串
    });

    test('deflate 块类型与压缩率', () {
      final Uint8List png = buildRgb8Png(const <List<int>>[
        <int>[1, 2, 3, 4, 5, 6],
        <int>[7, 8, 9, 10, 11, 12],
      ]);
      final ImageMetadata m = decode(png).metadata;

      // 测试用的 PNG 一律用存储块，所以这里必然是 stored×1。
      expect(m.extra['deflate 块'], 'stored×1');
      expect(m.extra['解压后'], '14 字节'); // 2 行 × (6 + 1)
      expect(m.extra['压缩数据'], contains('1 个 IDAT'));

      // 存储块比原文还大（多了 zlib 头、块头、Adler-32），所以压缩率
      // 小于 1:1。这个方向的「压缩」是 deflate 的保底行为：无论数据多
      // 难压，最坏也只膨胀几个字节。
      final String ratio = m.extra['压缩率']! as String;
      expect(ratio, endsWith(':1'));
      expect(double.parse(ratio.split(':').first), lessThan(1.0));
    });

    test('隔行方式写进 variant 与 extra', () {
      final ImageMetadata plain = decode(buildRgb8Png(const <List<int>>[
        <int>[1, 2, 3],
      ])).metadata;
      expect(plain.extra['隔行方式'], '无');
      expect(plain.variant, '真彩色 RGB');

      // 1×1 的 Adam7 图：只有第 1 遍有内容，其余六遍连滤波字节都没有。
      final ImageMetadata woven = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        interlace: 1,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
      )).metadata;
      expect(woven.extra['隔行方式'], 'Adam7 隔行');
      expect(woven.variant, '真彩色 RGB + Adam7 隔行');
    });

    test('只有真的解出透明像素才标透明', () {
      // 「有 alpha 通道」和「有透明像素」是两件事。全不透明的 RGBA 图
      // 不该被标成透明 —— 信息面板上这一行是给用户看的事实，不是
      // 格式能力的声明。
      final ImageMetadata opaque = decode(buildPng(
        width: 2,
        height: 1,
        bitDepth: 8,
        colorType: 6,
        raw: rawWithFilters(const <List<int>>[
          <int>[1, 2, 3, 255, 4, 5, 6, 255],
        ]),
      )).metadata;
      expect(opaque.extra.containsKey('透明像素'), isFalse);

      final ImageMetadata seeThrough = decode(buildPng(
        width: 2,
        height: 1,
        bitDepth: 8,
        colorType: 6,
        raw: rawWithFilters(const <List<int>>[
          <int>[1, 2, 3, 255, 4, 5, 6, 0],
        ]),
      )).metadata;
      expect(seeThrough.extra['透明像素'], '有');
    });

    test('关键色透明记录成可读文字', () {
      // 灰度关键色。tRNS 恒为 16 位大端，即使图是 8 位的。
      final ImageMetadata gray = decode(buildPng(
        width: 2,
        height: 1,
        bitDepth: 8,
        colorType: 0,
        raw: rawWithFilters(const <List<int>>[<int>[7, 9]]),
        transparency: const <int>[0, 7],
      )).metadata;
      expect(gray.extra['关键色透明'], 'PngColorKey(灰度 7)');
      expect(gray.extra['透明像素'], '有');

      // RGB 关键色：三个 16 位样本，六字节。
      final ImageMetadata rgb = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        transparency: const <int>[0, 1, 0, 2, 0, 3],
      )).metadata;
      expect(rgb.extra['关键色透明'], 'PngColorKey(RGB 1,2,3)');
    });

    test('chunk 数把 IHDR 与 IEND 都算进去', () {
      // 最少的合法 PNG 是三个 chunk：IHDR + IDAT + IEND。
      final ImageMetadata bare = decode(buildRgb8Png(const <List<int>>[
        <int>[1, 2, 3],
      ])).metadata;
      expect(bare.extra['chunk 数'], 3);

      // 多个 IDAT 各算一个 chunk，但压缩数据只有一条流。
      final ImageMetadata split = decode(buildPng(
        width: 4,
        height: 4,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(List<List<int>>.filled(4, List<int>.filled(12, 9))),
        idatSplit: 3,
      )).metadata;
      expect(split.extra['chunk 数'], 5); // IHDR + 3×IDAT + IEND
      expect(split.extra['压缩数据'], contains('3 个 IDAT'));
    });

    test('gAMA 换算成小数', () {
      // gAMA 存的是 gamma × 100000 的定点数。45455 就是老资料里常见的
      // 1/2.2 ≈ 0.45455 —— 图像数据已经做过 2.2 次幂编码。
      final ImageMetadata m = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        extraChunksBeforeIdat: <List<int>>[pngChunk('gAMA', u32be(45455))],
      )).metadata;
      expect(m.extra['gAMA'], '0.45455');
    });

    test('pHYs 换算成 DPI', () {
      // 3780 像素/米 ≈ 96 DPI（3780 / 39.3701）。单位字节为 1 表示米，
      // 为 0 表示「未指定」—— 那时两个数字只能表达宽高比。
      final ImageMetadata dpi = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        extraChunksBeforeIdat: <List<int>>[
          pngChunk('pHYs', <int>[...u32be(3780), ...u32be(3780), 1]),
        ],
      )).metadata;
      expect(dpi.extra['pHYs'], '3780×3780 像素/米（约 96×96 DPI）');

      final ImageMetadata ratio = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        extraChunksBeforeIdat: <List<int>>[
          pngChunk('pHYs', <int>[...u32be(1), ...u32be(2), 0]),
        ],
      )).metadata;
      expect(ratio.extra['pHYs'], '1×2（单位未指定，仅表示宽高比）');
    });

    test('tEXt 按 NUL 分隔取出关键字与内容', () {
      // 格式是 `关键字\0文本`，两段都是 Latin-1（不是 UTF-8 —— 想放
      // 别的编码得用 iTXt）。关键字最长 79 字节，且不能为空。
      final ImageMetadata m = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        extraChunksBeforeIdat: <List<int>>[
          pngChunk('tEXt', <int>[...ascii('Software'), 0, ...ascii('ImageViewer')]),
          pngChunk('tEXt', <int>[...ascii('Comment'), 0, ...ascii('hand-built')]),
        ],
      )).metadata;
      expect(m.extra['tEXt:Software'], 'ImageViewer');
      expect(m.extra['tEXt:Comment'], 'hand-built');
    });

    test('过长的 tEXt 被截断，畸形的被忽略', () {
      final ImageMetadata m = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        extraChunksBeforeIdat: <List<int>>[
          pngChunk('tEXt', <int>[...ascii('Long'), 0, ...ascii('x' * 200)]),
          // 没有 NUL 分隔符。辅助 chunk 的内容不值得中断整个解码 ——
          // 一条元数据坏了不影响像素，静默跳过是对的取舍。
          pngChunk('tEXt', ascii('NoSeparator')),
        ],
      )).metadata;
      expect(m.extra['tEXt:Long'], '${'x' * 120}…');
      expect(
        m.extra.keys.where((String k) => k.startsWith('tEXt:')).length,
        1,
      );
    });

    test('不认识的辅助 chunk 只记类型名', () {
      final ImageMetadata m = decode(buildPng(
        width: 1,
        height: 1,
        bitDepth: 8,
        colorType: 2,
        raw: rawWithFilters(const <List<int>>[<int>[1, 2, 3]]),
        extraChunksBeforeIdat: <List<int>>[
          pngChunk('sBIT', const <int>[8, 8, 8]),
          pngChunk('myPr', const <int>[1]), // 第二字母小写 = 私有
        ],
      )).metadata;
      expect(m.extra['其他 chunk'], 'sBIT, myPr（私有）');
    });
  });

  // docs/formats/png.md 末尾那段十六进制转储就是这 82 个字节。文档里逐字节
  // 标注了每个字段的含义，只要有人改了解码器而这段不再解得出预期结果，
  // 文档就已经错了 —— 所以把它钉在测试里，而不是只写在 Markdown 上。
  //
  // 刻意用 stored 块（BTYPE=00）：这样 IDAT 里的 14 个像素字节在转储里
  // 肉眼可读，读者能自己对着数。真实文件当然是压缩的。
  group('文档里那张 2×2 的例图', () {
    /// docs/formats/png.md「字节级实例」一节的完整文件。
    final Uint8List docExample = Uint8List.fromList(const <int>[
      // 签名
      0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A,
      // IHDR：长度 13、类型、2×2、位深 8、类型 2、压缩 0、滤波 0、隔行 0、CRC
      0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52,
      0x00, 0x00, 0x00, 0x02, 0x00, 0x00, 0x00, 0x02,
      0x08, 0x02, 0x00, 0x00, 0x00, 0xFD, 0xD4, 0x9A, 0x73,
      // IDAT：长度 25、类型
      0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54,
      // zlib 头 78 01；stored 块头 01 + LEN 0E00 + NLEN F1FF
      0x78, 0x01, 0x01, 0x0E, 0x00, 0xF1, 0xFF,
      // 第 0 行：filter 0 + 蓝 + 白
      0x00, 0x00, 0x00, 0xFF, 0xFF, 0xFF, 0xFF,
      // 第 1 行：filter 0 + 红 + 绿
      0x00, 0xFF, 0x00, 0x00, 0x00, 0xFF, 0x00,
      // Adler-32（大端）+ chunk 的 CRC-32
      0x2D, 0xE0, 0x05, 0xFB, 0x1C, 0x47, 0xEB, 0xB5,
      // IEND：长度 0、类型、CRC
      0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44,
      0xAE, 0x42, 0x60, 0x82,
    ]);

    test('总长 82 字节 —— 12 字节的 chunk 开销收了三次', () {
      expect(docExample.length, 82);
      // 8 签名 + (12+13) IHDR + (12+25) IDAT + (12+0) IEND
      expect(8 + 25 + 37 + 12, 82);
    });

    test('四个角的颜色和文档里画的一致', () {
      final RgbaImage img = decode(docExample);
      expect(img.width, 2);
      expect(img.height, 2);
      expectPixel(img, 0, 0, const <int>[0, 0, 255, 255], reason: '左上蓝');
      expectPixel(img, 1, 0, const <int>[255, 255, 255, 255], reason: '右上白');
      expectPixel(img, 0, 1, const <int>[255, 0, 0, 255], reason: '左下红');
      expectPixel(img, 1, 1, const <int>[0, 255, 0, 255], reason: '右下绿');
    });

    test('和同内容的 BMP 例图相比，PNG 的行里没有填充字节', () {
      // bmp.md 的例图是同样的 2×2，那边一行 6 字节要补到 8。
      // PNG 这边一行是 1 字节 filter + 6 字节像素 = 7，不补齐。
      final ImageMetadata m = decode(docExample).metadata;
      expect(m.extra['解压后'], '14 字节'); // 2 × (1 + 6)
      expect(m.extra['deflate 块'], 'stored×1');
      expect(m.extra['滤波器用量'], 'none×2');
      expect(m.extra['chunk 数'], 3);
    });

    test('改动任意一个字节都会被两道校验之一抓住', () {
      // 挑三个位置：IHDR 的宽度、IDAT 的像素字节、IEND 的类型名。
      for (final int at in <int>[19, 50, 76]) {
        final Uint8List broken = Uint8List.fromList(docExample);
        broken[at] ^= 0xFF;
        expect(
          () => decode(broken),
          throwsA(isA<ImageDecodeException>()),
          reason: '第 $at 字节被改动后仍然解码成功了',
        );
      }
    });
  });
}
