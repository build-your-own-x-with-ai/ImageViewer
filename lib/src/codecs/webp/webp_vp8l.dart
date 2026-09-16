/// VP8L 无损解码：头部、变换、meta-Huffman、颜色缓存、LZ77。
///
/// ## 和 deflate 的关系
///
/// VP8L 的骨架就是 LZ77 + Huffman，和 PNG 用的 deflate 同源。但它在三个地方
/// 往前走了一步，而这三步都是为了利用「这是二维图像，不是一维字节流」：
///
/// | | deflate | VP8L |
/// |---|---|---|
/// | 距离 | 一维字节偏移 | 二维平面码，(x, y) 偏移 |
/// | 码表 | 整个块共用一套 | 每个区域一套（meta-Huffman） |
/// | 短距离重复 | 只能靠 LZ77 | 额外有颜色缓存 |
///
/// ## 一次读一个符号就知道接下来是什么
///
/// 绿色码表的字母表被塞了三样东西：256 个字面量 + 24 个长度码 + 颜色缓存大小。
/// 读出来的符号落在哪一段，就决定了这个位置是字面量、反向引用还是缓存命中 ——
/// **不需要额外的标志位**。这是 VP8L 最省的一处设计：deflate 也用同样的手法
/// （字面量和长度共用一张表），VP8L 把缓存也塞进去了。
///
/// ## 递归只有两层
///
/// `decodeStream` 会递归 —— 变换的参数图、meta-Huffman 的熵图像、调色板的色表，
/// 都是「一张小图」，用同一套代码解。但递归深度天然封顶在 2：只有第 0 层能读
/// 变换和 meta-Huffman，子图一律不能。所以不需要深度计数器，格式自己保证了。
library;

import 'dart:typed_data';

import 'package:image_viewer/src/codecs/webp/webp_types.dart';
import 'package:image_viewer/src/codecs/webp/webp_vp8l_huffman.dart';
import 'package:image_viewer/src/codecs/webp/webp_vp8l_transform.dart';
import 'package:image_viewer/src/core/bit_reader_lsb.dart';
import 'package:image_viewer/src/core/errors.dart';
import 'package:image_viewer/src/core/rgba_image.dart';

/// 平面码的个数。超过这个数的距离码走「直接减掉」的直线路径。
const int kCodeToPlaneCodes = 120;

/// 颜色缓存最多 11 位，也就是 2048 个槽。
const int kMaxColorCacheBits = 11;

/// 距离码 1..120 到二维偏移的映射表。
///
/// 高 4 位是 `yoffset`（往上几行），低 4 位是 `8 - xoffset`（往左几列，可以为负
/// 即往右）。120 个条目按**离原点的欧氏距离从近到远**排列，所以最常用的邻居
/// 拿到最小的码号，也就拿到最短的 Huffman 码。
///
/// 为什么恰好 120：`x ∈ [-7, 8]`、`y ∈ [0, 7]` 一共 128 组，去掉 8 组
/// `y == 0 && x <= 0` —— 那些指向当前像素自己或右边，都还没解出来。剩下 120。
///
/// 前六个条目是 `(0,1) (1,0) (1,1) (-1,1) (0,2) (2,0)`：正上方、正左方、左上、
/// 右上、上两行、左两列。图像里最可能重复的就是这几个方向，而一维的 deflate
/// 只能用「往前 width 个字节」这种迂回方式表达「正上方」。
///
/// 这张表是从本机安装的 libweb 1.6.0 里核对出来的，不是凭记忆写的：120 个字节
/// 恰好是 `0x00–0x07 ∪ 0x10–0x7F` 的一个排列，这个特征足以在二进制里唯一定位它。
const List<int> kCodeToPlane = <int>[
  0x18, 0x07, 0x17, 0x19, 0x28, 0x06, 0x27, 0x29, 0x16, 0x1A, 0x26, 0x2A,
  0x38, 0x05, 0x37, 0x39, 0x15, 0x1B, 0x36, 0x3A, 0x25, 0x2B, 0x48, 0x04,
  0x47, 0x49, 0x14, 0x1C, 0x35, 0x3B, 0x46, 0x4A, 0x24, 0x2C, 0x58, 0x45,
  0x4B, 0x34, 0x3C, 0x03, 0x57, 0x59, 0x13, 0x1D, 0x56, 0x5A, 0x23, 0x2D,
  0x44, 0x4C, 0x55, 0x5B, 0x33, 0x3D, 0x68, 0x02, 0x67, 0x69, 0x12, 0x1E,
  0x66, 0x6A, 0x22, 0x2E, 0x54, 0x5C, 0x43, 0x4D, 0x65, 0x6B, 0x32, 0x3E,
  0x78, 0x01, 0x77, 0x79, 0x53, 0x5D, 0x11, 0x1F, 0x64, 0x6C, 0x42, 0x4E,
  0x76, 0x7A, 0x21, 0x2F, 0x75, 0x7B, 0x31, 0x3F, 0x63, 0x6D, 0x52, 0x5E,
  0x00, 0x74, 0x7C, 0x41, 0x4F, 0x10, 0x20, 0x62, 0x6E, 0x30, 0x73, 0x7D,
  0x51, 0x5F, 0x40, 0x72, 0x7E, 0x61, 0x6F, 0x50, 0x71, 0x7F, 0x60, 0x70,
];

