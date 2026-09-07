import 'dart:typed_data';

import 'package:image_viewer/src/codecs/bmp/bmp_header.dart';
import 'package:image_viewer/src/codecs/bmp/bmp_types.dart';
import 'package:image_viewer/src/core/errors.dart';

/// BMP 的游程编码（RLE4 / RLE8）解码器。
///
/// 输出的是**调色板索引**缓冲（每像素一字节），不是 RGBA —— 索引到颜色的
/// 映射留给主解码器，这样 RLE 逻辑与调色板逻辑互不纠缠。
///
/// ## 编码结构
///
/// 数据是一串两字节的命令对，第一字节的值决定如何解释第二字节：
///
/// ```
/// (n, v)   n >= 1   编码游程：输出 n 个像素
/// (0, 0)             行结束
/// (0, 1)             图像结束
/// (0, 2)   + dx, dy  增量跳转：当前位置移动 (dx, dy)
/// (0, n)   n >= 3    绝对模式：接下来 n 个像素是字面值
/// ```
///
/// ## 两个容易漏掉的规则
///
/// 1. **绝对模式的数据要填充到偶数字节**。RLE8 里 3 个像素占 3 字节，
///    但要补一个填充字节到 4；RLE4 里 3 个像素占 2 字节（打包成半字节），
///    正好是偶数就不补。漏掉填充会让后续所有命令错位。
///
/// 2. **未写到的像素保持索引 0**。增量跳转会跳过一片区域，行结束时
///    右边也可能有剩余。这些像素按规范是「未定义」，实践中一律填 0。
class BmpRleDecoder {
  /// 解码 RLE 数据，返回**存储顺序**（第一个解码出的行是缓冲第 0 行）
  /// 的调色板索引缓冲，长度 `width * height`。
  ///
  /// 行方向的翻转不在这里做 —— 主解码器对压缩与非压缩两条路统一处理，
  /// 保证翻转逻辑只有一份。
  static Uint8List decode(Uint8List bytes, BmpHeader header) {
    final int width = header.width;
    final int height = header.height;
    final bool isRle4 = header.compression == BmpCompression.rle4;

    // 未写到的像素保持 0
    final Uint8List indices = Uint8List(width * height);

    // 数据范围：从 bfOffBits 到「声明长度」或文件末尾。
    // biSizeImage 可能为 0 或撒谎，所以取两者的较小值兜底。
    int pos = header.pixelDataOffset;
    int end = bytes.length;
    if (header.declaredImageSize > 0) {
      final int declaredEnd = header.pixelDataOffset + header.declaredImageSize;
      if (declaredEnd < end) {
        end = declaredEnd;
      }
    }

    int x = 0;
    int y = 0;

    /// 写一个像素并右移。越界的写入静默丢弃 —— 畸形文件里游程长度
    /// 超出行宽是常见现象，不值得为此拒绝整个文件。
    void put(int index) {
      if (y >= 0 && y < height && x >= 0 && x < width) {
        indices[y * width + x] = index;
      }
      x++;
    }

    while (true) {
      if (pos + 1 >= end) {
        // 数据耗尽但没有显式的「图像结束」标记。现实中很常见，
        // 按已解出的部分返回而不是报错。
        break;
      }
      final int count = bytes[pos++];
      final int value = bytes[pos++];

      if (count > 0) {
        // —————— 编码游程 ——————
        if (isRle4) {
          // RLE4：一个字节里两个半字节交替输出。
          // 例：(5, 0xAB) → A B A B A
          final int hi = (value >> 4) & 0x0F;
          final int lo = value & 0x0F;
          for (int i = 0; i < count; i++) {
            put(i.isEven ? hi : lo);
          }
        } else {
          for (int i = 0; i < count; i++) {
            put(value);
          }
        }
        continue;
      }

      // —————— count == 0：转义命令 ——————
      switch (value) {
        case 0:
          // 行结束：回到行首，下移一行
          x = 0;
          y++;
        case 1:
          // 图像结束
          return indices;
        case 2:
          // 增量跳转
          if (pos + 1 >= end) {
            throw ImageDecodeException(
              'RLE 增量跳转命令后缺少 dx/dy 两个字节',
              format: 'BMP',
              offset: pos,
            );
          }
          x += bytes[pos++];
          y += bytes[pos++];
        default:
          // —————— 绝对模式：value 个字面像素 ——————
          final int pixelCount = value;
          if (isRle4) {
            // 半字节打包，两个像素一字节，向上取整
            final int dataBytes = (pixelCount + 1) ~/ 2;
            // 再填充到偶数字节
            final int padded = dataBytes.isOdd ? dataBytes + 1 : dataBytes;
            if (pos + dataBytes > end) {
              throw ImageDecodeException(
                'RLE4 绝对模式声明 $pixelCount 个像素（$dataBytes 字节），'
                '但只剩 ${end - pos} 字节',
                format: 'BMP',
                offset: pos,
              );
            }
            for (int i = 0; i < pixelCount; i++) {
              final int b = bytes[pos + (i >> 1)];
              put(i.isEven ? (b >> 4) & 0x0F : b & 0x0F);
            }
            pos += padded;
          } else {
            final int padded = pixelCount.isOdd ? pixelCount + 1 : pixelCount;
            if (pos + pixelCount > end) {
              throw ImageDecodeException(
                'RLE8 绝对模式声明 $pixelCount 个像素，'
                '但只剩 ${end - pos} 字节',
                format: 'BMP',
                offset: pos,
              );
            }
            for (int i = 0; i < pixelCount; i++) {
              put(bytes[pos + i]);
            }
            pos += padded;
          }
      }

      // 纵向跑出图像范围就停 —— 继续解也没有可写的地方了。
      if (y >= height) {
        break;
      }
    }

    return indices;
  }
}
