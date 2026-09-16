/// RIFF 容器：WebP 里唯一被两套编解码器共用的部分。
///
/// ## 三种文件布局
///
/// ```
/// 简单有损： RIFF <len> WEBP  VP8  <len> <VP8 码流>
/// 简单无损： RIFF <len> WEBP  VP8L <len> <VP8L 码流>
/// 扩展：     RIFF <len> WEBP  VP8X <10> [ICCP] [ALPH] [VP8|VP8L] [EXIF] [XMP]
/// ```
///
/// 前两种是「一个 chunk 装完一切」，只有第三种需要真的遍历。
///
/// **透明的有损图必须走扩展布局**：VP8 码流本身没有 alpha 通道，透明度装在
/// 独立的 `ALPH` chunk 里。无损图不需要 —— VP8L 自带 alpha。这是 WebP 里
/// 「同一件事有两种实现」的又一处，和「两套编解码器」是同一个成因。
///
/// ## chunk 的偶数对齐
///
/// 载荷长度是奇数时后面要补一个填充字节，而这个字节**不计入长度字段**。
/// 漏掉它的症状很好认：前一两个 chunk 读得好好的，之后所有 tag 都成了乱码,
/// 因为整条链从那里开始错了一个字节。
///
/// ## 为什么不信 RIFF 的长度字段
///
/// `RIFF` 后面那个 32 位长度按规范等于「文件长度 - 8」。实际文件里它经常
/// 不准 —— 截断的下载、拼接的流、某些编码器的 off-by-one。所以这里只把它
/// 当**提示**：比实际字节数大就用实际值，比实际小就按它截断。真正的边界
/// 由每个 chunk 自己的长度字段决定。
///
/// 这条选择是有代价的：一个声称很大、实际很小的文件不会在这里被拒，而是
/// 在读某个具体 chunk 时报「文件在此处被截断」。后者的信息量更大 —— 它指
/// 得出是哪个 chunk 不完整。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/webp/webp_types.dart';
import 'package:image_viewer/src/core/byte_reader.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 一个 RIFF chunk。
class WebpChunk {
  const WebpChunk({
    required this.tag,
    required this.payload,
    required this.payloadOffset,
  });

  /// 四字符标签，如 `'VP8L'`。注意 `'VP8 '` 末尾那个空格是标签的一部分。
  final String tag;

  /// 载荷，零拷贝视图（不含末尾的对齐填充字节）。
  final Uint8List payload;

  /// 载荷在原文件里的起始偏移。异常信息里报它，便于拿 hex 编辑器跳过去。
  final int payloadOffset;

  @override
  String toString() => "WebpChunk('$tag', ${payload.length} 字节 @ "
      '0x${payloadOffset.toRadixString(16)})';
}

/// `VP8X` 的 10 字节载荷。
///
/// ## 画布尺寸和图像尺寸是两个数
///
/// `VP8X` 声明的是**画布**尺寸，而 `VP8`/`VP8L` 码流里还各自带一份自己的
/// 尺寸。静态图里两者必须相等，动画里则不必 —— 每一帧可以比画布小，靠
/// `ANMF` 里的偏移贴到画布上。
///
/// 所以静态图解出来后要**交叉检查**这两个数。不检查的话，一个畸形文件可以
/// 用 `VP8X` 声明 1×1、用 VP8L 声明 16384×16384，我们按后者分配内存。
class Vp8xInfo {
  const Vp8xInfo({
    required this.flags,
    required this.canvasWidth,
    required this.canvasHeight,
  });

  /// 标志字节原值，留着给信息面板显示。
  final int flags;

  final int canvasWidth;
  final int canvasHeight;

  /// 有独立的 `ALPH` chunk（只有有损图会用）。
  bool get hasAlpha => flags & 0x10 != 0;

  /// 是动画（有 `ANIM` / `ANMF`）。
  bool get hasAnimation => flags & 0x02 != 0;

  /// 带 ICC 色彩配置。本项目不做色彩管理，只在信息面板里如实说明。
  bool get hasIccProfile => flags & 0x20 != 0;

  bool get hasExif => flags & 0x08 != 0;
  bool get hasXmp => flags & 0x04 != 0;
}

/// 解析后的 WebP 容器。
class WebpContainer {
  WebpContainer._(this.chunks, this.vp8x, this.declaredSize, this.actualSize);

  /// 所有 chunk，按文件顺序。
  final List<WebpChunk> chunks;

  /// `VP8X` 的内容，简单布局下为 null。
  final Vp8xInfo? vp8x;

  /// `RIFF` 头里声称的大小（已加回那 8 字节），以及文件实际大小。
  ///
  /// 两者不等时不报错，但记下来给信息面板 —— 这是真实文件里最常见的
  /// 「技术上违规但无害」的毛病。
  final int declaredSize;
  final int actualSize;

  /// 是扩展布局。
  bool get isExtended => vp8x != null;

