// 临时验证脚本，用完即删。
// 拿项目自己的 PNG / PNM 解码器解源图，和 WebP 解码器解出来的比对。
// 用法： dart run tool/scratch_xcheck.dart <src.png|src.ppm> <a.webp>
import 'dart:io';
import 'dart:typed_data';

import 'package:image_viewer/src/codecs/png/png_decoder.dart';
import 'package:image_viewer/src/codecs/pnm/pnm_decoder.dart';
import 'package:image_viewer/src/codecs/webp/webp_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

void main(List<String> args) {
  final Uint8List srcBytes = File(args[0]).readAsBytesSync();
  final RgbaImage src = args[0].endsWith('.png')
      ? const PngDecoder().decode(srcBytes)
      : const PnmDecoder().decode(srcBytes);
  final RgbaImage got = webpDecoder.decode(File(args[1]).readAsBytesSync());

  final Map<String, Object> x = got.metadata.extra;
  stdout.write('${got.width}x${got.height} | ${x['变换']} '
      '| 预测器 ${x['预测器模式'] ?? '-'} | 缓存 ${x['颜色缓存']} '
      '| ${x['码表组']} | ');

  if (src.width != got.width || src.height != got.height) {
    stdout.writeln('尺寸不一致 源 ${src.width}x${src.height}');
    exit(1);
  }
  int bad = 0;
  int maxDiff = 0;
  int firstBad = -1;
  for (int i = 0; i < got.pixels.length; i++) {
    final int d = (got.pixels[i] - src.pixels[i]).abs();
    if (d != 0) {
      bad++;
      if (firstBad < 0) firstBad = i;
      if (d > maxDiff) maxDiff = d;
    }
  }
  if (bad == 0) {
    stdout.writeln('逐字节一致 ✓');
    return;
  }
  final int px = firstBad ~/ 4;
  stdout.writeln('差 $bad 字节 最大 $maxDiff  首个 px '
      '(${px % got.width},${px ~/ got.width}) ch ${firstBad % 4}: '
      'ours ${got.pixels.sublist(px * 4, px * 4 + 4)} '
      'src ${src.pixels.sublist(px * 4, px * 4 + 4)}');
  exit(1);
}
