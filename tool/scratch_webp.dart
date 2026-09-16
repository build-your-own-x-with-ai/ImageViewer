// 临时验证脚本，用完即删。拿 dwebp 的 .pam 当参照物比对 VP8L 解码结果。
// 用法： dart run tool/scratch_webp.dart <a.webp> <a.pam>
import 'dart:io';
import 'dart:typed_data';

import 'package:image_viewer/src/codecs/webp/webp_decoder.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

({int width, int height, Uint8List pixels}) readPam(File f) {
  final Uint8List raw = f.readAsBytesSync();
  int p = 0;
  int width = 0;
  int height = 0;
  int depth = 0;
  while (true) {
    final int nl = raw.indexOf(0x0A, p);
    final String line = String.fromCharCodes(raw.sublist(p, nl)).trim();
    p = nl + 1;
    if (line == 'ENDHDR') {
      break;
    }
    final List<String> parts = line.split(RegExp(r'\s+'));
    if (parts.first == 'WIDTH') width = int.parse(parts[1]);
    if (parts.first == 'HEIGHT') height = int.parse(parts[1]);
    if (parts.first == 'DEPTH') depth = int.parse(parts[1]);
  }
  final Uint8List body = raw.sublist(p);
  // 归一到 RGBA
  final Uint8List out = Uint8List(width * height * 4);
  for (int i = 0; i < width * height; i++) {
    if (depth == 4) {
      out[i * 4] = body[i * 4];
      out[i * 4 + 1] = body[i * 4 + 1];
      out[i * 4 + 2] = body[i * 4 + 2];
      out[i * 4 + 3] = body[i * 4 + 3];
    } else {
      out[i * 4] = body[i * depth];
      out[i * 4 + 1] = body[i * depth + 1 % depth];
      out[i * 4 + 2] = body[i * depth + 2 % depth];
      out[i * 4 + 3] = 255;
    }
  }
  return (width: width, height: height, pixels: out);
}

void main(List<String> args) {
  final Uint8List bytes = File(args[0]).readAsBytesSync();
  final RgbaImage got = webpDecoder.decode(bytes);
  final ({int width, int height, Uint8List pixels}) want =
      readPam(File(args[1]));

  final Map<String, Object> x = got.metadata.extra;
  stdout.writeln('${got.width}x${got.height} | 变换 ${x['变换']} '
      '| 预测器 ${x['预测器模式'] ?? '-'} | 缓存 ${x['颜色缓存']} '
      '| ${x['码表组']}');
  if (got.width != want.width || got.height != want.height) {
    stdout.writeln('尺寸不一致');
    exit(1);
  }
  int bad = 0;
  int maxDiff = 0;
  int firstBad = -1;
  for (int i = 0; i < got.pixels.length; i++) {
    final int d = (got.pixels[i] - want.pixels[i]).abs();
    if (d != 0) {
      bad++;
      if (firstBad < 0) firstBad = i;
      if (d > maxDiff) maxDiff = d;
    }
  }
  stdout.writeln('不同字节 $bad / ${got.pixels.length}，最大差 $maxDiff');
  if (bad > 0) {
    final int px = firstBad ~/ 4;
    stdout.writeln('首个不同：字节 $firstBad = 像素 (${px % got.width}, '
        '${px ~/ got.width}) 通道 ${firstBad % 4}');
    for (int k = 0; k < 3; k++) {
      final int j = (px + k) * 4;
      stdout.writeln('  px ${px + k}: ours '
          '${got.pixels.sublist(j, j + 4)} ref ${want.pixels.sublist(j, j + 4)}');
    }
    exit(1);
  }
  stdout.writeln('逐字节一致 ✓');
}