/// 平面码 → 线性像素距离。
///
/// 小于等于 120 的码查表得到 (x, y) 偏移，再折算成 `y * width + x`。大于 120 的
/// 码表示纯线性距离 `code - 120` —— 短距离用二维表达，长距离退回一维。
///
/// 末尾那个 `< 1 → 1` 不是防御性代码，是**窄图像必需**的：宽度只有 2 时，
/// 偏移 `(-7, 1)` 折算成 `1 * 2 - 7 = -5`，指向未来。规范就规定夹到 1。
int planeCodeToDistance(int width, int planeCode) {
  if (planeCode > kCodeToPlaneCodes) {
    return planeCode - kCodeToPlaneCodes;
  }
  final int code = kCodeToPlane[planeCode - 1];
  final int yOffset = code >> 4;
  final int xOffset = 8 - (code & 0xF);
  final int dist = yOffset * width + xOffset;
  return dist >= 1 ? dist : 1;
}

/// 颜色缓存：最近用过的颜色，按哈希索引。
///
/// 它补的是 LZ77 的一个短板。LZ77 只能表达「和前面某个**位置**一样」，代价是
/// 要传一个距离；如果一个颜色在图里零散地重复（比如文字的抗锯齿边缘用到的
/// 几十种灰），每次都要传距离，很贵。颜色缓存表达的是「和最近用过的某个
/// **颜色**一样」，代价只是一个绿色码表里的符号 —— 没有额外的距离。
///
/// 没有淘汰策略，也没有冲突处理：新颜色直接覆盖同槽的旧颜色。这是可以的，
/// 因为编码器用同一套规则维护同一份缓存，双方状态永远一致 —— 缓存的作用
/// 是压缩，不是正确性。
class Vp8lColorCache {
  Vp8lColorCache(this.bits) : _colors = Uint32List(1 << bits);

  final int bits;
  final Uint32List _colors;

  int get size => _colors.length;

  /// 哈希是乘一个奇数常量再取高 `bits` 位 —— 乘法把低位的差异搅到高位去，
  /// 所以只看高位也能区分只差一点的颜色。`mul32` 处理 32 位回绕，见
  /// `webp_types.dart` 里那段说明：这里**依赖**溢出截断，两个平台都不自带。
  void insert(int argb) => _colors[colorCacheHash(argb, bits)] = argb;

  int lookup(int key) => _colors[key];
}

/// 长度码和距离码共用的「前缀值」解码。
///
/// 结构和 deflate 的长度/距离码一样：小符号直接是值，大符号带若干额外位。
/// 符号 0..3 直接给出 1..4；从符号 4 开始每两个符号额外位数加一，覆盖范围
/// 指数增长，最大到 2^20。
///
/// 这一处 VP8L 比 deflate 更整齐：deflate 的长度码和距离码用两张不同的
/// 额外位表（还有那个「长度 258 是特例」的补丁），VP8L 两者同一个公式。
int readLz77Value(BitReaderLsb reader, int symbol) {
  if (symbol < 4) {
    return symbol + 1;
  }
  final int extraBits = (symbol - 2) >> 1;
  final int offset = (2 + (symbol & 1)) << extraBits;
  return offset + reader.readBits(extraBits) + 1;
}

/// 一次 VP8L 解码的结果。
class Vp8lResult {
  const Vp8lResult({
    required this.width,
    required this.height,
    required this.pixels,
    required this.hasAlpha,
    required this.features,
  });

  final int width;
  final int height;

