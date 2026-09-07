import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/pnm/pnm_decoder.dart';
import 'package:image_viewer/src/codecs/pnm/pnm_header.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

import '../support/byte_builders.dart';
import '../support/pixel_matchers.dart';

const PnmDecoder decoder = PnmDecoder();

const List<int> black = <int>[0, 0, 0, 255];
const List<int> white = <int>[255, 255, 255, 255];

void main() {
  group('PNM 魔数嗅探', () {
    test('P1..P6 全部认领', () {
      for (int d = 1; d <= 6; d++) {
        expect(
          decoder.canDecode(ascii('P$d\n1 1\n')),
          isTrue,
          reason: 'P$d 应被认领',
        );
      }
    });

    test('P0 / P7 不认领', () {
      // P7 是 PAM 格式，头部结构完全不同，本项目不支持
      expect(decoder.canDecode(ascii('P0\n')), isFalse);
      expect(decoder.canDecode(ascii('P7\n')), isFalse);
    });

    test('非 P 开头与过短输入不认领', () {
      expect(decoder.canDecode(ascii('BM')), isFalse);
      expect(decoder.canDecode(Uint8List.fromList(<int>[0x50])), isFalse);
      expect(decoder.canDecode(Uint8List(0)), isFalse);
    });
  });

  group('P1 ASCII 位图', () {
    test('3x2，注意 1 表示黑', () {
      // PBM 描述的是"哪里要落墨"，所以 1=黑、0=白，与直觉相反
      final RgbaImage img = decoder.decode(ascii('P1\n3 2\n1 0 1\n0 1 0\n'));
      expect(img.width, 3);
      expect(img.height, 2);
      expectPixel(img, 0, 0, black);
      expectPixel(img, 1, 0, white);
      expectPixel(img, 2, 0, black);
      expectPixel(img, 0, 1, white);
      expectPixel(img, 1, 1, black);
      expectPixel(img, 2, 1, white);
    });

    test('像素之间的空白可以省略', () {
      final RgbaImage img = decoder.decode(ascii('P1\n4 1\n1010\n'));
      expectPixel(img, 0, 0, black);
      expectPixel(img, 1, 0, white);
      expectPixel(img, 2, 0, black);
      expectPixel(img, 3, 0, white);
    });

    test('1x1 最小有效图', () {
      expectPixel(decoder.decode(ascii('P1\n1 1\n1\n')), 0, 0, black);
    });
  });

  group('P2 ASCII 灰度图', () {
    test('2x2 四级灰度', () {
      final RgbaImage img = decoder.decode(ascii('P2\n2 2\n255\n0 85\n170 255\n'));
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[85, 85, 85, 255]);
      expectPixel(img, 0, 1, <int>[170, 170, 170, 255]);
      expectPixel(img, 1, 1, white);
    });

    test('maxval 非 255 时按比例缩放', () {
      // maxval=100，样本 50 应缩放到 128（四舍五入）
      final RgbaImage img = decoder.decode(ascii('P2\n3 1\n100\n0 50 100\n'));
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[128, 128, 128, 255]);
      expectPixel(img, 2, 0, white);
    });

    test('maxval=1 时 0/1 映射到黑/白', () {
      final RgbaImage img = decoder.decode(ascii('P2\n2 1\n1\n0 1\n'));
      expectPixel(img, 0, 0, black);
      expectPixel(img, 1, 0, white);
    });

    test('样本值超过 maxval 被拒', () {
      expect(
        () => decoder.decode(ascii('P2\n1 1\n100\n200\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('P3 ASCII 彩色图', () {
    test('2x1 红绿', () {
      final RgbaImage img = decoder.decode(
        ascii('P3\n2 1\n255\n255 0 0  0 255 0\n'),
      );
      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 255, 0, 255]);
    });

    test('样本可以跨行排布', () {
      // 规范只要求样本之间有空白，不要求每行一个像素
      final RgbaImage img = decoder.decode(
        ascii('P3\n2 1\n255\n255\n0\n0\n0\n0\n255\n'),
      );
      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 255, 255]);
    });
  });

  group('P4 二进制位图 —— 行按字节对齐', () {
    test('宽 8 正好一字节', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P4\n8 1\n'),
        <int>[0xA0], // 1010 0000
      ]);
      final RgbaImage img = decoder.decode(data);
      expectPixel(img, 0, 0, black, reason: '最高位对应 x=0');
      expectPixel(img, 1, 0, white);
      expectPixel(img, 2, 0, black);
      expectPixel(img, 3, 0, white);
    });

    test('宽 12 每行占 2 字节（含 4 位填充）', () {
      // 这是 P4 唯一的坑：12 位数据要占满 2 字节，不是 1.5 字节。
      // 行对齐算错的话第二行整个错位。
      final Uint8List data = concat(<List<int>>[
        ascii('P4\n12 2\n'),
        <int>[0xFF, 0x00], // 第一行：前 8 黑，后 4 白（末 4 位是填充）
        <int>[0x00, 0xF0], // 第二行：前 8 白，后 4 黑
      ]);
      final RgbaImage img = decoder.decode(data);
      expectPixel(img, 0, 0, black);
      expectPixel(img, 7, 0, black);
      expectPixel(img, 8, 0, white);
      expectPixel(img, 11, 0, white);
      expectPixel(img, 0, 1, white);
      expectPixel(img, 8, 1, black);
      expectPixel(img, 11, 1, black);
    });

    test('宽 3 也占满一字节', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P4\n3 2\n'),
        <int>[0xE0], // 111 xxxxx
        <int>[0x00], // 000 xxxxx
      ]);
      final RgbaImage img = decoder.decode(data);
      expectSolidColorRow(img, 0, black);
      expectSolidColorRow(img, 1, white);
    });

    test('数据不足时报出所需字节数', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P4\n12 2\n'),
        <int>[0xFF, 0x00], // 只给了第一行
      ]);
      try {
        decoder.decode(data);
        fail('应当抛异常');
      } on ImageDecodeException catch (e) {
        expect(e.toString(), contains('4 字节'));
      }
    });
  });

  group('P5 二进制灰度图', () {
    test('2x2 八位', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P5\n2 2\n255\n'),
        <int>[0, 85, 170, 255],
      ]);
      final RgbaImage img = decoder.decode(data);
      expectPixel(img, 0, 0, <int>[0, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[85, 85, 85, 255]);
      expectPixel(img, 0, 1, <int>[170, 170, 170, 255]);
      expectPixel(img, 1, 1, white);
    });

    test('maxval > 255 时每样本 2 字节大端', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P5\n2 1\n65535\n'),
        u16be(0), u16be(65535),
      ]);
      final RgbaImage img = decoder.decode(data);
      expectPixel(img, 0, 0, black);
      expectPixel(img, 1, 0, white);
    });

    test('16 位中间值降到 8 位', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P5\n1 1\n65535\n'),
        u16be(32768),
      ]);
      // 32768/65535*255 ≈ 127.5 → 128
      expectPixel(decoder.decode(data), 0, 0, <int>[128, 128, 128, 255]);
    });
  });

  group('P6 二进制彩色图', () {
    test('2x1 红蓝', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P6\n2 1\n255\n'),
        <int>[255, 0, 0, 0, 0, 255],
      ]);
      final RgbaImage img = decoder.decode(data);
      expectPixel(img, 0, 0, <int>[255, 0, 0, 255]);
      expectPixel(img, 1, 0, <int>[0, 0, 255, 255]);
    });

    test('16 位彩色每样本 2 字节', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P6\n1 1\n65535\n'),
        u16be(65535), u16be(0), u16be(32768),
      ]);
      expectPixel(decoder.decode(data), 0, 0, <int>[255, 0, 128, 255]);
    });

    test('所有像素都不透明', () {
      final Uint8List data = concat(<List<int>>[
        ascii('P6\n1 1\n255\n'),
        <int>[10, 20, 30],
      ]);
      // PNM 没有 alpha 通道，解码后应全部填 255
      expect(decoder.decode(data).hasTransparency, isFalse);
    });
  });

  group('PNM 头部词法 —— 注释与空白', () {
    test('注释可出现在魔数之后', () {
      final RgbaImage img = decoder.decode(
        ascii('P1\n# 这是注释\n1 1\n1\n'),
      );
      expectPixel(img, 0, 0, black);
    });

    test('注释可出现在宽高之间', () {
      final RgbaImage img = decoder.decode(
        ascii('P1\n2\n# 夹在宽和高中间\n1\n10\n'),
      );
      expect(img.width, 2);
      expect(img.height, 1);
    });

    test('多个注释与混合空白（制表、多空格、CRLF）', () {
      final RgbaImage img = decoder.decode(
        ascii('P2\r\n#a\r\n# b\r\n 2\t1 \r\n 255 \r\n0\t255\n'),
      );
      expect(img.width, 2);
      expectPixel(img, 0, 0, black);
      expectPixel(img, 1, 0, white);
    });

    test('二进制变体：头部后恰好一个空白作分界', () {
      // 关键边界：像素数据的首字节正好是 0x20（空格）。
      // 若按 ASCII 那样"跳过所有空白"，这个像素会被当作分隔符吃掉，
      // 整幅图错位一字节。
      final Uint8List data = concat(<List<int>>[
        ascii('P5\n2 1\n255\n'),
        <int>[0x20, 0xFF], // 首像素恰是空格的字节值
      ]);
      final RgbaImage img = decoder.decode(data);
      expectPixel(img, 0, 0, <int>[0x20, 0x20, 0x20, 255],
          reason: '0x20 是像素值，不是分隔符');
      expectPixel(img, 1, 0, white);
    });

    test('二进制变体头部后不是空白则报错', () {
      expect(
        () => decoder.decode(ascii('P5\n1 1\n255X')),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('PNM 畸形输入', () {
    test('宽高为 0 被拒', () {
      expect(
        () => decoder.decode(ascii('P1\n0 1\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('宽高不是数字被拒', () {
      expect(
        () => decoder.decode(ascii('P1\nabc 1\n1\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('头部截断被拒', () {
      expect(
        () => decoder.decode(ascii('P6\n2 2\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('maxval 越界被拒', () {
      expect(
        () => decoder.decode(ascii('P2\n1 1\n0\n0\n')),
        throwsA(isA<ImageDecodeException>()),
      );
      expect(
        () => decoder.decode(ascii('P2\n1 1\n70000\n0\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('像素数据不足被拒（ASCII 与二进制两路）', () {
      expect(
        () => decoder.decode(ascii('P3\n2 2\n255\n255 0 0\n')),
        throwsA(isA<ImageDecodeException>()),
      );
      expect(
        () => decoder.decode(concat(<List<int>>[
          ascii('P6\n2 2\n255\n'),
          <int>[255, 0, 0],
        ])),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('P1 数据里出现非法字符被拒', () {
      expect(
        () => decoder.decode(ascii('P1\n2 1\n1X\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('声明巨大尺寸被拒而不是 OOM', () {
      expect(
        () => decoder.decode(ascii('P5\n999999 999999\n255\n\n')),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('PnmHeader 与元数据', () {
    test('scaleToByte 的三条路径', () {
      PnmHeader h(int maxval) => PnmHeader(
            variant: PnmVariant.p5BinaryGray,
            width: 1,
            height: 1,
            maxValue: maxval,
            dataOffset: 0,
          );
      // maxval=255 直通
      expect(h(255).scaleToByte(123), 123);
      // maxval=1 二值化
      expect(h(1).scaleToByte(0), 0);
      expect(h(1).scaleToByte(1), 255);
      // 其它按比例四舍五入
      expect(h(100).scaleToByte(50), 128);
      expect(h(65535).scaleToByte(65535), 255);
    });

    test('bytesPerSample 由 maxval 决定', () {
      PnmHeader h(int maxval) => PnmHeader(
            variant: PnmVariant.p5BinaryGray,
            width: 1,
            height: 1,
            maxValue: maxval,
            dataOffset: 0,
          );
      expect(h(255).bytesPerSample, 1);
      expect(h(256).bytesPerSample, 2);
    });

    test('元数据记录变体与编码方式', () {
      final RgbaImage img = decoder.decode(ascii('P3\n1 1\n255\n1 2 3\n'));
      final Map<String, String> m = img.metadata.toDisplayMap();
      expect(m['格式'], 'PNM');
      expect(m['子类型'], contains('P3'));
      expect(m['通道数'], '3');
      expect(m['编码'], 'ASCII 文本');
      expect(m['有损/无损'], '无损');
    });

    test('位图变体的元数据位深为 1', () {
      final RgbaImage img = decoder.decode(ascii('P1\n1 1\n1\n'));
      expect(img.metadata.bitDepth, 1);
      expect(img.metadata.toDisplayMap()['maxval'], '1');
    });
  });
}

/// 断言某一行全是同一颜色。
void expectSolidColorRow(RgbaImage img, int y, List<int> rgba) {
  for (int x = 0; x < img.width; x++) {
    expectPixel(img, x, y, rgba);
  }
}
