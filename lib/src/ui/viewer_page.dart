import 'dart:typed_data';

import 'package:file_selector/file_selector.dart';
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image_viewer/src/codecs/yuv/yuv_options.dart';
import 'package:image_viewer/src/platform/file_source.dart';
import 'package:image_viewer/src/platform/image_file.dart';
import 'package:image_viewer/src/services/decode_service.dart';
import 'package:image_viewer/src/ui/browser_sidebar.dart';
import 'package:image_viewer/src/ui/error_view.dart';
import 'package:image_viewer/src/ui/image_bridge.dart';
import 'package:image_viewer/src/ui/image_canvas.dart';
import 'package:image_viewer/src/ui/info_panel.dart';
import 'package:image_viewer/src/ui/yuv_dialog.dart';

/// 主页面：把「取字节 → 解码 → 上屏」这条链路串起来。
///
/// ## 状态机
///
/// 四个状态，由 `_file` / `_image` / `_error` / `_busy` 的组合表示：
///
/// ```
/// 空闲（什么都没开） ──开文件──> 忙 ──成功──> 已显示
///                              └──失败──> 出错 ──重试/换参数──> 忙
/// ```
///
/// 不用 enum 是因为这四个字段本来就要各自留着：出错时仍然要显示是哪个文件
/// 出的错，重新解码时仍然要用同一份字节（不该再读一次盘）。再加一个 enum
/// 只会多一处需要同步的真相。
class ViewerPage extends StatefulWidget {
  const ViewerPage({super.key});

  @override
  State<ViewerPage> createState() => _ViewerPageState();
}

class _ViewerPageState extends State<ViewerPage> {
  static const FileSource _fs = FileSource();

  ImageFile? _file;
  DisplayImage? _image;
  Object? _error;
  bool _busy = false;

  /// 本文件上次用的 YUV 参数。非 null 表示「这张图是按裸流解出来的」。
  ///
  /// 留着它有两个用处：翻帧时只改 `frameIndex`，以及再次打开参数对话框时
  /// 预填上次填的五个值 —— 调参数是个反复试的过程，每次从空白开始很折磨。
  YuvOptions? _yuv;

  /// 递增的请求号，用来丢弃过期结果。
  ///
  /// 解码是异步的（还跳了 isolate），用户完全可能在大图解完之前又点了一张
  /// 小图。小图先解完上屏，紧接着大图解完，**把新的覆盖成旧的** —— 界面显示
  /// 的图和侧栏高亮的行对不上。所以每次请求领一个号，回来时号不对就丢掉。
  int _token = 0;

  /// 侧栏里高亮哪一行：asset key 或文件绝对路径。
  String? _selected;

  bool _showInfo = true;

  /// 出错文件的名字。
  ///
  /// 单独存是因为读盘失败时**根本没有 `ImageFile`**（构造它需要字节，而字节
  /// 正是没读到的东西）。可错误提示里最该有的就是「哪个文件出的错」。
  String? _errorName;

  /// 读盘失败的那个路径，供「重试」再读一次。
  ///
  /// macOS 沙盒下这条路径很实用：第一次被拒 → 用「选择文件夹」重新授权 →
  /// 重试就成了。没有它的话，用户只能回侧栏重新找一遍那个文件。
  String? _errorPath;

  @override
  void dispose() {
    // GPU 纹理不受 GC 管，得手动还。
    _image?.dispose();
    super.dispose();
  }

  /// 系统文件选择器。六个平台通用，也是 Web 上唯一的来源。
  Future<void> _openViaPicker() async {
    final XFile? picked = await openFile(acceptedTypeGroups: _typeGroups);
    if (picked == null) {
      return;
    }
    final Uint8List bytes = await picked.readAsBytes();
    await _load(ImageFile(
      name: picked.name,
      bytes: bytes,
      // Web 上 `XFile.path` 是个 blob URL，不是真实路径，显示出来只会误导。
      path: kIsWeb ? null : picked.path,
    ), selected: kIsWeb ? null : picked.path);
  }

  /// 打开内置样图。
  Future<void> _openAsset(String key) async {
    setState(() {
      _busy = true;
      _error = null;
      _selected = key;
    });
    final ByteData data = await rootBundle.load(key);
    await _load(
      ImageFile(
        name: key.substring(key.lastIndexOf('/') + 1),
        // 必须带 offsetInBytes/lengthInBytes：`ByteData` 是整个 asset 缓冲区
        // 上的一个视图，直接拿 `buffer.asUint8List()` 会连上别的资源的字节。
        bytes: data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        source: ImageFileSource.asset,
      ),
      selected: key,
    );
  }