  /// `0xAARRGGBB`，长度恒为 `width * height`。
  final Uint32List pixels;

  /// 头部里的 alpha 提示位。**只是提示** —— 置位不代表真有透明像素，
  /// 不置位也不能拿来省掉 alpha 码表（码表永远存在）。
  final bool hasAlpha;

  /// 这条流实际用到了哪些特性。给信息面板和教学模式看。
  final Vp8lFeatures features;
}

/// 一条 VP8L 流实际用到的特性。
///
/// 这些不是解码必需的信息 —— 解码器边读边用就丢了。留下来是因为它们是这张图
/// **为什么这么小**的答案：同样一张 128×96，用了熵图像的和没用的能差一倍体积。
/// 教学模式把它显示出来，比让人去猜要好。
///
/// 顺带也让「这批样图到底覆盖了几条路径」变成可以核对的事实，而不是我的假设。
class Vp8lFeatures {
  const Vp8lFeatures({
    required this.transforms,
    required this.colorCacheBits,
    required this.huffmanGroups,
    required this.predictorModes,
  });

  /// 按码流顺序（也就是编码时的施加顺序）。
  final List<Vp8lTransformType> transforms;

  /// 0 表示没开颜色缓存。
  final int colorCacheBits;

  /// 码表组数。大于 1 意味着用了 meta-Huffman 熵图像。
  final int huffmanGroups;

  /// 预测器变换实际用到的模式号，升序。没用预测器变换时为空。
  final List<int> predictorModes;

  bool get usesMetaHuffman => huffmanGroups > 1;
  bool get usesColorCache => colorCacheBits > 0;
}

/// VP8L 的 5 字节头部。
///
/// 一个签名字节 `0x2F`，然后是位流：宽 14 位、高 14 位、alpha 提示 1 位、
/// 版本 3 位。宽高存的都是**实际值减一**，所以 14 位能表示 1..16384 ——
/// 这就是 VP8L 的尺寸上限，比项目那道 65535 的安全阀更严。
class Vp8lHeader {
  const Vp8lHeader({
    required this.width,
    required this.height,
    required this.hasAlpha,
  });

  final int width;
  final int height;
  final bool hasAlpha;

  static Vp8lHeader read(BitReaderLsb reader) {
    final int signature = reader.readBits(8);
    if (signature != kVp8lSignature) {
      throw ImageDecodeException(
        'VP8L 签名应为 0x2F，实际是 '
        '0x${signature.toRadixString(16).padLeft(2, '0')}',
        format: kWebpFormat,
      );
    }
    final int width = reader.readBits(14) + 1;
    final int height = reader.readBits(14) + 1;
    final bool hasAlpha = reader.readBit() == 1;
    final int version = reader.readBits(kVp8lVersionBits);
    if (version != kVp8lVersion) {
      throw ImageDecodeException(
        'VP8L 版本号只认 0，实际是 $version',
        format: kWebpFormat,
      );
    }
    return Vp8lHeader(width: width, height: height, hasAlpha: hasAlpha);
  }
}

/// meta-Huffman：整张图分区域用不同的码表组。
///
/// 这是 VP8L 里最漂亮的一处设计。deflate 一个块只有一套码表，遇到「左半边是
/// 照片、右半边是纯色」这种图只能折中。VP8L 传一张**熵图像** —— 一张 tile
/// 分辨率的小图，每个像素说「这块 tile 用第几组码表」。组号由熵图像像素的
/// 红、绿两个通道拼成 16 位，所以最多 65536 组。
///
/// 妙在这张熵图像本身也是一张 VP8L 图，用同一套解码器递归解出来。「用图像
/// 描述图像的编码方式」—— 而代价只是复用已有的代码。
class Vp8lMetaHuffman {
  const Vp8lMetaHuffman({
    required this.groups,
    required this.image,
    required this.bits,
    required this.tilesPerRow,
  });

  final List<Vp8lHuffmanGroup> groups;

  /// 熵图像。为 null 表示整张图共用 `groups[0]`（最常见的情况）。
  final Uint32List? image;

  final int bits;
  final int tilesPerRow;

