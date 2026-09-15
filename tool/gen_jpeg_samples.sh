#!/usr/bin/env bash
# 生成 assets/samples/ 下的 JPEG 样图，以及 test/assets/expected/ 下的
# 交叉验证参考。
#
# ## 为什么不写在 gen_samples.dart 里
#
# 其它格式的样图由 gen_samples.dart 逐字节写出，那个脚本不 import 项目里
# 任何解码代码 —— 生成器和解码器是两套独立实现，对上了才说明两边都对。
#
# JPEG 破不了这个格局：要逐字节写出一张 JPEG 得先有 DCT、量化和霍夫曼
# **编码器**，那是解码器代码量的量级。所以这里换一个更强的参照物：
# libjpeg-turbo 本身。cjpeg 压，djpeg 解，两个产物都提交进仓库。
#
# 于是每张样图有两个独立参考：
#
#   1. `test/assets/expected/*.pnm` —— djpeg 的解码结果。逐通道比对，
#      这是「和世界上最权威的实现算得一样吗」。
#   2. 压缩前的原图（assets/samples/gradient_*.ppm，本来就在仓库里）。
#      这是「解出来的还是那张图吗」—— 能抓住两边一起错的情况。
#
# 测试只读提交进来的文件，**不调用任何外部命令**（docs/testing.md 的铁律）。
# 这个脚本是开发时的一次性工具，不参与 CI。
#
# 用法： bash tool/gen_jpeg_samples.sh
# 依赖： libjpeg-turbo 的 cjpeg / djpeg（brew install jpeg-turbo）

set -euo pipefail
cd "$(dirname "$0")/.."

samples=assets/samples
expected=test/assets/expected
mkdir -p "$expected"

src_rgb=$samples/gradient_64x48.ppm   # R=255x/63, G=255y/47, B=96
src_gray=$samples/gradient_64x32.pgm  # 灰度 = 255x/63

# 每张样图钉住一个不同的解码路径。
# -sample 1x1 = 4:4:4，2x2 = 4:2:0，2x1 = 4:2:2。
cjpeg -quality 90 -sample 1x1 -outfile "$samples/gradient_64x48_q90_444.jpg" "$src_rgb"
cjpeg -quality 75 -sample 2x2 -outfile "$samples/gradient_64x48_q75_420.jpg" "$src_rgb"
cjpeg -quality 80 -sample 2x1 -restart 2 -outfile "$samples/gradient_64x48_q80_422rst.jpg" "$src_rgb"
cjpeg -quality 80 -progressive -sample 2x2 -outfile "$samples/gradient_64x48_q80_prog.jpg" "$src_rgb"
cjpeg -quality 85 -grayscale -outfile "$samples/gradient_64x32_q85_gray.jpg" "$src_gray"

# EXIF 方向：exiftool 不一定装得上，直接往 SOI 后面插一个 APP1 段。
# 载荷是一个最小的 TIFF：小端、一个 IFD、一条 Orientation=6（顺时针 90°）。
# 熵数据一字节没动 —— 所以这张图的像素与 q75_420 那张严格相同，只是方向不同。
python3 - "$samples/gradient_64x48_q75_420.jpg" "$samples/gradient_64x48_exif6.jpg" <<'PY'
import sys
src, dst = sys.argv[1], sys.argv[2]
payload = (
    b'Exif\x00\x00'
    b'II\x2a\x00' + (8).to_bytes(4, 'little') +   # 小端 TIFF 头 + IFD0 偏移
    (1).to_bytes(2, 'little') +                   # 1 个条目
    (0x0112).to_bytes(2, 'little') +              # Orientation
    (3).to_bytes(2, 'little') +                   # 类型 SHORT
    (1).to_bytes(4, 'little') +                   # count = 1
    (6).to_bytes(2, 'little') + b'\x00\x00' +     # 值左对齐补零
    (0).to_bytes(4, 'little')                     # 没有下一个 IFD
)
app1 = b'\xff\xe1' + (len(payload) + 2).to_bytes(2, 'big') + payload
data = open(src, 'rb').read()
assert data[:2] == b'\xff\xd8', '源文件不以 SOI 开头'
open(dst, 'wb').write(data[:2] + app1 + data[2:])
PY

# djpeg 的默认是 -dct int（islow）+ fancy upsampling，和我们的实现同路。
# 注意 djpeg 的 PNM 输出只支持 1 或 3 个分量，所以交叉验证覆盖不到 CMYK。
for f in gradient_64x48_q90_444 gradient_64x48_q75_420 \
         gradient_64x48_q80_422rst gradient_64x48_q80_prog \
         gradient_64x32_q85_gray; do
  djpeg -pnm -outfile "$expected/$f.pnm" "$samples/$f.jpg"
done

ls -l "$samples"/*.jpg "$expected"/*.pnm