  /// 打开侧栏点中的文件。
  ///
  /// 读盘单独 try 住，跟解码失败分开报 —— 两者的下一步动作完全不同：
  /// 读不到是权限/路径问题，解不开才是格式问题。
  Future<void> _openPath(String path) async {
    setState(() {
      _busy = true;
      _error = null;
      _selected = path;
    });
    final String name = _fs.basenameOf(path);
    final Uint8List bytes;
    try {
      bytes = await _fs.readFile(path);
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          _busy = false;
          _error = e;
          _errorName = name;
          _errorPath = path;
        });
      }
      return;
    }
    await _load(
      ImageFile(
        name: name,
        bytes: bytes,
        path: path,
        source: ImageFileSource.directory,
      ),
      selected: path,
    );
  }

  /// 换一个文件：记下它，然后按魔数嗅探解码。
  Future<void> _load(ImageFile file, {String? selected}) async {
    setState(() {
      _file = file;
      _selected = selected;
      _errorName = file.name;
      _errorPath = file.path;
      // 清掉上一个文件的 YUV 参数：尺寸几乎必然不同，留着会让翻帧按钮
      // 拿旧的宽高去切新文件，切出来是一堆噪点。
      _yuv = null;
    });
    await _decode(() => decodeImage(file.bytes));
  }

  /// 跑一次解码，把结果或异常落到状态上。
  ///
  /// 收一个「返回 [DecodeResult] 的函数」而不是收字节：嗅探解码走
  /// `decodeImage`，显式 YUV 走 `decodeYuv`，两个入口不同；但之后的事
  /// —— 计忙、丢弃过期结果、回收旧纹理、转 GPU 纹理 —— 一模一样。
  Future<void> _decode(Future<DecodeResult> Function() run) async {
    final int token = ++_token;
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final DecodeResult result = await run();
      // 带上耗时再交给 UI：解码器本身不计时，计时是调用方的事。
      final DisplayImage display = await DisplayImage.from(
        result.imageWithTiming,
      );

      // 过期了：期间用户又点了别的图。这张已经解好的直接扔掉 ——
      // 注意纹理要 dispose，否则每次抢跑都漏一张图的显存。
      if (token != _token || !mounted) {
        display.dispose();
        return;
      }
      setState(() {
        _image?.dispose();
        _image = display;
        _busy = false;
      });
    } on Object catch (e) {
      if (token != _token || !mounted) {
        return;
      }
      setState(() {
        // 旧图一并清掉：留着上一张图 + 一条错误提示，看起来像是这张图解出来了。
        _image?.dispose();
        _image = null;
        _error = e;
        _busy = false;
      });
    }
  }

  /// 弹参数对话框，然后按裸 YUV 解码。
  ///
  /// 预填上次填的值（[_yuv]）—— 调 YUV 参数是个反复试的过程：先猜 1920×1080，
  /// 发现余数不为 0，改成 1280×720 再试。每次都从空白开始重填五个字段，
  /// 光是重新选一遍格式和矩阵就够烦了。
  Future<void> _promptYuv() async {
    final ImageFile? file = _file;
    if (file == null) {
      return;
    }
    final YuvOptions? options = await YuvDialog.show(
      context,
      byteLength: file.bytes.length,
      fileName: file.name,
      initial: _yuv ?? YuvOptions.empty,
    );
    if (options == null || !mounted) {
      return;
    }
    setState(() => _yuv = options);
    await _decode(() => decodeYuv(file.bytes, options));
  }

  /// 翻到第 [index] 帧。
  ///
  /// 只改 `frameIndex`，其余四个参数原样留着 —— 同一个文件里所有帧的宽高格式
  /// 必然相同，让用户翻一帧就重填一遍参数是荒谬的。这也是为什么参数对话框里
  /// 没有帧号输入框：翻帧属于「解完之后想看下一帧」的观察行为，该在工具栏上。
  Future<void> _gotoFrame(int index) async {
    final ImageFile? file = _file;
    final YuvOptions? current = _yuv;
    if (file == null || current == null) {
      return;
    }
    final YuvOptions next = current.copyWith(frameIndex: index);
    setState(() => _yuv = next);
    await _decode(() => decodeYuv(file.bytes, next));
  }

  /// 重来一次。
  ///
  /// 优先用内存里已有的字节重解，不再读一次盘 —— 除了读盘本身失败的情况，
  /// 那时候 [_file] 是 null，只能按路径重读。
  Future<void> _retry() async {
    final ImageFile? file = _file;
    if (file != null) {
      final YuvOptions? yuv = _yuv;
      await _decode(() =>
          yuv == null ? decodeImage(file.bytes) : decodeYuv(file.bytes, yuv));
      return;
    }
    final String? path = _errorPath;
    if (path != null) {
      await _openPath(path);
    }
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double width = constraints.maxWidth;
        final bool inlineSidebar = width >= _sidebarBreakpoint;
        final bool roomForInfo = width >= _infoBreakpoint;

        final ImageFile? file = _file;
        final DisplayImage? image = _image;

        return Scaffold(
          appBar: _appBar(canToggleInfo: roomForInfo && image != null),
          // 窗口窄的时候侧栏收进抽屉。
          //
          // 代价：抽屉一关，BrowserSidebar 的 State 就没了，用户选的目录也跟着
          // 丢。要保住得把目录状态提到本页 —— 但窄窗口下目录浏览本来就是次要
          // 来源（真正窄的平台是手机，那儿连 canBrowse 都常常为假），
          // 先按这个代价走。
          drawer: inlineSidebar
              ? null
              : Drawer(child: SafeArea(child: _sidebar())),
          body: Row(
            children: <Widget>[
              if (inlineSidebar) ...<Widget>[
                SizedBox(width: _sidebarWidth, child: _sidebar()),
                const VerticalDivider(width: 1),
              ],
              Expanded(child: _body()),
              if (roomForInfo && _showInfo && file != null && image != null)
                ...<Widget>[
                  const VerticalDivider(width: 1),
                  InfoPanel(file: file, image: image),
                ],
            ],
          ),
        );
      },
    );
  }

  Widget _sidebar() => BrowserSidebar(
        onOpenAsset: _openAsset,
        onOpenPath: _openPath,
        selected: _selected,
      );

  /// 中间那块：出错 / 空 / 加载中 / 显示图像。
  Widget _body() {
    final Object? error = _error;
    if (error != null) {
      return ErrorView(
        error: error,
        fileName: _errorName,
        // 只有字节已经在内存里时才给「按裸 YUV 解码」—— 读盘就失败的情况下
        // 弹参数对话框毫无意义，没有字节可解。
        onTryYuv: _file == null ? null : _promptYuv,
        onRetry: _file == null && _errorPath == null ? null : _retry,
      );
    }

    final DisplayImage? image = _image;
    if (image == null) {
      return _busy ? const Center(child: CircularProgressIndicator()) : _empty();
    }

    return Stack(
      children: <Widget>[
        // ClipRect 在这里：ImageCanvas 内部的 InteractiveViewer 用了
        // `clipBehavior: Clip.none` + 无限 boundaryMargin，裁剪必须由外层做。
        Positioned.fill(child: ClipRect(child: ImageCanvas(image: image))),
        // 重新解码（翻帧、改参数）时压一层薄雾：旧图还在，但要让人知道
        // 屏幕上这张已经不是最新参数的结果了。
        if (_busy)
          const Positioned.fill(
            child: ColoredBox(
              color: Color(0x40000000),
              child: Center(child: CircularProgressIndicator()),
            ),
          ),
      ],
    );
  }

  /// 什么都还没打开时的样子。
  ///
  /// 明确指一下左边的样图列表：这是空手启动时最快能看到解码结果的路径，
  /// 而新用户不一定会想到侧栏里那些文件是能点的。
  Widget _empty() {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              Icons.photo_size_select_actual_outlined,
              size: 44,
              color: theme.colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 18),
            Text('打开一张图看看', style: theme.textTheme.titleMedium),
            const SizedBox(height: 8),
            Text(
              'BMP / PNM / 裸 YUV，全部由本项目手写解码，不依赖任何图像库。\n'
              '左边的「内置样图」点开即用。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 22),
            FilledButton.icon(
              icon: const Icon(Icons.folder_open, size: 18),
              label: const Text('打开文件…'),
              onPressed: _openViaPicker,
            ),
          ],
        ),
      ),
    );
  }

  PreferredSizeWidget _appBar({required bool canToggleInfo}) {
    final ImageFile? file = _file;
    final DisplayImage? image = _image;

    return AppBar(
      title: file == null
          ? const Text('ImageViewer')
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Text(file.name, overflow: TextOverflow.ellipsis),
                if (image != null)
                  Text(
                    '${image.width} × ${image.height}',
                    style: Theme.of(context).textTheme.labelSmall,
                  ),
              ],
            ),
      titleSpacing: 12,
      actions: <Widget>[
        ..._frameNav(),
        // 已经按 YUV 解出来了也留着这个按钮：改参数比重开文件快，
        // 而调 YUV 参数本来就是反复试的过程。
        if (file != null)
          IconButton(
            icon: const Icon(Icons.tune),
            tooltip: _yuv == null ? '按裸 YUV 解码…' : '修改 YUV 参数…',
            isSelected: _yuv != null,
            onPressed: _promptYuv,
          ),
        IconButton(
          icon: const Icon(Icons.folder_open),
          tooltip: '打开文件…',
          onPressed: _openViaPicker,
        ),
        if (canToggleInfo)
          IconButton(
            icon: const Icon(Icons.info_outline),
            tooltip: _showInfo ? '隐藏信息面板' : '显示信息面板',
            isSelected: _showInfo,
            onPressed: () => setState(() => _showInfo = !_showInfo),
          ),
        const SizedBox(width: 4),
      ],
    );
  }

  /// 翻帧控件。只在「按 YUV 解码过」且文件里确实有多帧时出现。
  ///
  /// 单帧文件摆一对灰着的箭头是纯噪音 —— 而绝大多数 BMP/PNM 都是单帧，
  /// 所以这一整块默认不存在。
  List<Widget> _frameNav() {
    final YuvOptions? yuv = _yuv;
    final ImageFile? file = _file;
    if (yuv == null || file == null) {
      return const <Widget>[];
    }
    final int total = yuv.frameCountIn(file.bytes.length);
    if (total <= 1) {
      return const <Widget>[];
    }
    final int current = yuv.frameIndex;
    return <Widget>[
      IconButton(
        icon: const Icon(Icons.chevron_left),
        tooltip: '上一帧',
        onPressed: current > 0 ? () => _gotoFrame(current - 1) : null,
      ),
      Text('第 ${current + 1} / $total 帧',
          style: Theme.of(context).textTheme.labelMedium),
      IconButton(
        icon: const Icon(Icons.chevron_right),
        tooltip: '下一帧',
        onPressed: current < total - 1 ? () => _gotoFrame(current + 1) : null,
      ),
    ];
  }
}