  /// 查线性位置 `pos` 处的像素该用哪组码表。
  ///
  /// 传线性位置而不是 (x, y)，是为了让最常见的情形（只有一组码表）连除法都
  /// 不用做 —— 直接返回 `groups[0]`。只有真用了熵图像时才折算坐标。
  Vp8lHuffmanGroup groupAt(int pos, int width) {
    final Uint32List? img = image;
    if (img == null) {
      return groups[0];
    }
    final int x = pos % width;
    final int y = pos ~/ width;
    final int meta = img[(y >> bits) * tilesPerRow + (x >> bits)];
    // 组号 = 红 << 8 | 绿。用两个通道拼，因为单通道只有 8 位不够。
    final int index = argbR(meta) * 256 + argbG(meta);
    if (index >= groups.length) {
      throw ImageDecodeException(
        '熵图像指向第 $index 组码表，但只传了 ${groups.length} 组',
        format: kWebpFormat,
      );
    }
    return groups[index];
  }
}

/// 一次「图像流」解码的中间结果。
///
/// 主图像和子图（变换参数图、熵图像、调色板色表）走的是同一条路，所以返回的
/// 也是同一个类型。宽度单独带出来，是因为调色板变换会让它和入参不一样。
typedef Vp8lStream = ({int width, int height, Uint32List pixels});

/// VP8L 解码器本体。
///
/// 拿一个类而不是一堆函数，是因为**递归**：变换的参数图、熵图像、调色板色表
/// 都要回到 `decodeStream` 重新走一遍，共享同一个位读取器。
class Vp8lDecoder {
  Vp8lDecoder(this.reader);

  final BitReaderLsb reader;

  final List<Vp8lTransformType> _transforms = <Vp8lTransformType>[];
  int _cacheBits = 0;
  int _huffmanGroups = 1;
  List<int> _predictorModes = const <int>[];

  /// 主图像用到的特性。要在 [decodeStream] 之后读。
  ///
  /// 只记第 0 层的 —— 子图（参数图、熵图像、色表）自己也有码表和缓存，但那些
  /// 是实现细节，不是这张图的特征。
  Vp8lFeatures get features => Vp8lFeatures(
        transforms: List<Vp8lTransformType>.unmodifiable(_transforms),
        colorCacheBits: _cacheBits,
        huffmanGroups: _huffmanGroups,
        predictorModes: _predictorModes,
      );

  /// 解一整条图像流。
  ///
  /// `isLevel0` 区分主图像和子图。只有主图像能读变换和 meta-Huffman；子图不能，
  /// 这就是递归深度封顶在 2 的原因。
  Vp8lStream decodeStream(int width, int height, {required bool isLevel0}) {
    int xsize = width;
    final List<Vp8lTransform> transforms = <Vp8lTransform>[];

    if (isLevel0) {
      int seen = 0;
      // 变换是可选的、可叠加的，用一个「还有下一个吗」的标志位串起来。
      while (reader.readBit() == 1) {
        if (transforms.length >= kMaxTransforms) {
          throw ImageDecodeException(
            '变换个数超过 $kMaxTransforms，畸形码流',
            format: kWebpFormat,
          );
        }
        final Vp8lTransform t = _readTransform(xsize, height, seen);
        seen |= 1 << t.type.index;
        transforms.add(t);
        _transforms.add(t.type);
        if (t.type == Vp8lTransformType.predictor) {
          // 参数图的绿色通道就是模式号。扫一遍看实际用到哪几种 —— 14 种
          // 预测器是 14 条独立的代码路径，知道覆盖了几条比猜要好。
          final Set<int> modes = <int>{};
          for (final int p in t.data!) {
            modes.add(argbG(p) & 0xF);
          }
          _predictorModes = modes.toList()..sort();
        }
        // 调色板变换会把图像挤窄，后面的变换和主图像都按新宽度走。
        if (t.type == Vp8lTransformType.colorIndexing) {
          xsize = subSampleSize(xsize, t.bits);
        }
      }
    }

    // 颜色缓存的位数。0 表示不用缓存。
    int cacheBits = 0;
    if (reader.readBit() == 1) {
      cacheBits = reader.readBits(4);
      if (isLevel0) {
        _cacheBits = cacheBits;
      }
      if (cacheBits < 1 || cacheBits > kMaxColorCacheBits) {
        throw ImageDecodeException(
          '颜色缓存位数 $cacheBits 越界，合法范围 1..$kMaxColorCacheBits',
          format: kWebpFormat,
        );
      }
    }

    final Vp8lMetaHuffman meta = _readMetaHuffman(
      xsize,
      height,
      cacheBits,
      allowMeta: isLevel0,
    );
    if (isLevel0) {
      _huffmanGroups = meta.groups.length;
    }

    final Uint32List pixels =
        _decodeImageData(xsize, height, meta, cacheBits);

    if (transforms.isEmpty) {
      return (width: xsize, height: height, pixels: pixels);
    }
    // 逆变换之后宽度回到声明值 —— 调色板变换把打包的像素摊开了。
    return (
      width: width,
      height: height,
      pixels: applyInverseTransforms(transforms, pixels),
    );
  }

