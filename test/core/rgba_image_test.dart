import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

void main() {
  group('RgbaImage 构造与校验', () {
    test('alloc 得到全零（全透明）缓冲', () {
      final RgbaImage img = RgbaImage.alloc(2, 3);
      expect(img.width, 2);
      expect(img.height, 3);
      expect(img.pixels.length, 2 * 3 * 4);
      expect(img.pixels.every((int b) => b == 0), isTrue);
    });

    test('缓冲长度与尺寸不符时拒绝构造', () {
      expect(
        () => RgbaImage(width: 2, height: 2, pixels: Uint8List(15)),
        throwsA(isA<ImageDecodeException>()),
      );
    });
  });

  group('RgbaImage 尺寸校验 —— 不信任输入的安全阀', () {
    test('零与负数尺寸被拒', () {
      expect(
        () => RgbaImage.validateDimensions(0, 10),
        throwsA(isA<ImageDecodeException>()),
      );
      expect(
        () => RgbaImage.validateDimensions(10, -1),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('超过单边上限被拒', () {
      expect(
        () => RgbaImage.validateDimensions(kMaxImageDimension + 1, 1),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('像素总数溢出被拒 —— 防的就是声明 65535x65535 的恶意文件', () {
      // 65535 * 65535 * 4 ≈ 17GB，真分配下去进程就死了。
      expect(
        () => RgbaImage.validateDimensions(65535, 65535),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('溢出判定用先除后乘，中间结果不会自己先溢出', () {
      // width * height 若直接相乘，在 32 位环境下会绕回小正数从而漏过检查。
      // 这里断言的是"确实被拒了"，隐含验证了判定式的写法。
      expect(
        () => RgbaImage.validateDimensions(60000, 60000),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('合法尺寸通过', () {
      expect(() => RgbaImage.validateDimensions(1920, 1080), returnsNormally);
      expect(() => RgbaImage.validateDimensions(1, 1), returnsNormally);
    });

    test('异常信息带上格式名', () {
      try {
        RgbaImage.validateDimensions(0, 0, format: 'BMP');
        fail('应当抛异常');
      } on ImageDecodeException catch (e) {
        expect(e.format, 'BMP');
      }
    });
  });

  group('RgbaImage 像素读写', () {
    test('setPixel 与 channelsAt 往返一致', () {
      final RgbaImage img = RgbaImage.alloc(2, 2);
      img.setPixel(1, 0, 10, 20, 30, 40);
      expect(img.channelsAt(1, 0), <int>[10, 20, 30, 40]);
      expect(img.channelsAt(0, 0), <int>[0, 0, 0, 0]);
    });

    test('pixelAt 打包成 0xRRGGBBAA', () {
      final RgbaImage img = RgbaImage.alloc(1, 1);
      img.setPixel(0, 0, 0x12, 0x34, 0x56, 0x78);
      expect(img.pixelAt(0, 0), 0x12345678);
    });

    test('红色分量 ≥ 0x80 时结果仍是正数', () {
      // 位运算在 Web 上是 32 位有符号的，`0xFF << 24` 会得到 -16777216。
      // 这个断言在桌面上无论如何都过，它防的是 Web 上的回归。
      final RgbaImage img = RgbaImage.alloc(1, 1);
      img.setPixel(0, 0, 0xFF, 0x00, 0x00, 0xFF);
      expect(img.pixelAt(0, 0), 0xFF0000FF);
      expect(img.pixelAt(0, 0), greaterThan(0));
    });

    test('行优先直排，无行填充', () {
      // 第二行第一个像素的字节偏移应是 width * 4。
      final RgbaImage img = RgbaImage.alloc(3, 2);
      img.setPixel(0, 1, 0xFF, 0, 0, 0xFF);
      expect(img.pixels[3 * 4], 0xFF);
    });

    test('越界坐标抛 RangeError', () {
      final RgbaImage img = RgbaImage.alloc(2, 2);
      expect(() => img.pixelAt(2, 0), throwsRangeError);
      expect(() => img.pixelAt(0, -1), throwsRangeError);
      expect(() => img.channelsAt(0, 2), throwsRangeError);
    });
  });

  group('RgbaImage.hasTransparency', () {
    test('全不透明返回 false', () {
      final RgbaImage img = RgbaImage.alloc(2, 2);
      for (int i = 3; i < img.pixels.length; i += 4) {
        img.pixels[i] = 255;
      }
      expect(img.hasTransparency, isFalse);
    });

    test('存在半透明像素返回 true', () {
      final RgbaImage img = RgbaImage.alloc(2, 2);
      for (int i = 3; i < img.pixels.length; i += 4) {
        img.pixels[i] = 255;
      }
      img.pixels[7] = 128;
      expect(img.hasTransparency, isTrue);
    });
  });

  group('ImageMetadata', () {
    test('copyWith 只覆盖指定字段 —— 上层补解码耗时靠它', () {
      const ImageMetadata m = ImageMetadata(
        format: 'BMP',
        variant: 'BITMAPINFOHEADER',
        bitDepth: 8,
      );
      final ImageMetadata m2 = m.copyWith(
        decodeDuration: const Duration(milliseconds: 5),
      );
      expect(m2.format, 'BMP');
      expect(m2.variant, 'BITMAPINFOHEADER');
      expect(m2.bitDepth, 8);
      expect(m2.decodeDuration, const Duration(milliseconds: 5));
    });

    test('toDisplayMap 跳过未设置的字段', () {
      const ImageMetadata m = ImageMetadata(format: 'PNM');
      final Map<String, String> d = m.toDisplayMap();
      expect(d['格式'], 'PNM');
      expect(d.containsKey('原始位深'), isFalse);
      expect(d.containsKey('压缩'), isFalse);
    });

    test('toDisplayMap 摊平 extra 里的格式特有字段', () {
      const ImageMetadata m = ImageMetadata(
        format: 'JPEG',
        isLossless: false,
        extra: <String, Object>{'子采样': '4:2:0', '重启间隔': 8},
      );
      final Map<String, String> d = m.toDisplayMap();
      expect(d['有损/无损'], '有损');
      expect(d['子采样'], '4:2:0');
      expect(d['重启间隔'], '8');
    });
  });
}
