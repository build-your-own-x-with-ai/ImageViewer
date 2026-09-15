/// `assets/samples/` 下内置样图的端到端测试。
///
/// ## 这个测试在测什么
///
/// 样图由 `tool/gen_samples.dart` 逐字节写出，那个脚本**不 import 项目里
/// 任何解码代码**。所以这里是两套独立实现的交叉验证：生成器按规范写字节，
/// 解码器按规范读字节，两边对上了才说明两边都对。
///
/// 关键纪律：下面所有期望值都是**手算的字面量**，不是用生成器的公式重算的。
/// 一旦写成 `expect(px, computeGradient(x, y))`，就等于把生成器的逻辑复制
/// 了一遍 —— 公式错了两边一起错，测试照样绿。
///
/// ## 顺带守住两件事
///
/// 1. 样图文件被误删、被改坏、或者生成参数变了而忘了更新测试，立刻暴露。
/// 2. Web 与移动端拿不到本地文件系统，这些内置样图是那些平台上唯一的图片
///    来源。它们坏了，UI 上就什么都看不到。
///
/// 无损格式一律 `tolerance: 0`。只有 YUV 允许容差 —— 8 位 limited range
/// 往返本身就是有损的，详见下面 YUV 那一组的注释。
library;

import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_decoder.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_decoder.dart';
import 'package:image_viewer/src/codecs/png/png_decoder.dart';
import 'package:image_viewer/src/codecs/pnm/pnm_decoder.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_color.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_decoder.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_format.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_options.dart';
import 'package:image_viewer/src/core/decoder_registry.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';
import 'package:image_viewer/src/services/decode_service.dart';

import '../support/pixel_matchers.dart';

const BmpDecoder bmpDecoder = BmpDecoder();
const PngDecoder pngDecoder = PngDecoder();
const PnmDecoder pnmDecoder = PnmDecoder();
const YuvDecoder yuvDecoder = YuvDecoder();
const JpegDecoder jpegDecoder = JpegDecoder();

/// 读一个样图。`flutter test` 的工作目录是包根目录，所以相对路径可用。
Uint8List load(String name) =>
    File('assets/samples/$name').readAsBytesSync();

/// 读一份 djpeg 参考并解出来。这些 PNM 不进 assets/ —— 它们只服务测试，
/// 打进 App 包只是白占体积。
RgbaImage loadExpected(String name) =>
    pnmDecoder.decode(File('test/assets/expected/$name').readAsBytesSync());

/// 有 djpeg 参考的那五张样图（不含 EXIF 那张，它复用 q75_420 的参考）。
const List<String> jpegExpectedPnm = <String>[
  'gradient_64x32_q85_gray.pnm',
  'gradient_64x48_q75_420.pnm',
  'gradient_64x48_q80_422rst.pnm',
  'gradient_64x48_q80_prog.pnm',
  'gradient_64x48_q90_444.pnm',
];

/// 两行像素是否完全相同。
///
/// 用来判断「这幅图是不是斜的」：内容只跟 x 有关的图，任意两行都该相同。
bool _rowsEqual(RgbaImage img, int y1, int y2) {
  for (int x = 0; x < img.width; x++) {
    final List<int> a = img.channelsAt(x, y1);
    final List<int> b = img.channelsAt(x, y2);
    for (int c = 0; c < 4; c++) {
      if (a[c] != b[c]) {
        return false;
      }
    }
  }
  return true;
}