  /// 读一个变换头及其参数图。
  Vp8lTransform _readTransform(int width, int height, int seen) {
    final int raw = reader.readBits(2);
    final Vp8lTransformType type = Vp8lTransformType.values[raw];
    checkTransformNotSeen(seen, type);

    switch (type) {
      case Vp8lTransformType.predictor:
      case Vp8lTransformType.crossColor:
        // tile 边长的位数：读 3 位加 2，也就是 4×4 到 512×512。
        final int bits = reader.readBits(kTransformBitsCount) +
            kMinTransformBits;
        final Vp8lStream sub = decodeStream(
          subSampleSize(width, bits),
          subSampleSize(height, bits),
          isLevel0: false,
        );
        return Vp8lTransform(
          type: type,
          bits: bits,
          width: width,
          height: height,
          data: sub.pixels,
        );

      case Vp8lTransformType.colorIndexing:
        final int numColors = reader.readBits(8) + 1;
        final int bits = colorIndexBits(numColors);
        // 色表是一张 numColors × 1 的图 —— 一维图像，同一套解码器。
        final Vp8lStream sub = decodeStream(numColors, 1, isLevel0: false);
        return Vp8lTransform(
          type: type,
          bits: bits,
          width: width,
          height: height,
          data: expandColorMap(sub.pixels, numColors, bits),
        );

      case Vp8lTransformType.subtractGreen:
        // 没有参数，也没有 tile。
        return Vp8lTransform(
          type: type,
          bits: 0,
          width: width,
          height: height,
        );
    }
  }

  /// 读码表组，可能先读一张熵图像。
  Vp8lMetaHuffman _readMetaHuffman(
    int width,
    int height,
    int cacheBits, {
    required bool allowMeta,
  }) {
    int bits = 0;
    int tilesPerRow = 0;
    Uint32List? image;
    int numGroups = 1;

    if (allowMeta && reader.readBit() == 1) {
      bits = reader.readBits(3) + 2;
      final Vp8lStream sub = decodeStream(
        subSampleSize(width, bits),
        subSampleSize(height, bits),
        isLevel0: false,
      );
      image = sub.pixels;
      tilesPerRow = sub.width;
      // 组数不单独传，是从熵图像里最大的组号推出来的 —— 少传一个数。
      int maxIndex = 0;
      for (int i = 0; i < image.length; i++) {
        final int index = argbR(image[i]) * 256 + argbG(image[i]);
        if (index > maxIndex) {
          maxIndex = index;
        }
      }
      numGroups = maxIndex + 1;
    }

    final int cacheSize = cacheBits > 0 ? 1 << cacheBits : 0;
    final List<Vp8lHuffmanGroup> groups = <Vp8lHuffmanGroup>[];
    for (int i = 0; i < numGroups; i++) {
      groups.add(Vp8lHuffmanGroup.read(reader, cacheSize));
    }

    return Vp8lMetaHuffman(
      groups: groups,
      image: image,
      bits: bits,
      tilesPerRow: tilesPerRow,
    );
  }

