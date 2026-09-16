/// WebP 的容器常量、像素表示，以及两处 32 位陷阱的绕法。
///
/// ## 为什么像素用 `Uint32List` 装 ARGB
///
/// 前四种格式都是「读出通道 → 直接写进 RGBA 缓冲」，WebP 不行。VP8L 有两个
/// 环节把**整个像素**当成一个不可分的值来用：
///
/// * **颜色缓存**拿完整的 32 位 ARGB 算哈希，四个通道一起参与
/// * **LZ77 反向引用**整像素地往回拷，不是逐通道拷
///
/// 拆成四个平面就得在这两处反复拼装。所以 VP8L 内部一律用 `Uint32List`
/// 装 `0xAARRGGBB`，只在最后出图时摊成 RGBA8888。
///
/// 通道顺序刻意跟规范一致（A 在最高位），不是跟 [RgbaImage] 一致 —— 中间
/// 表示跟着规范走，读代码时才能和文档对照。
///
/// ## 陷阱一：不能用移位取通道
///
/// `Uint32List` 里的值可以到 0xFFFFFFFF，越过了 32 位**有符号**的范围。而
/// Dart 编译到 JS 后位运算是 32 位有符号语义，`v >> 24` 在 A ≥ 0x80 时结果
/// 可能带符号位。这个坑本项目已经踩过一次（`RgbaImage.pixelAt` 的
/// `<< 24`，见 `implementation.md` 第 3.11 节），代价是「桌面通过、Web 失败」
/// 这种最难查的症状。
///
/// 所以这里的通道存取一律用乘除和取模，不用移位。慢一点，但两个平台上
/// 结果一定相同。
///
/// ## 陷阱二：颜色缓存的哈希要真的 32 位截断
///
/// 规范的哈希是 `(0x1e35a7bd * argb) >> (32 - bits)`，其中乘法**要求**在
/// 32 位上回绕。原生 Dart 的 int 是 64 位，回绕不会自己发生；JS 的 number
/// 只有 53 位精度，两个 32 位数直接相乘会丢低位。两个平台的错法还不一样。
///
/// [mul32] 把乘法拆成 16 位半字来做，所有中间结果都不超过 2^53，于是两个
/// 平台得到同一个准确值。见那个函数的注释。
library;

/// 格式名，出现在异常信息与信息面板里。
const String kWebpFormat = 'WebP';

/// RIFF 容器的两个固定标签。
const String kRiffTag = 'RIFF';
const String kWebpTag = 'WEBP';

/// 各 chunk 的四字符标签。
///
/// 注意 `'VP8 '` **末尾有个空格** —— fourcc 恒为四字节，三个字母的标签用
/// 空格补齐。把它写成 `'VP8'` 是这个格式里最容易犯的错，而且症状很温和：
/// 有损图会被当成「不认识的 chunk」跳过，最后报一句「没有图像数据」。
const String kChunkVp8 = 'VP8 ';
const String kChunkVp8l = 'VP8L';
const String kChunkVp8x = 'VP8X';
const String kChunkAlph = 'ALPH';
const String kChunkAnim = 'ANIM';
const String kChunkAnmf = 'ANMF';
const String kChunkIccp = 'ICCP';
const String kChunkExif = 'EXIF';
const String kChunkXmp = 'XMP ';

/// VP8L 码流的第一个字节，规范固定为 `0x2F`。
///
/// 它不在 RIFF 层，是 `VP8L` chunk 内容的第 0 字节 —— 相当于码流自己的
/// 签名。存在的意义是让裸 VP8L 流（不套 RIFF）也能被认出来。
const int kVp8lSignature = 0x2F;

/// VP8L 的尺寸上限：头里宽高各占 **14 位**，存的是「实际值 - 1」。
///
/// 所以 VP8L 最大 16384×16384，比 [kMaxImageDimension]（65535）严格得多。
/// 这不是我们的安全阀，是格式本身的上限 —— 头里放不下更大的数。
const int kVp8lMaxDimension = 16384;

/// VP8L 头里的版本号字段宽度与唯一合法值。
const int kVp8lVersionBits = 3;
const int kVp8lVersion = 0;

/// 颜色缓存哈希的乘数，规范写死。
const int kColorCacheMultiplier = 0x1e35a7bd;

/// 2^32。取模用，写成常量比每处 `1 << 32` 清楚（且 `1 << 32` 在 Web 上是 0）。
const int kTwoPow32 = 4294967296;

/// 32 位回绕乘法。
///
/// 规范的颜色缓存哈希要求乘法在 32 位上**回绕**，而两个平台都不会自己
/// 给出这个结果：原生 Dart 的 int 是 64 位，乘积不回绕；编译到 JS 后 int
/// 是 double，只有 53 位精度，两个 32 位数相乘会丢掉低位。
///
/// 把 `a` 拆成两个 16 位半字就绕开了：
///
/// ```
/// a * b = (aHi * 65536 + aLo) * b = aHi * b * 65536 + aLo * b
/// ```
///
/// 对 2^32 取模时，`aHi * b * 65536` 只有 `aHi * b` 的低 16 位能活下来
/// （因为 65536 × 65536 = 2^32）。于是两个乘法的中间结果都不超过
/// 65535 × (2^32 - 1) ≈ 2.8×10^14，稳稳落在 2^53 以内 —— 两个平台算出
/// 同一个准确值。
int mul32(int a, int b) {
  final int aLo = a % 65536;
  final int aHi = (a ~/ 65536) % 65536;
  final int lo = (aLo * b) % kTwoPow32;
  final int hi = ((aHi * b) % 65536) * 65536;
  return (lo + hi) % kTwoPow32;
}

/// 颜色缓存的哈希：取 `0x1e35a7bd * argb` 的**高** [bits] 位。
///
/// 规范写的是 `>> (32 - bits)`。这里用除法代替右移，理由同本库开头 ——
/// 乘积可以到 0xFFFFFFFF，用 `>>` 在 Web 上会碰到符号位。
int colorCacheHash(int argb, int bits) =>
    mul32(kColorCacheMultiplier, argb) ~/ (1 << (32 - bits));

/// 从打包的 `0xAARRGGBB` 里取各通道。用除法取模而不是移位，理由见库注释。
int argbA(int argb) => (argb ~/ 16777216) % 256;
int argbR(int argb) => (argb ~/ 65536) % 256;
int argbG(int argb) => (argb ~/ 256) % 256;
int argbB(int argb) => argb % 256;

/// 打包成 `0xAARRGGBB`。入参必须已在 0..255，调用方负责。
int packArgb(int a, int r, int g, int b) =>
    a * 16777216 + r * 65536 + g * 256 + b;
