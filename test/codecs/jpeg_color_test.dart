import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/codecs/jpeg/jpeg_color.dart';
import 'package:image_viewer/src/core/errors.dart';

/// JFIF 版 APP0 的载荷：`'JFIF' 0x00` + 版本 + 密度信息。
Uint8List jfifPayload() => Uint8List.fromList(<int>[
      0x4A, 0x46, 0x49, 0x46, 0x00, // 'JFIF\0'
      1, 1, // 版本 1.1
      0, // 密度单位
      0, 1, 0, 1, // Xdensity / Ydensity
      0, 0, // 缩略图尺寸
    ]);

/// Adobe 版 APP14 的载荷，[transform] 落在第 11 个字节。
Uint8List adobePayload(int transform) => Uint8List.fromList(<int>[
      0x41, 0x64, 0x6F, 0x62, 0x65, // 'Adobe'
      0x00, 0x64, // 版本 100
      0, 0, // flags0
      0, 0, // flags1
      transform,
    ]);

Uint8List plane(List<int> values) => Uint8List.fromList(values);

/// 把 [count] 个像素的单个通道填成同一个值。
Uint8List filled(int value, int count) => Uint8List(count)..fillRange(0, count, value);

/// 取第 [i] 个像素的 R,G,B,A。
List<int> pixel(Uint8List rgba, int i) =>
    <int>[rgba[i * 4], rgba[i * 4 + 1], rgba[i * 4 + 2], rgba[i * 4 + 3]];

/// 单像素走一遍 YCbCr → RGBA，返回四个通道。
List<int> ycc(int y, int cb, int cr) => pixel(
      convertToRgba(
        planes: <Uint8List>[plane(<int>[y]), plane(<int>[cb]), plane(<int>[cr])],
        colorSpace: JpegColorSpace.ycbcr,
        pixelCount: 1,
      ),
      0,
    );

/// 单像素走一遍 CMYK → RGBA。
List<int> cmyk(int c, int m, int y, int k, {bool inverted = false}) => pixel(
      convertToRgba(
        planes: <Uint8List>[
          plane(<int>[c]),
          plane(<int>[m]),
          plane(<int>[y]),
          plane(<int>[k]),
        ],
        colorSpace: JpegColorSpace.cmyk,
        pixelCount: 1,
        adobeInverted: inverted,
      ),
      0,
    );

/// 单像素走一遍 YCCK → RGBA。
List<int> ycck(int y, int cb, int cr, int k) => pixel(
      convertToRgba(
        planes: <Uint8List>[
          plane(<int>[y]),
          plane(<int>[cb]),
          plane(<int>[cr]),
          plane(<int>[k]),
        ],
        colorSpace: JpegColorSpace.ycck,
        pixelCount: 1,
      ),
      0,
    );

/// 浮点参考实现的收尾：四舍五入再截断。
int clampRef(double v) {
  final int r = v.round();
  return r < 0 ? 0 : (r > 255 ? 255 : r);
}