  /// 主解码循环：一个绿色符号定三条路。
  ///
  /// 绿色码表的字母表是 `256 个字面量 + 24 个长度码 + 缓存大小`，读出来的符号
  /// 落在哪一段就走哪条路：
  ///
  /// * `< 256` —— 字面量。这个数就是绿色分量，再读红、蓝、alpha 三个符号；
  /// * `< 280` —— 反向引用。符号减 256 是长度码，接着读距离码；
  /// * 更大 —— 颜色缓存命中。符号减 280 直接就是缓存槽号。
  ///
  /// 三条路共用一个符号，不花一个额外的位去说「接下来是哪种」。
  ///
  /// 注意读取顺序是**绿、红、蓝、alpha** —— 绿色第一，因为它同时兼任那个
  /// 三选一的判据。顺序写错了图会整体串色，而且是很好看的那种串色，容易
  /// 误以为是别处的 bug。
  Uint32List _decodeImageData(
    int width,
    int height,
    Vp8lMetaHuffman meta,
    int cacheBits,
  ) {
    final int total = width * height;
    final Uint32List pixels = Uint32List(total);
    final Vp8lColorCache? cache =
        cacheBits > 0 ? Vp8lColorCache(cacheBits) : null;
    final int cacheBase = kNumLiteralCodes + kNumLengthCodes;

    int pos = 0;
    while (pos < total) {
      final Vp8lHuffmanGroup g = meta.groupAt(pos, width);
      final int green = g.green.decode(reader);

      if (green < kNumLiteralCodes) {
        final int red = g.red.decode(reader);
        final int blue = g.blue.decode(reader);
        final int alpha = g.alpha.decode(reader);
        final int argb = packArgb(alpha, red, green, blue);
        pixels[pos] = argb;
        cache?.insert(argb);
        pos++;
      } else if (green < cacheBase) {
        final int length = readLz77Value(reader, green - kNumLiteralCodes);
        // 距离要过两道手：先用和长度完全相同的额外位规则解出**平面码**，
        // 再把平面码折算成线性距离。少了哪一道都会得到一个看似合理的
        // 距离，然后整张图从第一个反向引用开始崩。
        final int distSymbol = g.distance.decode(reader);
        final int planeCode = readLz77Value(reader, distSymbol);
        final int distance = planeCodeToDistance(width, planeCode);
        if (distance > pos) {
          throw ImageDecodeException(
            '反向引用距离 $distance 超过已解出的 $pos 个像素',
            format: kWebpFormat,
          );
        }
        if (length > total - pos) {
          throw ImageDecodeException(
            '反向引用长度 $length 超出剩余的 ${total - pos} 个像素',
            format: kWebpFormat,
          );
        }
        // 逐个复制，不能整段搬 —— 距离可能小于长度，此时后面复制的正是
        // 前面刚写出来的，靠这个自我重叠实现「重复一个图案 N 次」。
        // 和 deflate 的重叠拷贝是同一个把戏。
        final int src = pos - distance;
        for (int i = 0; i < length; i++) {
          final int argb = pixels[src + i];
          pixels[pos + i] = argb;
          cache?.insert(argb);
        }
        pos += length;
      } else {
        if (cache == null) {
          throw ImageDecodeException(
            '出现颜色缓存符号 $green，但这条流没有开缓存',
            format: kWebpFormat,
          );
        }
        final int key = green - cacheBase;
        if (key >= cache.size) {
          throw ImageDecodeException(
            '颜色缓存槽号 $key 超出缓存容量 ${cache.size}',
            format: kWebpFormat,
          );
        }
        final int argb = cache.lookup(key);
        pixels[pos] = argb;
        cache.insert(argb);
        pos++;
      }
    }
    return pixels;
  }
}

/// 解一个完整的 `VP8L` chunk 载荷（含 5 字节头部）。
Vp8lResult decodeVp8l(Uint8List payload) {
  final BitReaderLsb reader = BitReaderLsb(payload, format: kWebpFormat);
  final Vp8lHeader header = Vp8lHeader.read(reader);
  // 14 位宽高最大 16384×16384 = 2.7 亿像素，超过项目的总像素上限，
  // 所以格式上限之外还要过一遍全局安全阀。
  RgbaImage.validateDimensions(
    header.width,
    header.height,
    format: kWebpFormat,
  );
  final Vp8lDecoder decoder = Vp8lDecoder(reader);
  final Vp8lStream out =
      decoder.decodeStream(header.width, header.height, isLevel0: true);
  return Vp8lResult(
    width: out.width,
    height: out.height,
    pixels: out.pixels,
    hasAlpha: header.hasAlpha,
    features: decoder.features,
  );
}

/// 解一条**没有头部**的 VP8L 流，尺寸由调用方给出。
///
/// 这是给 `ALPH` chunk 用的：透明通道的压缩路径就是一条 VP8L 流，但宽高已经由
/// 主图像确定了，再传一遍是浪费 —— 所以那条流从第一个变换标志位直接开始。
///
/// 同一套解码器服务两个入口，差别只在「头部谁给」。
Uint32List decodeVp8lRaw(Uint8List payload, int width, int height) {
  final BitReaderLsb reader = BitReaderLsb(payload, format: kWebpFormat);
  return Vp8lDecoder(reader)
      .decodeStream(width, height, isLevel0: true)
      .pixels;
}
