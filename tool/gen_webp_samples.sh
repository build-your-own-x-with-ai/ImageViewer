#!/usr/bin/env bash
# 生成 assets/samples/ 下的 WebP 样图。
#
# ## 为什么不需要 test/assets/expected/ 下的参考文件
#
# JPEG 那批样图得把 djpeg 的解码结果一起提交进来当参照（见
# gen_jpeg_samples.sh），因为 JPEG 是有损的 —— 压缩前的原图和解压后的结果
# 本来就不一样，只能拿另一个实现的输出比。
#
# 无损 WebP 没这个问题：`cwebp -lossless -exact` 的输出**必须**解回逐字节
# 相同的原图，这是格式的承诺。所以参照物就是压缩前的那张源图，而源图本来
# 就在仓库里 —— 一个字节的额外负担都没有。
#
# 于是交叉验证的链条是：
#
#   源图 --(cwebp，第三方编码器)--> .webp --(我们的解码器)--> RGBA
#     |                                                        |
#     +--(我们的 PNG/PNM 解码器)--> RGBA -------- 必须逐字节相同 --+
#
# 两边共享的代码是零：PNG 走 inflate + 逐行 filter，VP8L 走 LZ77 + Huffman
# + 四种变换，连位序都不一样（PNG 的 zlib 头是大端，VP8L 整条流是 LSB 优先）。
# 中间那个 cwebp 是完全独立的第三方。三方对上了，才说明三方都对。
#
# ## -exact 这个开关不能省
#
# 不加 -exact 时，cwebp 会把**全透明像素底下的 RGB 抹成 0** —— alpha 是 0，
# 那三个通道反正看不见，抹平了更好压。肉眼看不出区别，但这就不是逐字节无损了，
# 上面那条链子会在带透明像素的样图上断掉。
#
# 「无损」是关于**可见结果**的承诺，不是关于字节的承诺。想要后者得显式要求。
#
# ## 为什么 16 位灰度那张不在列表里
#
# assets/samples/ramp_64x64_gray16.png 是 16 位的，cwebp 必须先降到 8 位才能
# 编码，而它降位用的是截断（v >> 8），我们的 PNG 解码器用的是四舍五入
# （(v * 255 + 32767) / 65535）。16 位值 144 一个取 0 一个取 1，最大差 1。
#
# 两边都没错，只是舍入约定不同 —— 但这让源图不能再当参照物。核对过我们的
# WebP 解码结果和 dwebp 逐字节一致（16384 字节零差异），所以差异确实出在
# 编码器的降位上，不在解码器里。
#
# 测试只读提交进来的文件，**不调用任何外部命令**（docs/testing.md 的铁律）。
# 这个脚本是开发时的一次性工具，不参与 CI。
#
# 用法： bash tool/gen_webp_samples.sh
# 依赖： libwebp 的 cwebp / dwebp / webpmux（brew install webp）

set -euo pipefail
cd "$(dirname "$0")/.."

samples=assets/samples

# 每张样图钉住一组不同的 VP8L 特性。括号里是 cwebp 实际选中的变换 ——
# 不是我们指定的，是编码器按图的性质自己挑的，所以这一列是观察结果。
#
#   源图                        输出                                  变换
#   gradient_64x48.ppm          gradient_64x48_lossless.webp          预测器 + 颜色变换
#   hues_64x48_palette8.png     hues_64x48_lossless.webp              预测器 + 颜色变换
#   disc_64x64_rgba8.png        disc_64x64_lossless.webp              减绿 + 预测器 + 颜色变换，
#                                                                     带 alpha、2 组码表、颜色缓存
#   checker_35x24_gray1.png     checker_35x24_lossless.webp           只有减绿，宽 35 是奇数
#   rings_64x64_adam7.png       rings_64x64_lossless.webp             调色板（唯一一张走这条路的）
gen() {
  local src="$1" out="$2"
  cwebp -lossless -exact -m 6 -q 100 -quiet "$samples/$src" -o "$samples/$out"
  # 立刻用 dwebp 验一遍能解开，免得提交一个坏文件进仓库。
  dwebp -quiet "$samples/$out" -o /dev/null
  printf '  %-28s -> %-32s %5s 字节\n' "$src" "$out" "$(wc -c <"$samples/$out" | tr -d ' ')"
}

echo '简单无损布局（RIFF + WEBP + VP8L 三段）：'
gen gradient_64x48.ppm       gradient_64x48_lossless.webp
gen hues_64x48_palette8.png  hues_64x48_lossless.webp
gen disc_64x64_rgba8.png     disc_64x64_lossless.webp
gen checker_35x24_gray1.png  checker_35x24_lossless.webp
gen rings_64x64_adam7.png    rings_64x64_lossless.webp

# VP8X 扩展布局。透明的**有损**图必须用它（VP8 码流里没有 alpha 的位置，
# 只能另开一个 ALPH chunk，而顶层要放得下多个 chunk 就得有 VP8X）。
# 这里用无损图挂一段 EXIF 凑出同样的布局 —— 目的是测容器分派，不是测 EXIF。
echo 'VP8X 扩展布局（VP8X + VP8L + EXIF）：'
exif=$(mktemp)
# 最小的合法 TIFF：大端字节序、一个 IFD、一项 ImageDescription = "webp"。
printf 'Exif\x00\x00MM\x00\x2a\x00\x00\x00\x08\x00\x01\x01\x0e\x00\x02\x00\x00\x00\x05webp\x00\x00\x00\x00\x00\x00' >"$exif"
webpmux -set exif "$exif" "$samples/disc_64x64_lossless.webp" \
  -o "$samples/disc_64x64_vp8x_exif.webp" >/dev/null
rm -f "$exif"
printf '  %-28s -> %-32s %5s 字节\n' 'disc_64x64_lossless.webp' \
  'disc_64x64_vp8x_exif.webp' \
  "$(wc -c <"$samples/disc_64x64_vp8x_exif.webp" | tr -d ' ')"

echo
echo '完成。测试用 test/assets/samples_test.dart 里的 WebP 组核对。'