void main() {
  group('APP0 / APP14 识别', () {
    test('JFIF 版 APP0 被认出来', () {
      expect(isJfifApp0(jfifPayload()), isTrue);
    });

    test('JFXX 扩展段不算 JFIF 头', () {
      // 'JFXX\0'：同样是 APP0，但装的是缩略图，不能当色彩空间线索。
      expect(
        isJfifApp0(Uint8List.fromList(<int>[0x4A, 0x46, 0x58, 0x58, 0x00])),
        isFalse,
      );
    });

    test('太短的 APP0 不会越界，直接判否', () {
      expect(isJfifApp0(Uint8List.fromList(<int>[0x4A, 0x46])), isFalse);
      expect(isJfifApp0(Uint8List(0)), isFalse);
    });

    test('少了结尾的 0x00 就不是 JFIF', () {
      expect(
        isJfifApp0(Uint8List.fromList(<int>[0x4A, 0x46, 0x49, 0x46, 0x01])),
        isFalse,
      );
    });

    test('Adobe APP14 取出 transform 字节', () {
      expect(parseAdobeTransform(adobePayload(0)), 0);
      expect(parseAdobeTransform(adobePayload(1)), 1);
      expect(parseAdobeTransform(adobePayload(2)), 2);
    });

    test('非 Adobe 的 APP14 返回 null', () {
      // 长度够，但前五个字节不是 'Adobe'（这里是 Ducky 那类私有段）。
      final Uint8List payload = adobePayload(2);
      payload[0] = 0x44; // 'D'
      expect(parseAdobeTransform(payload), isNull);
    });

    test('长度不足 12 的 APP14 返回 null 而不是越界', () {
      expect(
        parseAdobeTransform(
          Uint8List.fromList(<int>[0x41, 0x64, 0x6F, 0x62, 0x65]),
        ),
        isNull,
      );
      expect(parseAdobeTransform(Uint8List(0)), isNull);
    });
  });

  group('色彩空间判定', () {
    test('单分量一律是灰阶', () {
      expect(
        chooseColorSpace(
            componentIds: <int>[1], hasJfif: false, adobeTransform: null),
        JpegColorSpace.grayscale,
      );
      // 就算带着 Adobe 段也不改判。
      expect(
        chooseColorSpace(
            componentIds: <int>[1], hasJfif: true, adobeTransform: 1),
        JpegColorSpace.grayscale,
      );
    });

    test('三分量默认 YCbCr', () {
      expect(
        chooseColorSpace(
            componentIds: <int>[1, 2, 3], hasJfif: false, adobeTransform: null),
        JpegColorSpace.ycbcr,
      );
    });

    test('分量 ID 是 R/G/B 且无标记时按 RGB 解释', () {
      expect(
        chooseColorSpace(
          componentIds: <int>[0x52, 0x47, 0x42],
          hasJfif: false,
          adobeTransform: null,
        ),
        JpegColorSpace.rgb,
      );
    });

    test('JFIF 压过 R/G/B 分量 ID', () {
      // 有编码器既写 JFIF 又把 ID 填成 'R','G','B'，但数据仍是 YCbCr。
      // 认 ID 会把颜色彻底解错，所以这条优先级不能反。
      expect(
        chooseColorSpace(
          componentIds: <int>[0x52, 0x47, 0x42],
          hasJfif: true,
          adobeTransform: null,
        ),
        JpegColorSpace.ycbcr,
      );
    });

    test('Adobe transform 决定三分量是 RGB 还是 YCbCr', () {
      expect(
        chooseColorSpace(
            componentIds: <int>[1, 2, 3], hasJfif: false, adobeTransform: 0),
        JpegColorSpace.rgb,
      );
      expect(
        chooseColorSpace(
            componentIds: <int>[1, 2, 3], hasJfif: false, adobeTransform: 1),
        JpegColorSpace.ycbcr,
      );
    });

    test('未知的 Adobe transform 当 YCbCr（跟 libjpeg 一致）', () {
      expect(
        chooseColorSpace(
            componentIds: <int>[1, 2, 3], hasJfif: false, adobeTransform: 99),
        JpegColorSpace.ycbcr,
      );
    });

    test('Adobe transform 压过 R/G/B 分量 ID', () {
      expect(
        chooseColorSpace(
          componentIds: <int>[0x52, 0x47, 0x42],
          hasJfif: false,
          adobeTransform: 1,
        ),
        JpegColorSpace.ycbcr,
      );
    });

    test('四分量：transform 0 是 CMYK，2 是 YCCK', () {
      expect(
        chooseColorSpace(
          componentIds: <int>[1, 2, 3, 4],
          hasJfif: false,
          adobeTransform: 0,
        ),
        JpegColorSpace.cmyk,
      );
      expect(
        chooseColorSpace(
          componentIds: <int>[1, 2, 3, 4],
          hasJfif: false,
          adobeTransform: 2,
        ),
        JpegColorSpace.ycck,
      );
    });

    test('四分量无 Adobe 段时当 CMYK 直存', () {
      expect(
        chooseColorSpace(
          componentIds: <int>[1, 2, 3, 4],
          hasJfif: false,
          adobeTransform: null,
        ),
        JpegColorSpace.cmyk,
      );
    });

    test('2 个或 5 个分量抛 UnsupportedImageFeature', () {
      for (final List<int> ids in <List<int>>[
        <int>[1, 2],
        <int>[1, 2, 3, 4, 5],
      ]) {
        expect(
          () => chooseColorSpace(
              componentIds: ids, hasJfif: false, adobeTransform: null),
          throwsA(isA<UnsupportedImageFeature>()),
          reason: '${ids.length} 个分量',
        );
      }
    });

    test('每种色彩空间都有可读的名字', () {
      expect(colorSpaceLabel(JpegColorSpace.grayscale), 'Grayscale');
      expect(colorSpaceLabel(JpegColorSpace.ycbcr), 'YCbCr (BT.601)');
      expect(colorSpaceLabel(JpegColorSpace.rgb), 'RGB');
      expect(colorSpaceLabel(JpegColorSpace.cmyk), 'CMYK');
      expect(colorSpaceLabel(JpegColorSpace.ycck), 'YCCK');
    });
  });

  group('灰阶与 RGB', () {
    test('灰阶把 Y 铺到三个通道，A 补 255', () {
      final Uint8List rgba = convertToRgba(
        planes: <Uint8List>[plane(<int>[0, 128, 255])],
        colorSpace: JpegColorSpace.grayscale,
        pixelCount: 3,
      );
      expect(rgba.length, 12);
      expect(pixel(rgba, 0), <int>[0, 0, 0, 255]);
      expect(pixel(rgba, 1), <int>[128, 128, 128, 255]);
      expect(pixel(rgba, 2), <int>[255, 255, 255, 255]);
    });

    test('RGB 三分量原样搬过去，不做任何变换', () {
      final Uint8List rgba = convertToRgba(
        planes: <Uint8List>[
          plane(<int>[10, 200]),
          plane(<int>[20, 100]),
          plane(<int>[30, 50]),
        ],
        colorSpace: JpegColorSpace.rgb,
        pixelCount: 2,
      );
      expect(pixel(rgba, 0), <int>[10, 20, 30, 255]);
      expect(pixel(rgba, 1), <int>[200, 100, 50, 255]);
    });

    test('平面比 pixelCount 长时只用前面那一截', () {
      // 升采样出来的平面可能带 MCU 补齐的余量，多出来的不该进画面。
      final Uint8List rgba = convertToRgba(
        planes: <Uint8List>[plane(<int>[7, 8, 99, 99])],
        colorSpace: JpegColorSpace.grayscale,
        pixelCount: 2,
      );
      expect(rgba.length, 8);
      expect(pixel(rgba, 0), <int>[7, 7, 7, 255]);
      expect(pixel(rgba, 1), <int>[8, 8, 8, 255]);
    });
  });

  group('YCbCr → RGB', () {
    test('中性色度（Cb=Cr=128）时 RGB 三通道都等于 Y', () {
      // 这是整个变换里唯一能闭式验证的点：色度居中意味着没有色偏，
      // 三个系数项全该归零。任何一处 -128 偏移写错都会在这里露出来。
      for (final int y in <int>[0, 1, 17, 128, 200, 254, 255]) {
        expect(ycc(y, 128, 128), <int>[y, y, y, 255], reason: 'Y=$y');
      }
    });

    test('纯红：色度饱和到 255 也只能还原出 254', () {
      // RGB(255,0,0) 正向变换得到 Y=76, Cb=85, Cr=255（Cr 的理想值是
      // 255.5，被 8 位截断了）。所以往回解拿不到 255 —— 这是量化损失，
      // 不是 bug。
      expect(ycc(76, 85, 255), <int>[254, 0, 0, 255]);
    });

    test('纯蓝同理，B 停在 254', () {
      expect(ycc(29, 255, 107), <int>[0, 0, 254, 255]);
    });

    test('超界的通道各自截断，不互相牵连', () {
      // 高端：R 溢出被压回 255，G 落在中间不受影响。
      expect(ycc(255, 128, 255), <int>[255, 164, 255, 255]);
      // 低端：R 算出来是 -179 被抬到 0，G 是 +91 保持原样。
      expect(ycc(0, 128, 0), <int>[0, 91, 0, 255]);
    });

    test('定点结果和浮点参考实现相差不超过 1', () {
      // 定点是为了跟 libjpeg 逐字节对上，但也得证明它确实在算 BT.601。
      // 容差 1 而不是 0：libjpeg 的系数取整到 2^-16，且它的四舍五入是
      // "half up"，而 Dart 的 round() 是"half away from zero" —— 半整数
      // 边界上会差一级（例如 1.772 × -125 = -221.5）。
      for (int y = 0; y <= 255; y += 17) {
        for (int cb = 0; cb <= 255; cb += 15) {
          for (int cr = 0; cr <= 255; cr += 15) {
            final List<int> got = ycc(y, cb, cr);
            final double fcb = cb - 128.0;
            final double fcr = cr - 128.0;
            final List<int> want = <int>[
              clampRef(y + 1.402 * fcr),
              clampRef(y - 0.344136 * fcb - 0.714136 * fcr),
              clampRef(y + 1.772 * fcb),
            ];
            for (int ch = 0; ch < 3; ch++) {
              expect(
                (got[ch] - want[ch]).abs(),
                lessThanOrEqualTo(1),
                reason: 'Y=$y Cb=$cb Cr=$cr 通道 $ch：得 ${got[ch]}，'
                    '参考 ${want[ch]}',
              );
            }
          }
        }
      }
    });
  });

  group('CMYK → RGB', () {
    test('直存 CMYK 的四个端点', () {
      expect(cmyk(0, 0, 0, 0), <int>[255, 255, 255, 255], reason: '无油墨=白');
      expect(cmyk(0, 0, 0, 255), <int>[0, 0, 0, 255], reason: 'K 满版=黑');
      expect(cmyk(255, 0, 0, 0), <int>[0, 255, 255, 255], reason: '纯青');
      expect(cmyk(0, 255, 0, 0), <int>[255, 0, 255, 255], reason: '纯洋红');
    });

    test('乘性公式：青 50% + 黑 50% 得到 63，不是 0', () {
      // 加性公式 255 - min(255, C + K) 在这里会给出 0，把这块压成纯黑。
      // 乘性把 K 当中性灰滤镜，更接近实际印刷 —— 这个数就是两者的分水岭。
      expect(cmyk(128, 0, 0, 128), <int>[63, 127, 127, 255]);
    });

    test('Adobe 反存：样本 255 表示没有油墨', () {
      expect(cmyk(255, 255, 255, 255, inverted: true), <int>[255, 255, 255, 255],
          reason: '全 255=白');
      expect(cmyk(255, 255, 255, 0, inverted: true), <int>[0, 0, 0, 255],
          reason: 'K 存 0 = 满版黑');
      expect(cmyk(0, 255, 255, 255, inverted: true), <int>[0, 255, 255, 255],
          reason: '纯青');
    });

    test('把输入取反后，两条路径结果一致', () {
      // 反存与直存只差一次 255-x，所以补码输入必须给出同一个像素。
      // 这条断言把"反存"钉成纯粹的输入变换，而不是另一套公式。
      for (final List<int> v in <List<int>>[
        <int>[128, 0, 0, 128],
        <int>[0, 0, 0, 0],
        <int>[255, 255, 255, 255],
        <int>[30, 90, 200, 17],
      ]) {
        expect(
          cmyk(255 - v[0], 255 - v[1], 255 - v[2], 255 - v[3], inverted: true),
          cmyk(v[0], v[1], v[2], v[3]),
          reason: '$v',
        );
      }
    });

    test('多像素时各通道不串位', () {
      final Uint8List rgba = convertToRgba(
        planes: <Uint8List>[
          plane(<int>[255, 0]),
          plane(<int>[0, 255]),
          plane(<int>[0, 0]),
          plane(<int>[0, 0]),
        ],
        colorSpace: JpegColorSpace.cmyk,
        pixelCount: 2,
      );
      expect(pixel(rgba, 0), <int>[0, 255, 255, 255]);
      expect(pixel(rgba, 1), <int>[255, 0, 255, 255]);
    });
  });

  group('YCCK → RGB', () {
    test('无油墨（Y=0、色度居中、K 存 255）解出白色', () {
      // YCCK 的 CMY 是取反后再做 YCbCr 的，所以"没有油墨"对应的是
      // R'G'B' = 0，也就是 Y=0 —— 直觉上反过来的那一头。
      expect(ycck(0, 128, 128, 255), <int>[255, 255, 255, 255]);
    });

    test('K 存 0（满版黑）压过一切色度', () {
      expect(ycck(0, 128, 128, 0), <int>[0, 0, 0, 255]);
      expect(ycck(200, 100, 50, 0), <int>[0, 0, 0, 255]);
    });

    test('色度居中且 K 存 255 时，输出是 Y 的反相灰阶', () {
      // 闭式验证点：ac = am = ay = 255 - Y，ak = 255，于是 RGB 全等于
      // 255 - Y。这条能同时抓住取反方向写错和 K 通道搭错位置。
      for (final int y in <int>[0, 50, 128, 200, 255]) {
        expect(ycck(y, 128, 128, 255), <int>[255 - y, 255 - y, 255 - y, 255],
            reason: 'Y=$y');
      }
    });

    test('纯青油墨：和 YCbCr 那条纯红用的是同一组样本', () {
      // 100% 青、其余为 0 → R'G'B' = (255,0,0)，正向变换给出
      // (76, 85, 255)，正是 YCbCr 组里"纯红"那个样本。色度截断让
      // R' 停在 254，所以青色差一级。
      expect(ycc(76, 85, 255), <int>[254, 0, 0, 255]);
      expect(ycck(76, 85, 255, 255), <int>[1, 255, 255, 255]);
    });
  });

  group('入参校验', () {
    test('分量个数不对就抛异常', () {
      expect(
        () => convertToRgba(
          planes: <Uint8List>[filled(0, 4), filled(0, 4)],
          colorSpace: JpegColorSpace.ycbcr,
          pixelCount: 4,
        ),
        throwsA(isA<ImageDecodeException>()),
      );
      expect(
        () => convertToRgba(
          planes: <Uint8List>[filled(0, 4), filled(0, 4), filled(0, 4)],
          colorSpace: JpegColorSpace.cmyk,
          pixelCount: 4,
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('平面短于 pixelCount 就抛异常，而不是越界崩掉', () {
      expect(
        () => convertToRgba(
          planes: <Uint8List>[filled(0, 4), filled(0, 3), filled(0, 4)],
          colorSpace: JpegColorSpace.ycbcr,
          pixelCount: 4,
        ),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('输出长度恒为 pixelCount × 4', () {
      for (final int n in <int>[1, 7, 64, 1000]) {
        final Uint8List rgba = convertToRgba(
          planes: <Uint8List>[filled(128, n)],
          colorSpace: JpegColorSpace.grayscale,
          pixelCount: n,
        );
        expect(rgba.length, n * 4, reason: 'n=$n');
      }
    });
  });
}
