import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image_viewer/src/compress/inflate.dart';
import 'package:image_viewer/src/core/errors.dart';

import '../support/deflate_builders.dart';

Uint8List bytes(List<int> b) => Uint8List.fromList(b);

/// 解一条 zlib 流并取出字节。
List<int> unzlib(List<int> stream) => inflateZlib(bytes(stream)).bytes.toList();

void main() {
  group('zlib 头部（RFC 1950）', () {
    test('标准的 0x78 0x01 头被接受', () {
      expect(unzlib(storedZlib(const <int>[1, 2, 3])), <int>[1, 2, 3]);
    });

    test('压缩方法非 8 被拒', () {
      // CM 字段四位，规范只定义了 8（deflate）。7 是保留值。
      final Uint8List s = storedZlib(const <int>[1]);
      s[0] = 0x77; // CM = 7
      expect(
        () => inflateZlib(s),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('CINFO 超过 7 被拒', () {
      // CINFO 是窗口大小的对数减 8，最大 7（对应 32KB）。
      // 更大的窗口 deflate 根本不支持。
      final Uint8List s = storedZlib(const <int>[1]);
      s[0] = 0x88; // CINFO = 8
      s[1] = 0x1C; // 重算 FCHECK：0x881C % 31 == 0，好让它死在 CINFO 上
      expect((0x88 * 256 + 0x1C) % 31, 0, reason: '这个头部应先通过 FCHECK');
      expect(
        () => inflateZlib(s),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('CINFO'),
          ),
        ),
      );
    });

    test('FCHECK 校验不过被拒', () {
      // 两字节头部当作大端 16 位整数必须能被 31 整除。这是个极弱的
      // 校验，但足以挡住「把随便两个字节当 zlib 头」的情况。
      final Uint8List s = storedZlib(const <int>[1]);
      s[1] = 0x02; // 0x7802 % 31 != 0
      expect(
        () => inflateZlib(s),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('31'),
          ),
        ),
      );
    });

    test('FDICT 置位时报「不支持」而非「损坏」', () {
      // 预设字典在 PNG 里被明令禁止。它不是坏数据，是我们不支持的
      // 合法特性 —— 所以该抛 UnsupportedImageFeature，两者的区别
      // 直接影响用户看到的提示该是「文件坏了」还是「本程序不支持」。
      final Uint8List s = storedZlib(const <int>[1]);
      s[1] = 0x20; // FDICT 位；0x7820 % 31 == 0，刚好也通过 FCHECK
      expect((0x78 * 256 + 0x20) % 31, 0, reason: '这个头部应先通过 FCHECK');
      expect(() => inflateZlib(s), throwsA(isA<UnsupportedImageFeature>()));
    });

    test('缺少尾部 Adler-32 被拒', () {
      final List<int> full = storedZlib(const <int>[1, 2, 3]);
      expect(
        () => inflateZlib(bytes(full.sublist(0, full.length - 2))),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('Adler-32 不匹配被拒', () {
      // 这是自写 inflate 最重要的一道防线：解压逻辑一旦出错，产物的
      // 校验和几乎必然不对。没有它，一个位移写反的 bug 会静默产出
      // 花屏图像而不是报错。
      final Uint8List s = storedZlib(const <int>[1, 2, 3]);
      s[s.length - 1] ^= 0xFF;
      expect(
        () => inflateZlib(s),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('Adler-32'),
          ),
        ),
      );
    });

    test('Adler-32 最高字节 ≥ 0x80 时也能通过', () {
      // 专门守住「用 `<< 24` 拼装大端会在 Web 上变成负数」这个坑。
      // 构造一段 Adler-32 高位字节带最高位的数据。
      final List<int> data = <int>[
        for (int i = 0; i < 600; i++) 0xFF,
      ];
      final int sum = naiveAdler32(data);
      expect(sum >= 0x80000000, isTrue, reason: '这组数据的校验和最高位应为 1');
      expect(unzlib(storedZlib(data)), data);
    });

    test('bytesConsumed 覆盖头 2 + 数据 + 尾 4', () {
      final Uint8List s = storedZlib(const <int>[1, 2, 3]);
      expect(inflateZlib(s).bytesConsumed, s.length);
    });
  });

  group('存储块 BTYPE=00', () {
    test('原样往返', () {
      final List<int> data = <int>[for (int i = 0; i < 300; i++) i & 0xFF];
      expect(unzlib(storedZlib(data)), data);
      expect(inflateZlib(bytes(storedZlib(data))).storedBlocks, 1);
    });

    test('空数据', () {
      // 长度为 0 的存储块是合法的。PNG 里 0 字节的图像数据不可能出现，
      // 但 inflate 本身该能处理。
      expect(unzlib(storedZlib(const <int>[])), <int>[]);
    });

    test('超过 65535 字节自动切成多块', () {
      // 存储块的 LEN 字段是 16 位，单块上限 65535。
      final List<int> data = <int>[
        for (int i = 0; i < 70000; i++) (i * 7) & 0xFF,
      ];
      final InflateResult r = inflateZlib(bytes(storedZlib(data)));
      expect(r.bytes.toList(), data);
      expect(r.storedBlocks, 2);
    });

    test('LEN 与 ~LEN 不互补被拒', () {
      // 这个冗余校验的作用是在「位流已经跑偏」时尽早发现 —— 跑偏后
      // 读到的 LEN 和 NLEN 几乎不可能恰好互补。
      final Uint8List s = storedZlib(const <int>[1, 2, 3]);
      s[5] ^= 0xFF; // 破坏 NLEN 的低字节
      expect(
        () => inflateZlib(s),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('NLEN'),
          ),
        ),
      );
    });

    test('数据被截断被拒', () {
      final List<int> raw = storedDeflate(const <int>[1, 2, 3, 4, 5]);
      // 砍掉两个数据字节，但保留 zlib 尾部，让它在读数据时就撞墙。
      final List<int> broken = <int>[
        0x78, 0x01,
        ...raw.sublist(0, raw.length - 2),
        0, 0, 0, 0,
      ];
      expect(() => inflateZlib(bytes(broken)),
          throwsA(isA<ImageDecodeException>()));
    });
  });
  group('固定 Huffman 块 BTYPE=01', () {
    test('纯字面量往返', () {
      final List<int> data = <int>[72, 101, 108, 108, 111];
      final List<int> stream = zlibWrap(fixedHuffmanLiterals(data), data);
      final InflateResult r = inflateZlib(bytes(stream));
      expect(r.bytes.toList(), data);
      expect(r.fixedBlocks, 1);
      expect(r.literalCount, 5);
      expect(r.matchCount, 0);
    });

    test('全部 256 个字节值都能正确往返', () {
      // 跨过 143/144 这个码长从 8 位变 9 位的分界 —— 固定表最容易
      // 写错的地方就在这里。
      final List<int> data = <int>[for (int i = 0; i < 256; i++) i];
      expect(
        inflateZlib(bytes(zlibWrap(fixedHuffmanLiterals(data), data)))
            .bytes
            .toList(),
        data,
      );
    });

    test('结束符之后的位被忽略', () {
      // 块以符号 256 结束，之后到字节边界的填充位不该被当作数据。
      final List<int> data = <int>[1];
      expect(unzlib(zlibWrap(fixedHuffmanLiterals(data), data)), <int>[1]);
    });
  });

  group('LZ77 反向引用', () {
    /// 用固定 Huffman 编码 [tokens]，包成 zlib，解出来应等于 [expected]。
    void expectTokens(List<Object> tokens, List<int> expected) {
      final List<int> stream = zlibWrap(fixedHuffmanBlock(tokens), expected);
      expect(inflateZlib(bytes(stream)).bytes.toList(), expected);
    }

    test('距离 1 是行程填充（源与目标重叠）', () {
      // 这是最关键的一个用例。距离 1、长度 5 的含义是「把上一个字节
      // 重复 5 次」—— 边写边读，源随着目标一起前进。
      //
      // 用 setRange 之类的批量拷贝实现 copyBack 会在这里出错：它会先
      // 把源区间整体读出来（此时源只有 1 个有效字节），得到的结果是
      // 「AB」而不是「AAAAA」。必须逐字节拷贝。
      // 字面量本身也算一个输出字节，所以总共是 1 + 5 = 6 个 0x41。
      expectTokens(
        <Object>[0x41, const Match(5, 1)],
        <int>[0x41, 0x41, 0x41, 0x41, 0x41, 0x41],
      );
    });

    test('距离 2 的交替填充', () {
      // 先输出 AB，再以距离 2、长度 6 复制 → 共 8 字节 ABABABAB。
      expectTokens(
        <Object>[0x41, 0x42, const Match(6, 2)],
        <int>[0x41, 0x42, 0x41, 0x42, 0x41, 0x42, 0x41, 0x42],
      );
    });

    test('长度大于距离时正确重叠', () {
      // 距离 3、长度 7：源区间会追上并越过自己的起点。
      expectTokens(
        <Object>[1, 2, 3, const Match(7, 3)],
        <int>[1, 2, 3, 1, 2, 3, 1, 2, 3, 1],
      );
    });

    test('不重叠的普通拷贝', () {
      expectTokens(
        <Object>[1, 2, 3, 4, 5, const Match(3, 5)],
        <int>[1, 2, 3, 4, 5, 1, 2, 3],
      );
    });

    test('最短匹配长度 3', () {
      expectTokens(
        <Object>[9, const Match(3, 1)],
        <int>[9, 9, 9, 9],
      );
    });

    test('最长匹配长度 258', () {
      // 符号 285 的特例：它没有额外位，直接表示 258。
      expectTokens(
        <Object>[7, const Match(258, 1)],
        <int>[for (int i = 0; i < 259; i++) 7],
      );
    });

    test('带额外位的长度与距离', () {
      // 长度 100 落在符号 277（基值 99，4 个额外位），
      // 距离 20 落在符号 8（基值 17，3 个额外位）。
      // 额外位低位先出、Huffman 码字高位先出，这个用例同时踩住两者。
      final List<int> seed = <int>[for (int i = 0; i < 20; i++) i];
      final List<int> expected = <int>[
        ...seed,
        for (int i = 0; i < 100; i++) seed[i % 20],
      ];
      expectTokens(<Object>[...seed, const Match(100, 20)], expected);
    });

    test('距离超出已输出长度被拒', () {
      // 只输出了 2 个字节却要往回引用 10 个 —— 越过了流的起点。
      // 这类数据会让实现读到未初始化的内存（C 里）或抛下标异常（Dart 里），
      // 必须显式拦住。
      final List<int> stream = <int>[
        0x78, 0x01,
        ...fixedHuffmanBlock(<Object>[1, 2, const Match(3, 10)]),
        0, 0, 0, 0,
      ];
      expect(
        () => inflateZlib(bytes(stream)),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('距离'),
          ),
        ),
      );
    });
  });
  group('动态 Huffman 块 BTYPE=10', () {
    /// 造一条动态块 zlib 流，码长由 [tokens] 用到的符号自动推出。
    ///
    /// 结束符 256 总要有码字；距离表哪怕用不上也得给一个退化码字，因为
    /// HDIST 字段最少报 1 个。
    List<int> dynZlib(List<Object> tokens, List<int> expected) {
      final List<List<int>> syms = symbolsFor(tokens);
      final List<int> lit = completeLengths(<int>{...syms[0], 256}.toList(), 288);
      final List<int> dist = completeLengths(
        syms[1].isEmpty ? const <int>[0] : syms[1],
        30,
      );
      return zlibWrap(dynamicHuffmanBlock(lit, dist, tokens), expected);
    }

    test('只有字面量的动态块', () {
      const List<int> expected = <int>[0x41, 0x42, 0x41, 0x41];
      final InflateResult r = inflateZlib(
        bytes(dynZlib(const <Object>[...expected], expected)),
      );
      expect(r.bytes.toList(), expected);
      expect(r.dynamicBlocks, 1);
      expect(r.fixedBlocks, 0);
      expect(r.storedBlocks, 0);
    });

    test('动态块里的反向引用', () {
      const List<int> expected = <int>[0x41, 0x41, 0x41, 0x41, 0x41];
      final List<int> stream = dynZlib(
        const <Object>[0x41, Match(4, 1)],
        expected,
      );
      expect(inflateZlib(bytes(stream)).bytes.toList(), expected);
    });

    test('码长不同、码字不同，解出来一样', () {
      // 同一个符号集，把码长换个分配方式，码字就完全变了。解码器只认
      // 码长 —— 这正是「规范化 Huffman 不用传码字」的底气。
      const List<int> expected = <int>[0x41, 0x42, 0x43];
      final List<int> a = completeLengths(<int>[0x41, 0x42, 0x43, 256], 288);
      final List<int> b = List<int>.filled(288, 0);
      b[0x41] = 3;
      b[0x42] = 3;
      b[0x43] = 2;
      b[256] = 1; // Σ2⁻ˡ = 1/8+1/8+1/4+1/2 = 1，仍是完整码表
      final List<int> dist = completeLengths(const <int>[0], 30);
      expect(canonicalCodes(a)[0x41], isNot(canonicalCodes(b)[0x41]));
      for (final List<int> lengths in <List<int>>[a, b]) {
        final List<int> stream = zlibWrap(
          dynamicHuffmanBlock(lengths, dist, const <Object>[0x41, 0x42, 0x43]),
          expected,
        );
        expect(inflateZlib(bytes(stream)).bytes.toList(), expected);
      }
    });

    /// 手写一个动态块，码长序列由 [emit] 自己决定怎么发。
    ///
    /// [dynamicHuffmanBlock] 刻意不做码长的行程压缩，所以符号 16/17/18
    /// 只能这样逐位手写。[emit] 拿到的是码长字母表的码字表。
    List<int> handBuilt({
      required List<int> clLengths,
      required int hlit,
      required int hdist,
      required void Function(BitWriterLsb w, Map<int, List<int>> cl) emit,
      void Function(BitWriterLsb w)? body,
    }) {
      final BitWriterLsb w = BitWriterLsb();
      w.writeBits(1, 1); // BFINAL
      w.writeBits(2, 2); // BTYPE=10
      w.writeBits(hlit - 257, 5);
      w.writeBits(hdist - 1, 5);
      int hclen = 19;
      while (hclen > 4 && clLengths[codeLengthOrder[hclen - 1]] == 0) {
        hclen--;
      }
      w.writeBits(hclen - 4, 4);
      for (int i = 0; i < hclen; i++) {
        w.writeBits(clLengths[codeLengthOrder[i]], 3);
      }
      emit(w, canonicalCodes(clLengths));
      body?.call(w);
      return w.toBytes();
    }

    test('码长表的重复指令 16 / 17 / 18', () {
      // 258 项码长，只有 5 项非零，靠三种重复指令跳过其余 253 项：
      //   18(×65) 3 16(×3) 18(×138) 18(×40) 17(×9) 1 1
      // 加起来正好 65+1+3+138+40+9+1+1 = 258。
      final List<int> clLengths =
          completeLengths(const <int>[1, 3, 16, 17, 18], 19);
      final List<int> litLengths = List<int>.filled(257, 0);
      for (int s = 0x41; s <= 0x44; s++) {
        litLengths[s] = 3;
      }
      litLengths[256] = 1; // 4×⅛ + 1×½ = 1，完整码表
      final List<int> distLengths = <int>[1];

      const List<int> expected = <int>[0x41, 0x42, 0x43, 0x44];
      final List<int> raw = handBuilt(
        clLengths: clLengths,
        hlit: 257,
        hdist: 1,
        emit: (BitWriterLsb w, Map<int, List<int>> cl) {
          void put(int sym) => w.writeCode(cl[sym]![0], cl[sym]![1]);
          put(18);
          w.writeBits(65 - 11, 7); // 前 65 项都是 0
          put(3); // 第 65 项：码长 3
          put(16);
          w.writeBits(3 - 3, 2); // 重复上一个码长 3 次 → 第 66..68 项
          put(18);
          w.writeBits(138 - 11, 7); // 一条指令最多跳 138 项
          put(18);
          w.writeBits(40 - 11, 7);
          put(17);
          w.writeBits(9 - 3, 3); // 17 管 3..10 项，收尾用它更省
          put(1); // 第 256 项：结束符的码长
          put(1); // 第 257 项：距离符号 0 的码长
        },
        body: (BitWriterLsb w) => writeTokens(
          w,
          const <Object>[...expected],
          canonicalCodes(litLengths),
          canonicalCodes(distLengths),
        ),
      );
      expect(inflateZlib(bytes(zlibWrap(raw, expected))).bytes.toList(),
          expected);
    });

    test('码长表以符号 16 开头被拒', () {
      // 16 的含义是「重复上一个码长」。开头没有上一个，只能是坏数据。
      final List<int> clLengths = List<int>.filled(19, 0);
      clLengths[0] = 1;
      clLengths[16] = 1;
      final List<int> raw = handBuilt(
        clLengths: clLengths,
        hlit: 257,
        hdist: 1,
        emit: (BitWriterLsb w, Map<int, List<int>> cl) =>
            w.writeCode(cl[16]![0], cl[16]![1]),
      );
      expect(
        () => inflateZlib(bytes(zlibWrap(raw, const <int>[]))),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('符号 16'),
          ),
        ),
      );
    });

    test('重复指令写超总项数被拒', () {
      // 声明 258 项，却用两条 18 想写 276 项。越界必须当场拦下，
      // 否则就是往定长数组外面写。
      final List<int> clLengths = List<int>.filled(19, 0);
      clLengths[0] = 1;
      clLengths[18] = 1;
      final List<int> raw = handBuilt(
        clLengths: clLengths,
        hlit: 257,
        hdist: 1,
        emit: (BitWriterLsb w, Map<int, List<int>> cl) {
          for (int i = 0; i < 2; i++) {
            w.writeCode(cl[18]![0], cl[18]![1]);
            w.writeBits(138 - 11, 7);
          }
        },
      );
      expect(
        () => inflateZlib(bytes(zlibWrap(raw, const <int>[]))),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('越界'),
          ),
        ),
      );
    });

    test('HLIT / HDIST 取满量程仍能工作', () {
      // 两个字段都是 5 位，HLIT 最大表示 288 个字面/长度码、HDIST 最大
      // 表示 32 个距离码 —— 正好覆盖两张字母表的全部符号，字段宽度与
      // 字母表大小是配套设计的。
      const List<int> expected = <int>[0x41];
      final List<int> lit = completeLengths(const <int>[0x41, 256], 288);
      final List<int> dist = completeLengths(const <int>[0], 32);
      final List<int> raw =
          dynamicHuffmanBlock(lit, dist, const <Object>[0x41]);
      expect(inflateZlib(bytes(zlibWrap(raw, expected))).bytes.toList(),
          expected);
    });
  });

  group('保留块类型与输出上限', () {
    test('BTYPE=11 被拒', () {
      // 三个块类型已经用掉 00/01/10，11 是规范明确保留的非法值。压缩器
      // 不会产出它 —— 读到它说明位流已经错位或损坏。
      // BFINAL=1 + BTYPE=11，低位先出，于是第一个字节是 0b111 = 0x07。
      expect(
        () => inflateZlib(bytes(zlibWrap(const <int>[0x07], const <int>[]))),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('保留'),
          ),
        ),
      );
    });

    test('输出正好等于上限时通过', () {
      // 边界应当是「小于等于」。PNG 传的就是精确的 rawSize，要是这里写成
      // 严格小于，每一张正常的 PNG 都会被自己的上限拦下。
      final List<int> raw = List<int>.generate(10, (int i) => i);
      final InflateResult r =
          inflateZlib(bytes(storedZlib(raw)), sizeLimit: 10);
      expect(r.bytes.length, 10);
    });

    test('输出超过上限被拒', () {
      final List<int> raw = List<int>.generate(10, (int i) => i);
      expect(
        () => inflateZlib(bytes(storedZlib(raw)), sizeLimit: 9),
        throwsA(isA<ImageDecodeException>()),
      );
    });

    test('解压炸弹在上限处停住，而不是先撑爆内存', () {
      // 一个字面量 + 40 条「距离 1、长度 258」的匹配 ≈ 74 字节输入，
      // 却能吐出 10321 字节，放大一百多倍。真正的炸弹用同样的手法能把
      // 几十 KB 变成几 GB —— 所以上限必须在**写之前**检查，边写边算。
      final List<Object> tokens = <Object>[
        0x41,
        ...List<Match>.filled(40, const Match(258, 1)),
      ];
      final List<int> compressed = fixedHuffmanBlock(tokens);
      expect(compressed.length, lessThan(100));

      // 不设上限时确实会膨胀到一万多字节。
      final List<int> full = List<int>.filled(1 + 40 * 258, 0x41);
      expect(inflateZlib(bytes(zlibWrap(compressed, full))).bytes.length, 10321);

      // 设了上限就停在上限，不会先分配一万多字节再回头检查。
      expect(
        () => inflateZlib(bytes(zlibWrap(compressed, full)), sizeLimit: 1024),
        throwsA(
          isA<ImageDecodeException>().having(
            (ImageDecodeException e) => e.message,
            'message',
            contains('解压炸弹'),
          ),
        ),
      );
    });
  });

  group('统计信息', () {
    test('字面量与匹配分别计数', () {
      // A B ←复制3×距离1→ C，即 "ABBBBC"：三个字面量、一条匹配。
      // 结束符 256 不算字面量 —— 它是控制符号，不产出字节。
      const List<Object> tokens = <Object>[0x41, 0x42, Match(3, 1), 0x43];
      const List<int> expected = <int>[0x41, 0x42, 0x42, 0x42, 0x42, 0x43];
      final InflateResult r = inflateZlib(
        bytes(zlibWrap(fixedHuffmanBlock(tokens), expected)),
      );
      expect(r.bytes.toList(), expected);
      expect(r.literalCount, 3);
      expect(r.matchCount, 1);
    });

    test('三种块类型各自的概括', () {
      final InflateResult stored = inflateZlib(bytes(storedZlib(const <int>[1])));
      expect(stored.blockSummary, 'stored×1');
      expect(stored.blockCount, 1);

      final InflateResult fixed = inflateZlib(
        bytes(zlibWrap(fixedHuffmanLiterals(const <int>[1]), const <int>[1])),
      );
      expect(fixed.blockSummary, '固定×1');

      final List<int> lit = completeLengths(const <int>[1, 256], 288);
      final InflateResult dynamic = inflateZlib(
        bytes(
          zlibWrap(
            dynamicHuffmanBlock(
              lit,
              completeLengths(const <int>[0], 30),
              const <Object>[1],
            ),
            const <int>[1],
          ),
        ),
      );
      expect(dynamic.blockSummary, '动态×1');
    });

    test('多块的类型混在一起也能数清', () {
      // 手写一个非终止的 stored 块，后面接一个固定 Huffman 块。
      // stored 块的 3 位头之后要跳到字节边界，所以它整体占满字节，
      // 后一个块正好从新字节开始 —— 这也是 stored 块必须字节对齐的原因。
      final List<int> raw = <int>[
        0x00, // BFINAL=0, BTYPE=00
        0x02, 0x00, // LEN = 2
        0xFD, 0xFF, // NLEN = LEN 的反码
        0x41, 0x42,
        ...fixedHuffmanLiterals(const <int>[0x43]),
      ];
      const List<int> expected = <int>[0x41, 0x42, 0x43];
      final InflateResult r = inflateZlib(bytes(zlibWrap(raw, expected)));
      expect(r.bytes.toList(), expected);
      expect(r.storedBlocks, 1);
      expect(r.fixedBlocks, 1);
      expect(r.blockCount, 2);
      expect(r.blockSummary, 'stored×1 + 固定×1');
      // stored 块的字节是整段照抄的，不经过 Huffman 解码，所以不计入
      // 字面量 —— 统计口径是「Huffman 符号」，不是「输出字节」。
      expect(r.literalCount, 1);
    });
  });
}