  /// 解析容器，不碰任何 chunk 的内容。
  static WebpContainer parse(Uint8List bytes) {
    final ByteReader r = ByteReader(bytes, format: kWebpFormat);

    final String riff = r.ascii(4, 'RIFF 标签');
    if (riff != kRiffTag) {
      throw ImageDecodeException(
        "不是 RIFF 容器：开头四字节是 '$riff'，应为 '$kRiffTag'",
        format: kWebpFormat,
        offset: 0,
      );
    }
    final int declared = r.u32le('RIFF 长度');
    final String webp = r.ascii(4, 'WEBP 标签');
    if (webp != kWebpTag) {
      throw ImageDecodeException(
        "RIFF 容器里装的不是 WebP：类型标签是 '$webp'，应为 '$kWebpTag'"
        '（RIFF 也用于 WAV、AVI 等格式）',
        format: kWebpFormat,
        offset: 8,
      );
    }

    // 长度字段只当提示：谁小听谁的。理由见库注释。
    final int declaredEnd = declared + 8;
    final int end = declaredEnd < bytes.length ? declaredEnd : bytes.length;

    final List<WebpChunk> chunks = <WebpChunk>[];
    Vp8xInfo? vp8x;

    // 少于 8 字节装不下一个 chunk 头，剩下的当尾部垃圾忽略。
    while (r.offset + 8 <= end) {
      final int headerAt = r.offset;
      final String tag = r.ascii(4, 'chunk 标签');
      final int size = r.u32le("chunk '$tag' 的长度");

      if (r.offset + size > end) {
        throw ImageDecodeException(
          "chunk '$tag' 声称有 $size 字节，但容器里只剩 ${end - r.offset} 字节",
          format: kWebpFormat,
          offset: headerAt,
        );
      }
      final int payloadAt = r.offset;
      final Uint8List payload = r.bytesView(size, "chunk '$tag' 的内容");
      chunks.add(WebpChunk(
        tag: tag,
        payload: payload,
        payloadOffset: payloadAt,
      ));

      if (tag == kChunkVp8x && vp8x == null) {
        vp8x = _parseVp8x(payload, payloadAt);
      }

      // 奇数长度后面补一个字节，且**不计入**长度字段。文件末尾缺这个
      // 填充字节的情况真实存在，宽容处理 —— 没有它也没有任何信息丢失。
      if (size.isOdd && r.offset < bytes.length) {
        r.skip(1, '对齐填充字节');
      }
    }

    if (chunks.isEmpty) {
      throw ImageDecodeException(
        'RIFF/WEBP 头之后没有任何 chunk，文件只有 ${bytes.length} 字节',
        format: kWebpFormat,
        offset: 12,
      );
    }

    return WebpContainer._(
      List<WebpChunk>.unmodifiable(chunks),
      vp8x,
      declaredEnd,
      bytes.length,
    );
  }

  /// 解析 `VP8X` 的 10 字节载荷。
  ///
  /// 布局：标志 1 字节 + 保留 3 字节 + 画布宽 3 字节 + 画布高 3 字节。
  /// 宽高都是 **24 位小端**，且存的是「实际值 - 1」—— 这个偏一在 WebP 里
  /// 到处都是（VP8L 的头也这样），因为宽高不可能是 0，省下的那个编码位
  /// 刚好让 24 位装到 16777216。
  static Vp8xInfo _parseVp8x(Uint8List payload, int at) {
    const int expected = 10;
    if (payload.length < expected) {
      throw ImageDecodeException(
        'VP8X 应有 $expected 字节，实际 ${payload.length} 字节',
        format: kWebpFormat,
        offset: at,
      );
    }
    final int flags = payload[0];

    // 没有 24 位读取方法，就地拼。小端：低位字节在前。
    int u24(int i) => payload[i] + payload[i + 1] * 256 + payload[i + 2] * 65536;

    return Vp8xInfo(
      flags: flags,
      canvasWidth: u24(4) + 1,
      canvasHeight: u24(7) + 1,
    );
  }

  /// 找第一个指定 tag 的 chunk，没有则返回 null。
  WebpChunk? find(String tag) {
    for (final WebpChunk c in chunks) {
      if (c.tag == tag) {
        return c;
      }
    }
    return null;
  }

  /// 装图像数据的那个 chunk（`VP8 ` 或 `VP8L`）。
  ///
  /// 动画的第一帧藏在 `ANMF` 里面，不在顶层，所以这里会返回 null ——
  /// 调用方据此报「暂不支持动画」，而不是报「没有图像数据」。
  WebpChunk? get imageChunk => find(kChunkVp8l) ?? find(kChunkVp8);

  /// 只用文件头判断是不是 WebP。给 `canDecode` 用，代价必须足够低。
  ///
  /// 只看 12 字节：`RIFF` + 4 字节长度 + `WEBP`。长度字段本身不检查 ——
  /// 它经常不准（见库注释），拿它当嗅探依据会拒掉能解的文件。
  static bool looksLikeWebp(Uint8List bytes) {
    if (bytes.length < 12) {
      return false;
    }
    const List<int> riff = <int>[0x52, 0x49, 0x46, 0x46]; // 'RIFF'
    const List<int> webp = <int>[0x57, 0x45, 0x42, 0x50]; // 'WEBP'
    for (int i = 0; i < 4; i++) {
      if (bytes[i] != riff[i] || bytes[8 + i] != webp[i]) {
        return false;
      }
    }
    return true;
  }
}