void main() {
  group('清单完整性', () {
    // 这一组防的是「样图没生成」和「文件名改了但引用没跟上」。
    // 后面每一组都假定文件存在，所以这个检查放最前面。
    const List<String> expected = <String>[
      'bands_80x32_rle8.bmp',
      'checker_20x16.pbm',
      'checker_35x24_gray1.png',
      'circle_64x64_32bpp.bmp',
      'colorbars_96x64_i420_3frames.yuv',
      'disc_64x64_rgba8.png',
      'gradient_61x40_24bpp.bmp',
      'gradient_64x32.pgm',
      'gradient_64x32_q85_gray.jpg',
      'gradient_64x48.ppm',
      'gradient_64x48_exif6.jpg',
      'gradient_64x48_q75_420.jpg',
      'gradient_64x48_q80_422rst.jpg',
      'gradient_64x48_q80_prog.jpg',
      'gradient_64x48_q90_444.jpg',
      'gradient_96x64_rgb8.png',
      'hues_64x48_palette8.png',
      'rainbow_128x40_8bpp.bmp',
      'ramp_16x8_ascii.pgm',
      'ramp_64x64_gray16.png',
      'ring_16x16_ascii.pbm',
      'rings_64x64_adam7.png',
      'tiny_8x8_ascii.ppm',
      'topdown_61x40_24bpp.bmp',
    ];

    test('24 个样图都在，且都不是空文件', () {
      for (final String name in expected) {
        // JPEG 那六张由 tool/gen_jpeg_samples.sh 产出（cjpeg 压的），
        // 其余由 tool/gen_samples.dart 逐字节写出。缺哪张就跑对应的那个。
        final String how = name.endsWith('.jpg')
            ? 'bash tool/gen_jpeg_samples.sh'
            : 'dart run tool/gen_samples.dart';
        final File f = File('assets/samples/$name');
        expect(f.existsSync(), isTrue, reason: '缺少样图 $name —— 跑一下 $how');
        expect(f.lengthSync(), greaterThan(0), reason: '$name 是空文件');
      }
    });

    test('5 份 djpeg 参考都在', () {
      // JPEG 是有损的，期望值没法写成手算字面量（见 tool/gen_jpeg_samples.sh
      // 开头的说明），所以改成和 libjpeg-turbo 的解码结果逐通道比。
      for (final String name in jpegExpectedPnm) {
        final File f = File('test/assets/expected/$name');
        expect(f.existsSync(), isTrue,
            reason: '缺少参考 $name —— 跑一下 bash tool/gen_jpeg_samples.sh');
        expect(f.lengthSync(), greaterThan(0), reason: '$name 是空文件');
      }
    });

    test('目录里没有多余文件', () {
      // 多出来的文件通常是手动丢进去的（比如从网上下的图）。
      // 那种文件不受生成器管，换台机器就可能不在，测试会莫名其妙地挂。
      final List<String> actual = Directory('assets/samples')
          .listSync()
          .whereType<File>()
          .map((File f) => f.uri.pathSegments.last)
          .where((String n) => !n.startsWith('.')) // .gitkeep
          .toList()
        ..sort();
      expect(actual, expected);
    });
  });

  group('BMP 24bpp 渐变（自底向上）', () {
    // 生成器自底向上写：先写 y=39 那行。所以文件第 0 行是图像最后一行，
    // 解码器必须把它放回最下面。方向搞反了下面三个断言全错。
    //
    // 每个像素：B = round(255·y/39)，G = round(255·x/60)，R = 128。
    late final RgbaImage img = bmpDecoder.decode(load('gradient_61x40_24bpp.bmp'));

    test('尺寸与元数据', () {
      expect(img.width, 61);
      expect(img.height, 40);
      expect(img.metadata.format, 'BMP');
      expect(img.metadata.bitDepth, 24);
      expect(img.metadata.isLossless, isTrue);
    });

    test('四角与中心的像素值', () {
      // 左上：y=0 → B=0；x=0 → G=0
      expectPixel(img, 0, 0, <int>[128, 0, 0, 255], reason: '左上角');
      // 右下：y=39 → B=255；x=60 → G=255
      expectPixel(img, 60, 39, <int>[128, 255, 255, 255], reason: '右下角');
      // 右上：G 满、B 空 —— 跟左下正好互换，能查出行列搞混
      expectPixel(img, 60, 0, <int>[128, 255, 0, 255], reason: '右上角');
      expectPixel(img, 0, 39, <int>[128, 0, 255, 255], reason: '左下角');
      // 中心：round(255·20/39)=131，round(255·30/60)=128
      expectPixel(img, 30, 20, <int>[128, 128, 131, 255]);
    });

    test('宽度 61 → 行末有 1 字节填充，且填充没被当成像素', () {
      // 61 像素 × 3 字节 = 183，对齐到 4 的倍数是 184。每行多 1 个填充字节。
      // 行跨距算成 183 的话，第 1 行就会整体左移 1 字节 —— 也就是错位 1/3
      // 个像素，通道会串（B 读到上一行的 R），整幅图斜着扭过去。
      //
      // 所以这里查每一行的最后一个像素：它紧挨填充字节，最先出问题。
      for (int y = 0; y < img.height; y++) {
        final int b = (255 * y / 39).round();
        expectPixel(img, 60, y, <int>[128, 255, b, 255],
            reason: '第 $y 行最后一个像素 —— 行跨距应为 184 而不是 183');
      }
    });
  });

  group('BMP 24bpp 自顶向下（负高度）', () {
    // 内容跟上一张上下颠倒地写，但标了负高度。解出来应该跟上一张一模一样。
    late final RgbaImage topDown =
        bmpDecoder.decode(load('topdown_61x40_24bpp.bmp'));

    test('逐像素等于自底向上那张', () {
      // 最强的断言：两种存储方向、同一幅图像。
      // 负高度没处理的话这里会报出上下翻转（第 0 行对上第 39 行）。
      final RgbaImage bottomUp =
          bmpDecoder.decode(load('gradient_61x40_24bpp.bmp'));
      expectImageMatches(topDown, bottomUp,
          reason: '负高度表示自顶向下，解出来的图像应与自底向上版本一致');
    });

    test('两个文件的字节数相同但内容不同', () {
      // 确认这不是同一份数据复制两遍 —— 那样上面那条断言就没意义了。
      final Uint8List a = load('gradient_61x40_24bpp.bmp');
      final Uint8List b = load('topdown_61x40_24bpp.bmp');
      expect(a.length, b.length, reason: '同尺寸同位深，文件大小应相同');
      expect(a, isNot(b), reason: '像素行的写入顺序相反，字节应该不同');
    });
  });

  group('BMP 8bpp 调色板（256 色彩虹）', () {
    // 每个像素存的是**索引**，颜色要去调色板里查。索引 = x·2（宽 128、
    // 用满 256 项），调色板第 i 项是 hue = i·360/256 的饱和色。
    //
    // 调色板本身是 BGRA 顺序、第四字节保留为 0。解码器要把它当保留位
    // 忽略、alpha 一律填 255 —— 拿它当 alpha 用的话整幅图全透明。
    late final RgbaImage img = bmpDecoder.decode(load('rainbow_128x40_8bpp.bmp'));

    test('尺寸与元数据', () {
      expect(img.width, 128);
      expect(img.height, 40);
      expect(img.metadata.bitDepth, 8);
      expect(img.metadata.colorSpace, '调色板索引');
    });

    test('调色板查表：色相 0/180/270 三处取值精确', () {
      // 挑 60 的倍数 —— HSV→RGB 在那些角度上没有插值，值是精确的整数。
      expectPixel(img, 0, 0, <int>[255, 0, 0, 255], reason: 'x=0 → 索引 0 → 红');
      expectPixel(img, 64, 0, <int>[0, 255, 255, 255],
          reason: 'x=64 → 索引 128 → 色相 180 → 青');
      expectPixel(img, 96, 0, <int>[128, 0, 255, 255],
          reason: 'x=96 → 索引 192 → 色相 270 → 紫');
    });

    test('相邻索引的颜色不同 —— 查表错一格就能查出来', () {
      // x=1 取索引 2（色相 2.8125），而索引 1 是色相 1.40625。
      // 两者 G 通道差 6，容差 0 下足以区分。查表偏一格这里就红了。
      expectPixel(img, 1, 0, <int>[255, 12, 0, 255],
          reason: 'x=1 → 索引 2，不是索引 1 的 [255, 6, 0]');
      expectPixel(img, 127, 0, <int>[255, 0, 12, 255],
          reason: 'x=127 → 索引 254 → 色相 357.1875');
    });

    test('alpha 全为 255 —— 调色板保留字节不能当 alpha 用', () {
      // 这条单独立出来：保留字节是 0，误当 alpha 就是整幅图全透明。
      // 那种 bug 在深色背景上"看起来只是图没显示"，很难定位。
      for (int y = 0; y < img.height; y++) {
        for (int x = 0; x < img.width; x++) {
          expect(img.channelsAt(x, y)[3], 255,
              reason: '($x, $y) 的 alpha 应为 255');
        }
      }
      expect(img.hasTransparency, isFalse);
    });

    test('所有行完全相同 —— 颜色只跟 x 有关', () {
      // 生成器里颜色只由 x 决定。任何行间差异都说明行跨距或翻转出了问题。
      for (int y = 1; y < img.height; y++) {
        for (int x = 0; x < img.width; x++) {
          expect(img.channelsAt(x, y), img.channelsAt(x, 0),
              reason: '第 $y 行与第 0 行不同（x=$x）');
        }
      }
    });
  });

  group('BMP RLE8 游程编码（水平色带）', () {
    // 16 条水平色带，每行编码成一整条游程：[80, 索引] 再跟一个 EOL。
    // 解码行 oy 用调色板第 oy~/2 项；palette[i] 是 hue=i·22.5、s=0.85、v=0.95。
    late final RgbaImage img = bmpDecoder.decode(load('bands_80x32_rle8.bmp'));

    test('尺寸与压缩方式', () {
      expect(img.width, 80);
      expect(img.height, 32);
      expect(img.metadata.bitDepth, 8);
      expect(img.metadata.compression, 'RLE8 游程编码');
    });

    test('色带颜色与行号对应', () {
      expectPixel(img, 0, 0, <int>[242, 36, 36, 255], reason: '第 0 行 → 索引 0');
      expectPixel(img, 0, 2, <int>[242, 114, 36, 255], reason: '第 2 行 → 索引 1');
      expectPixel(img, 0, 16, <int>[36, 242, 242, 255],
          reason: '第 16 行 → 索引 8 → 色相 180');
      expectPixel(img, 0, 31, <int>[242, 36, 114, 255], reason: '第 31 行 → 索引 15');
    });

    test('每行都是一整条纯色游程', () {
      // 游程长度处理错了就会出现「半行有色、半行是黑」。逐行扫过去。
      for (int y = 0; y < img.height; y++) {
        final List<int> first = img.channelsAt(0, y);
        for (int x = 1; x < img.width; x++) {
          expect(img.channelsAt(x, y), first,
              reason: '第 $y 行第 $x 列与行首不同 —— 游程没铺满整行');
        }
      }
    });

    test('相邻两行同色、隔两行换色', () {
      // index = y~/2，所以第 0/1 行同色、第 2/3 行同色，但第 1 与第 2 行不同。
      // EOL 少吃或多吃一行，这个「两行一组」的节奏立刻乱掉。
      for (int y = 0; y < img.height; y += 2) {
        expect(img.channelsAt(0, y), img.channelsAt(0, y + 1),
            reason: '第 $y 行与第 ${y + 1} 行应同色');
      }
      for (int y = 0; y < img.height - 2; y += 2) {
        expect(img.channelsAt(0, y), isNot(img.channelsAt(0, y + 2)),
            reason: '第 $y 行与第 ${y + 2} 行应换色');
      }
    });
  });

  group('BMP 32bpp 带 alpha（羽化圆）', () {
    // 圆心 (32.5, 32.5)，半径 26，边缘 6 像素线性羽化到全透明。
    // 颜色按角度取色相、按距离取饱和度 —— 是个色轮。
    //
    // 这里刻意不写死羽化区的具体 alpha 值：那些值由 hypot 的浮点结果
    // 四舍五入而来，手算容易在 .5 附近判断错。改成断言**结构性质**
    // （单调、有中间值、两端精确），既守得住又不脆。
    late final RgbaImage img = bmpDecoder.decode(load('circle_64x64_32bpp.bmp'));

    test('尺寸与元数据', () {
      expect(img.width, 64);
      expect(img.height, 64);
      expect(img.metadata.bitDepth, 32);
      expect(img.metadata.channels, 4);
      expect(img.hasTransparency, isTrue, reason: '这张图就是为了测半透明');
    });

    test('圆心不透明、四角全透明', () {
      expect(img.channelsAt(32, 32)[3], 255, reason: '圆心在实心区内');
      for (final List<int> c in <List<int>>[
        <int>[0, 0],
        <int>[63, 0],
        <int>[0, 63],
        <int>[63, 63],
      ]) {
        expect(img.channelsAt(c[0], c[1])[3], 0,
            reason: '角点 (${c[0]}, ${c[1]}) 距圆心约 44.5，远在半径 26 之外');
      }
    });

    test('圆心接近白色 —— 饱和度随距离趋于 0', () {
      // 距离 0.707 / 26 ≈ 0.027，饱和度几乎为 0，于是三通道都接近 255。
      // 这条能查出通道错位：如果 R/B 互换了，圆心仍然是白的看不出来，
      // 但下一条的色相分布会变 —— 两条合起来才完整。
      final List<int> c = img.channelsAt(32, 32);
      for (int i = 0; i < 3; i++) {
        expect(c[i], greaterThanOrEqualTo(240),
            reason: '圆心第 $i 通道应接近 255，实际 ${c[i]}');
      }
    });

    test('alpha 沿半径单调递增（自外向内）', () {
      // x=32 这一列，y 从 0 走到 31 是距圆心越来越近，alpha 只能升不能降。
      // 上下翻转或行跨距错了，这条单调性立刻破掉。
      int prev = -1;
      for (int y = 0; y <= 31; y++) {
        final int a = img.channelsAt(32, y)[3];
        expect(a, greaterThanOrEqualTo(prev),
            reason: '(32, $y) 的 alpha $a 比上一行的 $prev 还小');
        prev = a;
      }
      expect(prev, 255, reason: 'y=31 已进入实心区');
    });

    test('羽化区真的有中间 alpha 值', () {
      // 全 0 / 全 255 两种极端测不出混合是否正确。这条确认样图里确实有
      // 一圈半透明像素 —— 否则棋盘格背景那个功能就没有素材可测。
      int partial = 0;
      for (int y = 0; y < img.height; y++) {
        for (int x = 0; x < img.width; x++) {
          final int a = img.channelsAt(x, y)[3];
          if (a > 0 && a < 255) {
            partial++;
          }
        }
      }
      // 半径 20–26 那一圈的面积约 860 像素，取 300 作下限留足余量。
      expect(partial, greaterThan(300),
          reason: '只找到 $partial 个半透明像素，羽化环太窄或没生成');
    });
  });

  group('PNM P6 二进制彩色渐变', () {
    // PNM 跟 BMP 相反，是**自顶向下**的，所以不需要翻转。
    // R = round(255·x/63)，G = round(255·y/47)，B 固定 96。
    // B 取 96 而不是 0：全 0 的通道分不清"没读"和"读到 0"。
    late final RgbaImage img = pnmDecoder.decode(load('gradient_64x48.ppm'));

    test('尺寸与元数据', () {
      expect(img.width, 64);
      expect(img.height, 48);
      expect(img.metadata.format, 'PNM');
      expect(img.metadata.variant, startsWith('P6'));
      expect(img.metadata.bitDepth, 8);
    });

    test('四角与中心，且方向没有翻转', () {
      expectPixel(img, 0, 0, <int>[0, 0, 96, 255], reason: '左上');
      expectPixel(img, 63, 47, <int>[255, 255, 96, 255], reason: '右下');
      // 这两个角互换才是翻转的症状 —— 上面两条对称，单看查不出来。
      expectPixel(img, 63, 0, <int>[255, 0, 96, 255], reason: '右上：R 满 G 空');
      expectPixel(img, 0, 47, <int>[0, 255, 96, 255], reason: '左下：R 空 G 满');
      expectPixel(img, 32, 24, <int>[130, 130, 96, 255]);
    });

    test('头部里的注释被跳过了', () {
      // 头部是 `P6\n# ...\n64 48\n255\n`。注释没跳过的话宽高会解析成
      // 注释里的字符，尺寸直接就不对 —— 上面的断言已经覆盖。
      // 这里再确认一次 B 通道：注释多吃或少吃一个字节，像素数据整体错位，
      // B 就不再是 96。
      for (int y = 0; y < img.height; y += 8) {
        expect(img.channelsAt(0, y)[2], 96,
            reason: '(0, $y) 的 B 应为 96 —— 不是 96 说明像素数据起点算错了');
      }
    });
  });

  group('PNM P3 ASCII 彩色', () {
    // 8×8，颜色是 hsvToRgb(i·5.625, 0.9, 1.0)，i = x + y·8。
    // 故意做得小，能直接用文本编辑器打开看每个数字。
    late final RgbaImage img = pnmDecoder.decode(load('tiny_8x8_ascii.ppm'));

    test('尺寸与变体', () {
      expect(img.width, 8);
      expect(img.height, 8);
      expect(img.metadata.variant, startsWith('P3'));
    });

    test('逐像素取值', () {
      // s=0.9 而不是 1.0，所以最小通道不是 0，三个通道都非零 ——
      // 任何通道错位都藏不住。
      //
      // 最小通道是 **25**，不是手算的 round(0.1·255)=26。原因是浮点：
      // IEEE754 里 1.0 - 0.9 = 0.09999999999999998，乘 255 得 25.4999…，
      // 四舍五入到 25。这不是 bug，是二进制浮点表示不了 0.1。
      //
      // 期望值取自文件里的实际数字（P3 是 ASCII，直接打开就能看），
      // 不是重算公式得来的 —— 重算就会重犯同一个理想化错误。
      expectPixel(img, 0, 0, <int>[255, 25, 25, 255], reason: 'i=0 → 色相 0');
      expectPixel(img, 1, 0, <int>[255, 47, 25, 255], reason: 'i=1 → 色相 5.625');
      expectPixel(img, 0, 1, <int>[255, 198, 25, 255], reason: 'i=8 → 色相 45');
      // 跟 (1,0) 正好 G/B 互换 —— 通道顺序错了这条会红而 (0,0) 不会
      // （(0,0) 的 G 与 B 相等，互换看不出来）。
      expectPixel(img, 7, 7, <int>[255, 25, 47, 255], reason: 'i=63 → 色相 354.375');
    });

    test('ASCII 与二进制解出同样的东西', () {
      // P3 和 P6 是同一份数据的两种写法。这里不比较像素（两张图内容不同），
      // 只确认两条码路都能正常走完并给出合理结果。
      final RgbaImage binary = pnmDecoder.decode(load('gradient_64x48.ppm'));
      expect(binary.metadata.format, img.metadata.format);
      expect(img.pixels.length, 8 * 8 * 4);
    });
  });

  group('PNM P5 二进制灰度', () {
    // 灰度图解成 RGBA 时三个通道要填同一个值。gray = round(255·x/63)。
    late final RgbaImage img = pnmDecoder.decode(load('gradient_64x32.pgm'));

    test('尺寸与变体', () {
      expect(img.width, 64);
      expect(img.height, 32);
      expect(img.metadata.variant, startsWith('P5'));
      expect(img.metadata.bitDepth, 8);
    });

    test('灰度值展开到三通道', () {
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 63, 0, <int>[255, 255, 255, 255]);
      expectPixel(img, 32, 16, <int>[130, 130, 130, 255]);
    });

    test('每一行都一样 —— 灰度只跟 x 有关', () {
      for (int y = 1; y < img.height; y++) {
        for (int x = 0; x < img.width; x += 7) {
          expect(img.channelsAt(x, y), img.channelsAt(x, 0),
              reason: '第 $y 行第 $x 列与第 0 行不同');
        }
      }
    });
  });

  group('PNM P2 ASCII 灰度，maxval=15', () {
    // 这张图唯一的目的是查 maxval 缩放。样本值是 0..15，
    // 解码器必须按 (v·255 + 7) ~/ 15 放大到 0..255。
    // 不缩放直接当 8 位用的话，整张图会暗得几乎全黑 —— 最大值只到 15。
    late final RgbaImage img = pnmDecoder.decode(load('ramp_16x8_ascii.pgm'));

    test('尺寸与变体', () {
      expect(img.width, 16);
      expect(img.height, 8);
      expect(img.metadata.variant, startsWith('P2'));
      // maxval 15 仍然是 1 字节/样本，所以位深报 8。
      expect(img.metadata.bitDepth, 8);
    });

    test('缩放确实发生了', () {
      // x=1 的样本值是 1。缩放后是 17，不缩放就是 1。
      // 这一条就是整个 maxval 逻辑的判别式。
      expectPixel(img, 1, 0, <int>[17, 17, 17, 255],
          reason: '样本值 1、maxval 15 → 17；如果得到 1，说明没做缩放');
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255], reason: '样本 0 → 0');
      expectPixel(img, 15, 0, <int>[255, 255, 255, 255],
          reason: '样本 15 = maxval → 必须正好是 255，不能是 254');
      expectPixel(img, 8, 0, <int>[136, 136, 136, 255], reason: '样本 8 → 136');
    });

    test('端点精确 —— 缩放公式那个 +7 就是为了这个', () {
      // 写成 v·255~/15 也能让 0→0、15→255，但中间值会一律偏小。
      // 上面 x=1 得 17 与 x=8 得 136 两条合起来钉住了四舍五入版本：
      // 截断版会给 17 与 136（恰好相同），所以再加一条中间值。
      // 样本 7 → (7·255+7)~/15 = 119；截断版 (7·255)~/15 = 119，也相同。
      // 真正能区分的是样本 4：(4·255+7)~/15 = 68，截断版也是 68。
      // maxval=15 这个特例下两种写法结果一致（255 是 15 的整数倍），
      // 所以这里只钉住端点与实际值，不假装能区分四舍五入。
      expect(img.channelsAt(15, 0)[0], 255);
      expect(img.channelsAt(0, 0)[0], 0);
    });
  });

  group('PNM P4 二进制位图（棋盘格）', () {
    // 位图有两个坑，这张图两个都占了：
    //   1. **1 表示黑**，跟直觉相反（PNM 的位图是"墨水量"，不是亮度）。
    //   2. 每行按字节对齐、高位在前。宽 20 不是 8 的倍数，
    //      每行 3 字节里最后 4 位是填充。
    late final RgbaImage img = pnmDecoder.decode(load('checker_20x16.pbm'));

    test('尺寸与位深', () {
      expect(img.width, 20);
      expect(img.height, 16);
      expect(img.metadata.variant, startsWith('P4'));
      expect(img.metadata.bitDepth, 1);
    });

    test('1 是黑、0 是白', () {
      // (x~/4 + y~/4) 为偶数时生成器写 1。写 1 的地方必须解成黑。
      // 极性反了这两条会同时红 —— 这就是要的效果。
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255], reason: 'bit=1 → 黑');
      expectPixel(img, 4, 0, <int>[255, 255, 255, 255], reason: 'bit=0 → 白');
    });

    test('每行重新按字节对齐 —— 填充位不能当像素', () {
      // 这是这张图的核心。第 0 行占 3 字节 = 24 位，但只有前 20 位是像素，
      // 后 4 位是填充（值为 0）。
      //
      // 如果解码器不在行边界重新对齐，第 1 行就会从第 20 位开始读，
      // 于是先读到 4 个填充位（0 = 白）。而 (0,1) 应该是黑。
      expectPixel(img, 0, 1, <int>[0, 0, 0, 255],
          reason: '第 1 行必须从第 3 个字节的开头读起，不能接着第 0 行的填充位');
      expectPixel(img, 0, 2, <int>[0, 0, 0, 255]);
      expectPixel(img, 0, 3, <int>[0, 0, 0, 255]);
      // 第 4 行换格子：y~/4 = 1，于是 x~/4 = 0 处变白。
      expectPixel(img, 0, 4, <int>[255, 255, 255, 255], reason: '第 4 行起格子翻转');
    });

    test('行末那个不完整的字节读对了', () {
      // x=16..19 在第 3 个字节的高 4 位。x~/4 = 4，与 y~/4=0 相加为偶 → 黑。
      // 填充位当像素读的话这里会白。
      expectPixel(img, 16, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 19, 0, <int>[0, 0, 0, 255], reason: '最后一列');
    });

    test('位图没有 maxval 行', () {
      // P4/P1 的头部只有 `P4\n20 16\n` 两行 —— 多读一个数字当 maxval
      // 就会把第一个像素字节吃掉，整幅图错位一字节。
      // 上面 (0,0) 是黑那条已经能查出来，这里确认尺寸也没被带偏。
      expect(img.pixels.length, 20 * 16 * 4);
    });
  });

  group('PNM P1 ASCII 位图（圆环）', () {
    // 距圆心 4..7 之间画黑环。
    late final RgbaImage img = pnmDecoder.decode(load('ring_16x16_ascii.pbm'));

    test('尺寸与变体', () {
      expect(img.width, 16);
      expect(img.height, 16);
      expect(img.metadata.variant, startsWith('P1'));
      expect(img.metadata.bitDepth, 1);
    });

    test('环内是黑、环内外都是白', () {
      expectPixel(img, 8, 8, <int>[255, 255, 255, 255],
          reason: '圆心距 0.707，在内径 4 以内 → 白');
      expectPixel(img, 13, 8, <int>[0, 0, 0, 255], reason: '距 5.52，在环上 → 黑');
      expectPixel(img, 14, 8, <int>[0, 0, 0, 255], reason: '距 6.52，还在环上');
      expectPixel(img, 15, 8, <int>[255, 255, 255, 255],
          reason: '距 7.52，超出外径 7 → 白');
      expectPixel(img, 0, 0, <int>[255, 255, 255, 255], reason: '角点距 10.6 → 白');
    });

    test('相邻数字之间没有空白也能解', () {
      // P1 的一行是 `0000011111100000` —— 数字**紧挨着**，中间没有分隔符。
      // 这是 P1 与 P2/P3 的关键差别：位图每个样本固定一个字符，所以不需要
      // 分隔。按"读到空白才算一个 token"写的词法器在这里会把整行当成一个
      // 巨大的数字，然后尺寸对不上而报错。
      //
      // 能解出正确尺寸和上面那些像素，就说明这条路走通了。
      expect(img.pixels.length, 16 * 16 * 4);
      // 再确认这一行确实黑白都有 —— 全白或全黑说明词法出了问题。
      final Set<int> distinct = <int>{
        for (int x = 0; x < 16; x++) img.channelsAt(x, 8)[0],
      };
      expect(distinct, <int>{0, 255}, reason: '第 8 行应同时含黑与白');
    });
  });

  group('YUV I420 彩条（三帧）', () {
    // 这一组是全套测试里唯一允许容差的：8 位 limited range 往返本身有损。
    //
    // 生成器按标准正向变换编码（Y∈16..235、Cb/Cr∈16..240），解码器按反向
    // 变换解回来。两边都是 8 位整数量化，往返误差实测每通道最多 1
    // （比如纯红 255 解回来是 254，纯绿的 B 通道从 0 变成 1）。
    // 容差取 2 留一格余量。这个误差**不是 bug** —— 它就是 YUV 的代价。
    //
    // 取样点全部选在色条内部、且 2×2 色度块不跨条：色条边界上最近邻
    // 上采样会把颜色抹开一格，那里对不上是设计使然。
    const YuvOptions opts = YuvOptions(
      width: 96,
      height: 64,
      format: YuvFormat.i420,
      matrix: YuvMatrix.bt601,
      range: YuvRange.limited,
    );
    late final Uint8List bytes = load('colorbars_96x64_i420_3frames.yuv');
    late final RgbaImage frame0 = yuvDecoder.decodeWith(bytes, opts);

    test('文件大小正好是三帧', () {
      // I420 每帧 = w·h（Y） + 2·(w/2)·(h/2)（UV） = 96·64·1.5 = 9216。
      // 帧大小算错就会读到帧的中间，图像看起来是上下错位的两半。
      expect(YuvFormat.i420.frameSize(96, 64), 9216);
      expect(bytes.length, 9216 * 3);
    });

    test('尺寸与元数据', () {
      expect(frame0.width, 96);
      expect(frame0.height, 64);
      expect(frame0.metadata.format, 'YUV');
      expect(frame0.metadata.variant, 'I420');
    });

    test('七条色条的颜色（容差 2）', () {
      // 每条宽 96/7 ≈ 13.7，取样点都在条内部。
      const List<List<int>> expected = <List<int>>[
        <int>[4, 255, 255, 255], // 白
        <int>[20, 255, 255, 0], // 黄
        <int>[34, 0, 255, 255], // 青
        <int>[48, 0, 255, 0], // 绿
        <int>[60, 255, 0, 255], // 洋红
        <int>[76, 255, 0, 0], // 红
        <int>[90, 0, 0, 255], // 蓝
      ];
      for (final List<int> e in expected) {
        expectPixel(frame0, e[0], 10, <int>[e[1], e[2], e[3], 255],
            tolerance: 2, reason: 'x=${e[0]} 处的色条');
      }
    });

    test('alpha 全为 255 —— YUV 没有 alpha 概念', () {
      for (int y = 0; y < frame0.height; y += 8) {
        for (int x = 0; x < frame0.width; x += 8) {
          expect(frame0.channelsAt(x, y)[3], 255);
        }
      }
    });

    test('三帧各不相同，且色条逐帧右移', () {
      // 帧 f 在 x=0 处是 bars[f]。这条同时验证两件事：
      // 帧偏移算对了（帧大小 × 帧号），以及三帧确实是不同的内容。
      const List<List<int>> firstBar = <List<int>>[
        <int>[255, 255, 255], // 帧 0：白
        <int>[255, 255, 0], // 帧 1：黄
        <int>[0, 255, 255], // 帧 2：青
      ];
      for (int f = 0; f < 3; f++) {
        final RgbaImage img =
            yuvDecoder.decodeWith(bytes, opts.copyWith(frameIndex: f));
        expectPixel(img, 4, 10,
            <int>[firstBar[f][0], firstBar[f][1], firstBar[f][2], 255],
            tolerance: 2, reason: '第 $f 帧最左边的色条');
      }
    });

    test('越界帧号报错而不是读到垃圾', () {
      // 文件只有三帧。要第 4 帧时必须明确报错 —— 静默返回一张噪声图
      // 比报错糟得多，那种 bug 会被当成"解码器有问题"查很久。
      expect(
        () => yuvDecoder.decodeWith(bytes, opts.copyWith(frameIndex: 3)),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('宽度填错但字节够 —— 不报错，画出一张斜图', () {
      // 这是裸 YUV 最阴的一个坑，也是 docs/formats/yuv.md 里记的三大经典
      // bug 之一：**参数错了但字节数够，解码器无从察觉**。
      //
      // 95×64 的 I420 需要 9120 字节，文件有 27648 字节，绰绰有余。
      // 于是解码器老老实实解出一张 95×64 的图 —— 不抛异常、不警告。
      // 每行少读一个字节，行与行之间累积错位，整幅图斜过去。
      //
      // 所以这条测试断言的是「它确实不报错」。把这件事写成测试，是为了
      // 记住：YUV 的参数只能靠人填对，代码救不了。UI 上因此要把参数
      // 显眼地摆出来让人核对，而不是藏在设置里。
      final RgbaImage skewed =
          yuvDecoder.decodeWith(bytes, opts.copyWith(width: 95));
      expect(skewed.width, 95);
      expect(skewed.height, 64);

      // 怎么证明它真的斜了：正确宽度下每一行都一样（色条只跟 x 有关），
      // 错误宽度下行与行之间必然不同。
      final bool rowsIdenticalAt96 = _rowsEqual(frame0, 0, 32);
      final bool rowsIdenticalAt95 = _rowsEqual(skewed, 0, 32);
      expect(rowsIdenticalAt96, isTrue, reason: '宽度正确时第 0 行与第 32 行应相同');
      expect(rowsIdenticalAt95, isFalse,
          reason: '宽度错 1 会让每行累积错位，第 0 行与第 32 行不该再相同');
    });

    test('字节确实不够时才会报错，且报出还差多少', () {
      // 512×64 的 I420 需要 49152 字节，文件只有 27648 —— 这时解码器
      // 有据可查，必须报错。错误信息里要带上差多少字节，这样填错参数的人
      // 能直接算出正确的宽高。
      expect(
        () => yuvDecoder.decodeWith(bytes, opts.copyWith(width: 512)),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('PNG RGB8 渐变（真 zlib 压缩）', () {
    // 这一组和上面所有组有个本质区别：压缩数据是 `dart:io` 的 ZLibCodec
    // 以 level 9 写出来的，也就是 zlib 官方实现的输出。
    //
    // 单元测试里的 PNG 一律用**存储块**，压根不碰 Huffman 路径。这张图
    // 补上的正是那一块 —— 我们手写的 inflate 能解开 zlib 的动态 Huffman
    // 块，才说明它真的实现了 RFC 1951，而不只是能解开自家写出来的东西。
    //
    // 每个像素：R = 255·x÷95，G = 255·y÷63，B = 255·(x+y)÷158（整数除法，
    // 向下取整，不是四舍五入 —— 生成器用的是 `~/`）。
    late final RgbaImage img = pngDecoder.decode(load('gradient_96x64_rgb8.png'));

    test('尺寸与元数据', () {
      expect(img.width, 96);
      expect(img.height, 64);
      expect(img.metadata.format, 'PNG');
      expect(img.metadata.variant, '真彩色 RGB');
      expect(img.metadata.bitDepth, 8); // 每采样 8 位，不是每像素 24
      expect(img.metadata.channels, 3);
      expect(img.metadata.isLossless, isTrue);
      expect(img.metadata.extra['隔行方式'], '无');
    });

    test('四角与中心的像素值', () {
      expectPixel(img, 0, 0, const <int>[0, 0, 0, 255], reason: '左上角');
      // 95·255÷95 = 255；(95+0)·255÷158 = 153
      expectPixel(img, 95, 0, const <int>[255, 0, 153, 255], reason: '右上角');
      // 63·255÷63 = 255；(0+63)·255÷158 = 101
      expectPixel(img, 0, 63, const <int>[0, 255, 101, 255], reason: '左下角');
      expectPixel(img, 95, 63, const <int>[255, 255, 255, 255], reason: '右下角');
      // 48·255÷95 = 128；32·255÷63 = 129；80·255÷158 = 129
      expectPixel(img, 48, 32, const <int>[128, 129, 129, 255]);
    });

    test('R 只跟 x 有关，G 只跟 y 有关', () {
      // 一整行里 G 必须恒定、R 必须单调不减。反过来（R 恒定、G 变化）
      // 就是行列搞混了 —— 那种错在正方形图上看不出来，96×64 能。
      for (int y = 0; y < img.height; y += 7) {
        final int g = y * 255 ~/ 63;
        for (int x = 0; x < img.width; x += 5) {
          final List<int> px = img.channelsAt(x, y);
          expect(px[1], g, reason: '($x, $y) 的 G 应只由 y 决定');
          expect(px[0], x * 255 ~/ 95, reason: '($x, $y) 的 R 应只由 x 决定');
        }
      }
    });

    test('压缩数据用的是动态 Huffman 块', () {
      // 这一条是本组存在的理由。zlib 以 level 9 压一张渐变图，必然选动态
      // Huffman —— 于是这个断言证明了「我们的 inflate 解开了 zlib 生成的
      // 动态码表」，而不只是解开了测试里手搭的那些。
      expect(img.metadata.extra['deflate 块'], contains('动态'));
      expect(img.metadata.extra['解压后'], '${64 * (96 * 3 + 1)} 字节');

      // 18496 字节的原始数据压到几百字节。渐变图对 deflate 极其友好：
      // 滤波之后大量字节变成 0 附近的小值。
      final String ratio = img.metadata.extra['压缩率']! as String;
      expect(double.parse(ratio.split(':').first), greaterThan(10));
    });

    test('逐行挑滤波器，所以用上了多种', () {
      // 生成器对每一行都试遍五种、取绝对值之和最小的那个（libpng 的默认
      // 启发式）。于是这张图天然会用上不止一种滤波器，把解码端的多条分支
      // 一次跑到 —— 单元测试里那些「整张图一种滤波器」的用例覆盖不到
      // 「上一行用 Paeth、这一行用 Sub」的衔接。
      final String used = img.metadata.extra['滤波器用量']! as String;
      expect(used.split(', ').length, greaterThan(1), reason: '实际用量：$used');

      // 各滤波器的行数加起来必须等于总行数。
      int rows = 0;
      for (final String part in used.split(', ')) {
        rows += int.parse(part.split('×').last);
      }
      expect(rows, 64);
    });

    test('辅助 chunk 都被读出来了', () {
      expect(img.metadata.extra['gAMA'], '0.45455');
      expect(img.metadata.extra['pHYs'], contains('96×96 DPI'));
      expect(img.metadata.extra['tEXt:Software'],
          'ImageViewer gen_samples.dart');
      // IHDR + gAMA + pHYs + tEXt + IDAT + IEND
      expect(img.metadata.extra['chunk 数'], 6);
    });
  });

  group('PNG RGBA8 圆盘（alpha 渐隐）', () {
    // 和 circle_64x64_32bpp.bmp 画的是同一个形状：两种格式表达同一张图。
    // 圆心 (31.5, 31.5)，半径 30，最外 8 像素线性渐隐。
    late final RgbaImage img = pngDecoder.decode(load('disc_64x64_rgba8.png'));

    test('尺寸与元数据', () {
      expect(img.width, 64);
      expect(img.height, 64);
      expect(img.metadata.variant, '真彩色 RGBA');
      expect(img.metadata.channels, 4);
      expect(img.metadata.extra['透明像素'], '有');
      // 有 alpha 通道的图不该同时带 tRNS，所以没有关键色那一项。
      expect(img.metadata.extra.containsKey('关键色透明'), isFalse);
    });

    test('圆心不透明，圆外全透明', () {
      // 圆心附近：d = sqrt(0.5) ≈ 0.71 < 22，alpha 满。
      // R = 255·31÷63 = 125，G 同，B 恒 200。
      expectPixel(img, 31, 31, const <int>[125, 125, 200, 255]);
      // 255·32÷63 = 129
      expectPixel(img, 32, 32, const <int>[129, 129, 200, 255]);
      // 角落：d = 31.5·√2 ≈ 44.5 ≥ 30，alpha 为 0。
      expect(img.channelsAt(0, 0)[3], 0, reason: '左上角应完全透明');
      expect(img.channelsAt(63, 63)[3], 0, reason: '右下角应完全透明');
    });

    test('透明像素仍保留自己的 RGB —— PNG 不做预乘', () {
      // 这是容易被忽略的一点：alpha=0 的像素，RGB 依然是写进去的值，
      // 不是 0。若解码时按预乘处理（RGB 乘以 alpha），这里就会读到黑色。
      // PNG 规范明确：存的是**非**预乘的直通 alpha。
      expectPixel(img, 0, 0, const <int>[0, 0, 200, 0]);
    });

    test('渐隐带上的 alpha 是算出来的中间值', () {
      // (57, 31)：dx = 25.5，dy = -0.5，d = √650.5 ≈ 25.5049。
      // 落在 22..30 的渐隐带里：alpha = round((30 - 25.5049) / 8 · 255) = 143。
      // 这个值既不是 0 也不是 255，能查出「渐隐被做成硬边」的实现。
      expectPixel(img, 57, 31, const <int>[230, 125, 200, 143]);
    });
  });

  group('PNG 8 位调色板 + tRNS（色相条）', () {
    // 32 项调色板，内容只跟 x 有关：索引 = x ÷ 2。
    // tRNS 只给了前 8 项（alpha 依次 0/32/64/…/224），剩下 24 项按规范
    // 默认不透明。
    late final RgbaImage img = pngDecoder.decode(load('hues_64x48_palette8.png'));

    test('尺寸与元数据', () {
      expect(img.width, 64);
      expect(img.height, 48);
      expect(img.metadata.variant, '调色板');
      expect(img.metadata.colorSpace, '调色板（sRGB）');
      expect(img.metadata.bitDepth, 8); // 索引的位数
      expect(img.metadata.channels, 1); // 一个索引就是一个采样
      expect(img.metadata.extra['调色板'], '32 项');
      expect(img.metadata.extra['透明像素'], '有');
      expect(img.metadata.extra['调色板说明'], '32 项，8 位索引最大可到 255');
    });

    test('索引查表得到的颜色', () {
      // x=0..1 → 索引 0 → 色相环起点纯红
      expectPixel(img, 0, 0, const <int>[255, 0, 0, 0]);
      expectPixel(img, 1, 0, const <int>[255, 0, 0, 0]);
      // x=2 → 索引 1 → [255, 47, 0]，tRNS 第 1 项 alpha=32
      expectPixel(img, 2, 0, const <int>[255, 47, 0, 32]);
      // x=63 → 索引 31 → 环末尾回到红紫 [255, 0, 48]
      expectPixel(img, 63, 0, const <int>[255, 0, 48, 255]);
    });

    test('tRNS 比 PLTE 短 —— 缺的项默认不透明', () {
      // 这是最容易写反的一处。tRNS 只有 8 项，索引 8 及以后没有对应的
      // alpha。规范说默认 255（不透明）；若实现按「缺省补 0」处理，
      // 这张图右边四分之三会凭空消失。
      expect(img.channelsAt(14, 0)[3], 224, reason: '索引 7 —— tRNS 最后一项');
      expect(img.channelsAt(16, 0)[3], 255, reason: '索引 8 —— 超出 tRNS');
      for (int x = 16; x < 64; x++) {
        expect(img.channelsAt(x, 0)[3], 255, reason: 'x=$x 应不透明');
      }
    });

    test('内容只跟 x 有关，所以每行都一样', () {
      // 调色板图一行一个字节地存索引，没有位打包，行跨距 = 宽度。
      // 若把行跨距算错，各行会依次错开，这个断言立刻挂。
      for (int y = 1; y < img.height; y++) {
        expect(_rowsEqual(img, 0, y), isTrue, reason: '第 $y 行与第 0 行不同');
      }
    });
  });

  group('PNG 16 位灰度渐变（降位的证据）', () {
    // 64×64，每采样两字节大端。第 (y·64 + x) 个像素的 16 位值是
    // (y·64 + x)·65535 ÷ 4095，也就是索引乘 16 —— 4096 个像素刚好铺满
    // 0..65535，每步 16。
    //
    // 这张图存在的唯一理由是查降位：16 位要变成 8 位，正确做法是
    // round(v·255 / 65535)，等价于 (v·255 + 32767) ÷ 65535。
    late final RgbaImage img = pngDecoder.decode(load('ramp_64x64_gray16.png'));

    test('尺寸与元数据', () {
      expect(img.width, 64);
      expect(img.height, 64);
      expect(img.metadata.variant, '灰度');
      expect(img.metadata.bitDepth, 16);
      expect(img.metadata.channels, 1);
      // 64 行 × (64 像素 × 2 字节 + 1 滤波字节) = 8256
      expect(img.metadata.extra['解压后'], '8256 字节');
    });

    test('两端与中点', () {
      // 灰度展开成 RGB 三个相同的值，alpha 补 255。
      expectPixel(img, 0, 0, const <int>[0, 0, 0, 255]);
      expectPixel(img, 63, 63, const <int>[255, 255, 255, 255]);
      // 索引 2015 → 16 位值 32240 → round(32240·255/65535) = 125
      expectPixel(img, 31, 31, const <int>[125, 125, 125, 255]);
    });

    test('降位是四舍五入，不是丢掉低字节', () {
      // 关键的一对相邻像素：
      //   索引 8 → 16 位 128 → 128·255/65535 = 0.498 → 四舍五入 0
      //   索引 9 → 16 位 144 → 144·255/65535 = 0.560 → 四舍五入 1
      // 若实现是「取高字节」，这两个的高字节都是 0，会一起变成 0，
      // 这里就会看到 1 变成 0。整条渐变上会出现 256 级的台阶。
      expect(img.channelsAt(8, 0)[0], 0, reason: '16 位 128 应降到 0');
      expect(img.channelsAt(9, 0)[0], 1, reason: '16 位 144 应降到 1');
    });

    test('渐变单调不减，且横跨行边界也连续', () {
      // 逐像素比较。真正想查的是行末到下一行行首：索引是连续的，所以
      // 灰度也必须连续。若行跨距算错，这里会出现回跳。
      int prev = -1;
      for (int y = 0; y < img.height; y++) {
        for (int x = 0; x < img.width; x++) {
          final int v = img.channelsAt(x, y)[0];
          expect(v, greaterThanOrEqualTo(prev), reason: '($x, $y) 处回跳了');
          prev = v;
        }
      }
      expect(prev, 255);
    });
  });

  group('PNG 1 位灰度棋盘（宽度不是 8 的倍数）', () {
    // 35×24，一格 5 像素：on = ((x÷5) + (y÷5)) % 2 == 0。
    //
    // 宽度 35 是刻意选的：每行 5 字节，最后一字节只有 3 位是真像素，
    // 剩 5 位是填充。位序 MSB 先 —— 一字节的最高位是最左那个像素，
    // 和 deflate 数据字段的 LSB 先正好相反。
    late final RgbaImage img = pngDecoder.decode(load('checker_35x24_gray1.png'));

    test('尺寸与元数据', () {
      expect(img.width, 35);
      expect(img.height, 24);
      expect(img.metadata.variant, '灰度');
      expect(img.metadata.bitDepth, 1);
      expect(img.metadata.channels, 1);
      // 24 行 × ((35+7)÷8 + 1) = 24 × 6 = 144
      expect(img.metadata.extra['解压后'], '144 字节');
    });

    test('1 位灰度按满量程展开：1 → 255', () {
      // 位深 1 时最大采样值是 1，所以 1 要拉到 255 而不是留成 1。
      // 若照 8 位那样直接用采样值，整张图会是全黑配"几乎全黑"。
      expectPixel(img, 0, 0, const <int>[255, 255, 255, 255], reason: '第一格');
      expectPixel(img, 5, 0, const <int>[0, 0, 0, 255], reason: '第二格');
      expectPixel(img, 0, 5, const <int>[0, 0, 0, 255]);
      expectPixel(img, 5, 5, const <int>[255, 255, 255, 255]);
    });

    test('末字节的 5 个填充位没被当成像素', () {
      // x=34 是最后一个真像素，落在第 5 字节的第 3 位（MSB 起数）。
      // 34÷5 = 6（偶），所以它的开关只由 y÷5 的奇偶决定。
      //
      // 若解码器把填充位也算进去，宽度会变成 40，右边多出 5 列杂点；
      // 若行跨距按 35÷8 = 4 字节算，每行都会左移，图案整体扭斜。
      for (int y = 0; y < img.height; y++) {
        final bool on = (y ~/ 5) % 2 == 0;
        final int v = on ? 255 : 0;
        expectPixel(img, 34, y, <int>[v, v, v, 255],
            reason: '第 $y 行最后一个像素');
        // x=0 的格列号也是偶数，所以两端应当同色。
        expectPixel(img, 0, y, <int>[v, v, v, 255], reason: '第 $y 行第一个像素');
      }
    });

    test('每格 5×5 都是纯色', () {
      // 格子内部完全一致才说明位提取的顺序对。位序若反（LSB 先），
      // 格子边界会在字节内错位，5 像素的格子会变成锯齿状。
      for (int cy = 0; cy < 24 ~/ 5; cy++) {
        for (int cx = 0; cx < 35 ~/ 5; cx++) {
          final int v = (cx + cy) % 2 == 0 ? 255 : 0;
          for (int dy = 0; dy < 5; dy++) {
            for (int dx = 0; dx < 5; dx++) {
              expectPixel(img, cx * 5 + dx, cy * 5 + dy, <int>[v, v, v, 255],
                  reason: '格 ($cx, $cy) 内的 ($dx, $dy)');
            }
          }
        }
      }
    });
  });

  group('PNG Adam7 隔行同心环', () {
    // 64×64 RGB8，内容按到圆心 (31.5, 31.5) 的距离分环：
    //   d = round(sqrt(dx² + dy²))，(d ÷ 4) 为偶数时是"环"色。
    //   环色 [240, 60 + 2d, 30]，底色 [30, 30, 120 + 2d]。
    //
    // 七遍隔行的每一遍都是一张独立的小图：行字节数按**本遍宽度**重算，
    // 上一行缓冲在遍与遍之间重置。这两点错一个，图案就会碎掉。
    late final RgbaImage img = pngDecoder.decode(load('rings_64x64_adam7.png'));

    test('尺寸与元数据', () {
      expect(img.width, 64);
      expect(img.height, 64);
      expect(img.metadata.extra['隔行方式'], 'Adam7 隔行');
      expect(img.metadata.variant, '真彩色 RGB + Adam7 隔行');
    });

    test('隔行的原始数据比非隔行更大', () {
      // 逐遍手算：七遍的子图尺寸分别是
      //   8×8, 8×8, 16×8, 16×16, 32×16, 32×32, 64×32
      // 每遍每行 3·宽 字节再加 1 个滤波字节：
      //   8×(24+1) + 8×(24+1) + 8×(48+1) + 16×(48+1)
      //   + 16×(96+1) + 32×(96+1) + 32×(192+1)
      //   = 200 + 200 + 392 + 784 + 1552 + 3104 + 6176 = 12408
      // 非隔行同尺寸是 64×(192+1) = 12352，隔行多出 56 字节 —— 正好是
      // 多出来的 56 行滤波字节（120 行 - 64 行）。
      //
      // 「隔行能省体积」是个常见的想当然。Adam7 换来的是渐显，不是体积；
      // 位深小于 8 时每遍还要各自补到字节边界，差距更大。
      expect(img.metadata.extra['解压后'], '12408 字节');
      expect(12408 - 64 * (192 + 1), 56);
    });

    test('七遍拼回来的像素值', () {
      // 这几个点分属不同的遍：(0,0) 在第 1 遍，(4,0) 在第 2 遍，
      // (0,4) 在第 3 遍，(2,0) 在第 4 遍，(1,0) 在第 6 遍，(0,1) 在第 7 遍。
      // 某一遍的偏移或步长写错，只有那一遍的点会错 —— 混在一起看是"图案
      // 有杂点"，逐点查才定位得到。
      //
      // (0,0)：d = round(31.5·√2) = 45，45÷4 = 11 奇 → 底色 [30,30,210]
      expectPixel(img, 0, 0, const <int>[30, 30, 210, 255]);
      // (31,31)：d = round(√0.5) = 1，0 偶 → 环色 [240,62,30]
      expectPixel(img, 31, 31, const <int>[240, 62, 30, 255]);
      // (63,31)：d = round(√(31.5²+0.5²)) = 32，8 偶 → 环色 [240,124,30]
      expectPixel(img, 63, 31, const <int>[240, 124, 30, 255]);
    });

    test('图案关于中心左右、上下对称', () {
      // 距离只跟 |dx|、|dy| 有关，所以 (x,y) 必须等于 (63-x,y) 和 (x,63-y)。
      // 这是对 Adam7 最有效的整体检查：任何一遍的 xOffset / xStep 偏了，
      // 那一遍的像素会落到错误的列上，对称性立刻破。
      for (int y = 0; y < 64; y++) {
        for (int x = 0; x < 32; x++) {
          expect(img.channelsAt(x, y), img.channelsAt(63 - x, y),
              reason: '($x, $y) 与 (${63 - x}, $y) 应左右对称');
        }
      }
      for (int y = 0; y < 32; y++) {
        for (int x = 0; x < 64; x++) {
          expect(img.channelsAt(x, y), img.channelsAt(x, 63 - y),
              reason: '($x, $y) 与 ($x, ${63 - y}) 应上下对称');
        }
      }
    });
  });

  group('JPEG 与 libjpeg-turbo 的交叉验证', () {
    // 这一组和上面各组的路子不同。上面的期望值都是手算字面量 —— JPEG 做不到
    // 这件事：DCT + 量化的结果没法在注释里手算。所以换成两个独立参考：
    //
    //   1. djpeg 的解码结果（test/assets/expected/*.pnm）。这是「和最权威的
    //      实现算得一样吗」。容差 2 —— 见下面 444 那条的说明。
    //   2. 压缩前的原图（assets/samples/gradient_64x48.ppm）。这是「解出来的
    //      还是那张图吗」。它能抓住 djpeg 比对抓不到的一类错：如果我们和
    //      djpeg 都错了同一步，只有原图能看出来。
    //
    // 光有 (1) 是不够的：我们和 libjpeg 共享同一套算法族，一起错是可能的。
    // 光有 (2) 也不够：量化损失把容差撑到 8，那么松的比对漏得过不少 bug。

    late final RgbaImage source = pnmDecoder.decode(load('gradient_64x48.ppm'));
    late final RgbaImage sourceGray =
        pnmDecoder.decode(load('gradient_64x32.pgm'));

    test('基线 4:4:4（q90）', () {
      final RgbaImage img = jpegDecoder.decode(load('gradient_64x48_q90_444.jpg'));
      expect(img.width, 64);
      expect(img.height, 48);
      expect(img.metadata.variant, '基线（SOF0）');
      expect(img.metadata.colorSpace, 'YCbCr (BT.601)');
      expect(img.metadata.extra['采样'], '4:4:4');
      expect(img.metadata.extra['扫描趟数'], 1);

      // 容差 2 的来历：我们的 IDCT 和 libjpeg 的 islow 都是整数近似，末位
      // 舍入不同。实测 9216 个通道里有 34 个差 1~2。这不是缺陷 —— libjpeg
      // 自己的 islow 和 float 两个 IDCT 在这张图上差了 67 个通道，比我们和
      // 它的差距还大。ITU T.83 给的合规判据本来就是容差，不是逐位相同。
      expectImageMatches(img, loadExpected('gradient_64x48_q90_444.pnm'),
          tolerance: 2, reason: '与 djpeg 的解码结果比');

      // q90 的量化损失。B 通道原图恒为 96，色度全图一致所以损失最小。
      expectImageMatches(img, source,
          tolerance: 4, reason: 'q90 压缩前后');
    });

    test('基线 4:2:0（q75）—— 与 djpeg 逐字节相同', () {
      final RgbaImage img = jpegDecoder.decode(load('gradient_64x48_q75_420.jpg'));
      expect(img.metadata.extra['采样'], '4:2:0');
      expect(img.metadata.extra['采样因子'], '2x2 1x1 1x1');
      expect(img.metadata.extra['MCU'], '16x16（4x3 个）');

      // 容差 0。这条是整组里最有价值的一个断言：色度平面只有 32x24，要经过
      // **三角滤波升采样**才铺回 64x48，而结果和 libjpeg 一个字节都不差。
      // 也就是说 IDCT 和 fancy upsampling 两级同时被钉住了。
      //
      // 为什么 q75 能对齐而 q90 不能：量化越粗，非零系数越少，IDCT 的末位
      // 分歧就越没有机会显形。
      expectImageMatches(img, loadExpected('gradient_64x48_q75_420.pnm'),
          reason: '与 djpeg 的解码结果必须逐字节相同');

      // 色度抽掉四分之三，损失比 444 大一倍。
      expectImageMatches(img, source, tolerance: 8, reason: 'q75 4:2:0 压缩前后');
    });

    test('基线 4:2:2 + 重启间隔（q80）', () {
      final RgbaImage img =
          jpegDecoder.decode(load('gradient_64x48_q80_422rst.jpg'));
      expect(img.metadata.extra['采样'], '4:2:2');
      // cjpeg -restart 2 是「每 2 行 MCU 一个」，这张图一行 4 个 MCU。
      expect(img.metadata.extra['重启间隔'], '8 个 MCU');
      expectImageMatches(img, loadExpected('gradient_64x48_q80_422rst.pnm'),
          tolerance: 2, reason: '与 djpeg 的解码结果比');
      expectImageMatches(img, source, tolerance: 6, reason: 'q80 4:2:2 压缩前后');
    });

    test('渐进（q80，10 趟扫描）', () {
      final RgbaImage img = jpegDecoder.decode(load('gradient_64x48_q80_prog.jpg'));
      expect(img.metadata.variant, '渐进（SOF2）');
      // cjpeg 的默认渐进脚本：DC 首趟 + DC 细化 + 每个分量的 AC 首趟与细化。
      // 10 趟意味着 DC首/DC细化/AC首/AC细化四条路径全都跑到了 —— 手搓的
      // 位流很难覆盖这么全，这是这张样图的主要价值。
      expect(img.metadata.extra['扫描趟数'], 10);
      expectImageMatches(img, loadExpected('gradient_64x48_q80_prog.pnm'),
          tolerance: 2, reason: '与 djpeg 的解码结果比');
      expectImageMatches(img, source, tolerance: 8, reason: 'q80 渐进压缩前后');
    });

    test('灰度（q85）—— 与 djpeg 逐字节相同', () {
      final RgbaImage img = jpegDecoder.decode(load('gradient_64x32_q85_gray.jpg'));
      expect(img.width, 64);
      expect(img.height, 32);
      expect(img.metadata.channels, 1);
      expect(img.metadata.colorSpace, 'Grayscale');
      expect(img.metadata.extra['采样'], '单分量（灰度）');
      // 灰度没有色彩变换、没有升采样，只剩 IDCT。逐字节相同。
      expectImageMatches(img, loadExpected('gradient_64x32_q85_gray.pnm'),
          reason: '与 djpeg 的解码结果必须逐字节相同');
      expectImageMatches(img, sourceGray, tolerance: 1, reason: 'q85 灰度压缩前后');

      // R=G=B —— 灰度图三通道必须一致。
      for (int x = 0; x < 64; x += 7) {
        final List<int> px = img.channelsAt(x, 16);
        expect(px[0], px[1], reason: 'x=$x 的 R 与 G');
        expect(px[1], px[2], reason: 'x=$x 的 G 与 B');
        expect(px[3], 255);
      }
    });

    test('EXIF 方向 6：宽高互换，像素按顺时针 90° 落位', () {
      // 这张图是 q75_420 那张原封不动地在 SOI 后面插了一个 APP1 段，熵数据
      // 一字节没动。所以旋转前的像素与那张严格相同 —— 期望值可以从那张推出来，
      // 不必依赖 applyOrientation 自己（它的八种映射由 jpeg_exif_test 钉住）。
      final RgbaImage img = jpegDecoder.decode(load('gradient_64x48_exif6.jpg'));
      final RgbaImage base = jpegDecoder.decode(load('gradient_64x48_q75_420.jpg'));

      expect(img.width, 48, reason: '方向 6 换宽高');
      expect(img.height, 64);
      expect(img.metadata.extra['EXIF 方向'], '6（顺时针 90°）');

      // 顺时针 90°：原图第 0 列（x=0）变成新图第 0 行，且原图底部走在前面。
      // 即 新(dx, dy) = 原(dy, H-1-dx)。
      for (int dy = 0; dy < 64; dy++) {
        for (int dx = 0; dx < 48; dx++) {
          expect(img.channelsAt(dx, dy), base.channelsAt(dy, 47 - dx),
              reason: '新图 ($dx, $dy) 应取自原图 ($dy, ${47 - dx})');
        }
      }

      // 顺手钉一个角，免得上面那个循环里的映射写反了还自证自洽：
      // 原图左下角（x=0, y=47）→ 新图左上角。原图 G = 255·47/47 = 255。
      expectPixel(img, 0, 0, base.channelsAt(0, 47), reason: '原图左下 → 新图左上');
    });
  });

  group('文档里那张 482 字节的灰度图', () {
    // `docs/formats/jpeg.md`「字节级实例」一节把这张样图逐段拆开讲了一遍，
    // 还手算了第一个 DC 系数。那一节里的每个数字都在这里被断言 —— 段偏移、
    // 量化表第 0 项、SOF0 的 9 个载荷字节、类别 8 → -182 → -910 → 14.25
    // 这条链。文档和代码要么一起对，要么一起红，不会悄悄脱节。
    //
    // 这一组和 png_test.dart 的「文档里那张 2×2 的例图」、yuv_test.dart 的
    // 「文档里的字节级实例」是同一个用途。
    final Uint8List d = load('gradient_64x32_q85_gray.jpg');

    test('总长与各段偏移和文档的转储左栏一致', () {
      expect(d.length, 482, reason: '文档说共 482 字节');

      expect(d.sublist(0x00, 0x02), equals(<int>[0xFF, 0xD8]), reason: 'SOI');
      expect(d.sublist(0x02, 0x04), equals(<int>[0xFF, 0xE0]), reason: 'APP0');
      expect(d.sublist(0x14, 0x16), equals(<int>[0xFF, 0xDB]), reason: 'DQT');
      expect(d.sublist(0x59, 0x5B), equals(<int>[0xFF, 0xC0]), reason: 'SOF0');
      expect(d.sublist(0x66, 0x68), equals(<int>[0xFF, 0xC4]),
          reason: 'DHT（DC 表）');
      expect(d.sublist(0x87, 0x89), equals(<int>[0xFF, 0xC4]),
          reason: 'DHT（AC 表）');
      expect(d.sublist(0x13E, 0x140), equals(<int>[0xFF, 0xDA]), reason: 'SOS');
      expect(d.sublist(0x1E0, 0x1E2), equals(<int>[0xFF, 0xD9]), reason: 'EOI');

      // 上面那串偏移不是抄来的，是长度字段一段一段链出来的。链子对不上，
      // 说明文档的转储和文件本身已经不是一回事了。
      expect(0x02 + 2 + ((d[0x04] << 8) | d[0x05]), 0x14, reason: 'APP0 → DQT');
      expect(0x14 + 2 + ((d[0x16] << 8) | d[0x17]), 0x59, reason: 'DQT → SOF0');
      expect(0x59 + 2 + ((d[0x5B] << 8) | d[0x5C]), 0x66, reason: 'SOF0 → DHT');
    });

    test('SOF0 的 9 个载荷字节：8 位精度、32 行、64 列、单分量 1×1', () {
      expect(
          d.sublist(0x5D, 0x66),
          equals(<int>[
            0x08, // 精度 8 位
            0x00, 0x20, // 高 = 32
            0x00, 0x40, // 宽 = 64
            0x01, // 分量数 = 1（灰度）
            0x01, 0x11, 0x00, // id 1、抽样 1×1、量化表 0
          ]));

      // 解码器读出来的必须是同一件事。
      final RgbaImage img = jpegDecoder.decode(d);
      expect(img.width, 64);
      expect(img.height, 32);
    });

    test('DQT 按 zigzag 存，第 0 项（DC 的除数）是 5', () {
      expect(d[0x18], 0x00, reason: 'Pq=0（8 位）、Tq=0（表号 0）');
      expect(d[0x19], 5, reason: '文档手算 DC 时乘的就是这个 5');
      expect((d[0x16] << 8) | d[0x17], 67, reason: '2 + 1 + 64');
    });

    test('手算第一个 DC 系数：类别 8 → -182 → -910 → 整块 14.25', () {
      // 熵数据紧跟在 SOS 头后面 —— SOS 是最后一个有长度字段的段。
      const int entropy = 0x148;
      expect(0x13E + 2 + ((d[0x140] << 8) | d[0x141]), entropy);
      expect(d.sublist(entropy, entropy + 4),
          equals(<int>[0xF9, 0x27, 0x47, 0xFE]));

      // 从 entropy 起按 MSB 优先取第 i 个位。
      int bitAt(int i) => (d[entropy + (i >> 3)] >> (7 - (i & 7))) & 1;

      // 前 6 位 111110 查 DC 表得类别 8（DC 表就在 0x66 那一段里）。
      int code = 0;
      for (int i = 0; i < 6; i++) {
        code = (code << 1) | bitAt(i);
      }
      expect(code, 0x3E, reason: '111110');

      // 紧接着 8 个裸位。最高位是 0 ⇒ 负数，走 extend：v - 2^n + 1。
      int raw = 0;
      for (int i = 6; i < 14; i++) {
        raw = (raw << 1) | bitAt(i);
      }
      expect(raw, 0x49, reason: '01001001 = 73');
      expect(bitAt(6), 0, reason: '最高位 0 才走负数分支');
      final int diff = raw - (1 << 8) + 1;
      expect(diff, -182, reason: '73 - 256 + 1');

      // 第一块没有前驱，所以 DC 就是 diff 本身。乘量化表第 0 项。
      final int dc = diff * d[0x19];
      expect(dc, -910);

      // 只有 DC 的块 IDCT 出来是常数 DC/8 + 128。这张图的 AC 不为零，但
      // 所有 AC 基函数在整块上求和为零 —— 所以块均值只由 DC 决定。
      expect(dc / 8 + 128, 14.25);
    });

    test('解码器算出来的块 0 均值就是 14.25', () {
      final RgbaImage img = jpegDecoder.decode(d);

      // 文档引的是 djpeg 第 0 行的前 8 个像素。
      const List<int> row0 = <int>[0, 4, 9, 13, 16, 20, 24, 28];
      for (int x = 0; x < 8; x++) {
        expect(img.channelsAt(x, 0)[0], row0[x], reason: '第 0 行 x=$x');
      }

      int sum = 0;
      for (int y = 0; y < 8; y++) {
        for (int x = 0; x < 8; x++) {
          sum += img.channelsAt(x, y)[0];
        }
      }
      expect(sum, 912, reason: '64 个样本');
      expect(sum / 64, 14.25, reason: '与手算的 DC/8 + 128 相等');

      // 渐变只沿 x 变化，所以块里 8 行的前 8 个像素完全相同。
      // 这也是「行均值 == 块均值」这个对照成立的前提。
      for (int y = 1; y < 8; y++) {
        expect(img.channelsAt(3, y)[0], img.channelsAt(3, 0)[0],
            reason: '第 $y 行应和第 0 行相同');
      }
    });
  });

  group('通过注册表解码 —— 走的是 App 真正的那条路', () {
    // 上面各组都是直接调具体解码器。这一组用 buildRegistry()，也就是
    // decode_service 里 App 实际使用的那个注册表：先魔数嗅探，再分派。
    //
    // 意义在于：某个解码器的 canDecode 写错了，上面全绿而 App 里打不开图。
    final DecoderRegistry registry = buildRegistry();

    test('五张 BMP、六张 PNM、六张 PNG 与六张 JPEG 都能被嗅探出来', () {
      const Map<String, List<int>> expected = <String, List<int>>{
        'gradient_64x48_q90_444.jpg': <int>[64, 48],
        'gradient_64x48_q75_420.jpg': <int>[64, 48],
        'gradient_64x48_q80_422rst.jpg': <int>[64, 48],
        'gradient_64x48_q80_prog.jpg': <int>[64, 48],
        'gradient_64x32_q85_gray.jpg': <int>[64, 32],
        // 方向 6：注册表报出来的必须是转过之后的宽高。
        'gradient_64x48_exif6.jpg': <int>[48, 64],
        'gradient_61x40_24bpp.bmp': <int>[61, 40],
        'topdown_61x40_24bpp.bmp': <int>[61, 40],
        'rainbow_128x40_8bpp.bmp': <int>[128, 40],
        'bands_80x32_rle8.bmp': <int>[80, 32],
        'circle_64x64_32bpp.bmp': <int>[64, 64],
        'gradient_64x48.ppm': <int>[64, 48],
        'tiny_8x8_ascii.ppm': <int>[8, 8],
        'gradient_64x32.pgm': <int>[64, 32],
        'ramp_16x8_ascii.pgm': <int>[16, 8],
        'checker_20x16.pbm': <int>[20, 16],
        'ring_16x16_ascii.pbm': <int>[16, 16],
        'gradient_96x64_rgb8.png': <int>[96, 64],
        'disc_64x64_rgba8.png': <int>[64, 64],
        'hues_64x48_palette8.png': <int>[64, 48],
        'ramp_64x64_gray16.png': <int>[64, 64],
        'checker_35x24_gray1.png': <int>[35, 24],
        'rings_64x64_adam7.png': <int>[64, 64],
      };
      expected.forEach((String name, List<int> size) {
        final Uint8List bytes = load(name);
        expect(hasDecoderFor(bytes), isTrue, reason: '$name 没被任何解码器认领');
        final RgbaImage img = registry.decode(bytes);
        expect(<int>[img.width, img.height], size, reason: '$name 尺寸不对');
      });
    });

    test('YUV 无法被嗅探 —— 这是设计如此，不是缺陷', () {
      // 裸 YUV 没有魔数，第一个字节就是第一个像素的亮度。任何"嗅探 YUV"
      // 的尝试都只能是猜。所以 YuvDecoder.canDecode 永远返回 false，
      // 走注册表必然失败，必须由 UI 收集参数后调 decodeWith。
      final Uint8List bytes = load('colorbars_96x64_i420_3frames.yuv');
      expect(hasDecoderFor(bytes), isFalse);
      expect(
        () => registry.decode(bytes),
        throwsA(isA<UnknownImageFormat>()),
        reason: 'YUV 必须走 decodeWith 那条路',
      );
    });
  });
}