/// 侧栏内联显示所需的最小窗口宽度。低于此值收进抽屉。
const double _sidebarBreakpoint = 900;

/// 信息面板所需的最小窗口宽度。
///
/// 比侧栏的阈值低：信息面板是「看这张图的元数据」，比换文件更贴近当前任务，
/// 窗口变窄时该后让位。
const double _infoBreakpoint = 700;

const double _sidebarWidth = 280;

/// 文件选择器的过滤条件。
///
/// **只列已经实现了解码器的格式。** 把 png/jpeg 也塞进来会让用户选中一个
/// PNG，然后得到「没有解码器认领」+「试试按裸 YUV 解码」的建议 —— 而那是
/// 一张完全正常的 PNG，建议是错的。等 PNG 解码器写完再往这儿加。
///
/// 侧栏的 `kBrowsableExtensions` 比这份宽，那是刻意的：列目录时宁可多显示
/// 一个让用户点开看看。而选择器是**主动限制用户能选什么**，宽了就是误导。
const List<XTypeGroup> _typeGroups = <XTypeGroup>[
  XTypeGroup(
    label: '支持的图像',
    extensions: <String>[
      'bmp', 'dib', // BMP
      'pnm', 'pbm', 'pgm', 'ppm', // PNM
      'yuv', 'raw', 'i420', 'yv12', 'nv12', 'nv21', 'yuy2', 'uyvy', // 裸 YUV
    ],
  ),
  // 裸流的扩展名千奇百怪（.bin/.data/没有扩展名都常见），
  // 所以留一个「所有文件」的口子。
  XTypeGroup(label: '所有文件'),
];
