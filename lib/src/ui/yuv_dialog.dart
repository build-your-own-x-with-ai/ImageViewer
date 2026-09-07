import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_color.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_format.dart';
import 'package:image_viewer/src/codecs/yuv/yuv_options.dart';
import 'package:image_viewer/src/core/rgba_image.dart' show kMaxImageDimension;

/// 裸 YUV 的参数对话框。
///
/// ## 为什么只有 YUV 需要这个
///
/// 别的格式都自带头部：BMP 有 `BITMAPFILEHEADER`，PNM 开头就是 `P6 64 48 255`。
/// 裸 YUV **什么都没有** —— 文件第一个字节就是第一个像素的亮度。同一份
/// 27648 字节的数据，既可以是 96×64 的三帧 I420，也可以是 96×96 的单帧
/// I444，两种解释都完全合法。
///
/// 所以参数只能由人告知。而人会填错 —— 填错的后果见 `docs/formats/yuv.md`：
/// 宽度差 1 会让每行累积错位，画出一张斜图，而且**解码器无从察觉**（字节数
/// 够就不报错）。
///
/// 因此这个对话框的重点不是「收集五个参数」，而是**在按下确定之前就把
/// 错误暴露出来**：下方实时显示这组参数能整除出几帧、余下多少字节。
/// 余数不为 0 基本就意味着填错了。
class YuvDialog extends StatefulWidget {
  const YuvDialog({
    required this.byteLength,
    required this.fileName,
    this.initial = YuvOptions.empty,
    super.key,
  });

  /// 文件总字节数。用来实时算帧数与余数。
  final int byteLength;

  final String fileName;

  /// 预填值。再次打开同一个文件时沿用上次填的，省得重新输一遍。
  final YuvOptions initial;

  /// 弹出对话框。返回 null 表示用户取消。
  static Future<YuvOptions?> show(
    BuildContext context, {
    required int byteLength,
    required String fileName,
    YuvOptions initial = YuvOptions.empty,
  }) {
    return showDialog<YuvOptions>(
      context: context,
      builder: (BuildContext context) => YuvDialog(
        byteLength: byteLength,
        fileName: fileName,
        initial: initial,
      ),
    );
  }

  @override
  State<YuvDialog> createState() => _YuvDialogState();
}

class _YuvDialogState extends State<YuvDialog> {
  late final TextEditingController _widthCtrl;
  late final TextEditingController _heightCtrl;

  late YuvFormat _format;
  late YuvMatrix _matrix;
  late YuvRange _range;

  /// 帧号。**本对话框不提供它的编辑控件**，只是原样带进带出。
  ///
  /// 翻帧是「解完之后想看下一帧」，属于观察行为，放在主界面工具栏上一点即换。
  /// 塞进这个模态框就变成「每看一帧都要重开对话框、重填五个参数」，
  /// 荒谬得很。所以这里只负责在重开对话框时保住上次的帧号不丢。
  late int _frameIndex;

  @override
  void initState() {
    super.initState();
    // 宽高为 0 表示「还没填」，此时输入框留空而不是显示 0。
    _widthCtrl = TextEditingController(
      text: widget.initial.width > 0 ? '${widget.initial.width}' : '',
    );
    _heightCtrl = TextEditingController(
      text: widget.initial.height > 0 ? '${widget.initial.height}' : '',
    );
    _format = widget.initial.format;
    _matrix = widget.initial.matrix;
    _range = widget.initial.range;
    _frameIndex = widget.initial.frameIndex;
  }

  @override
  void dispose() {
    _widthCtrl.dispose();
    _heightCtrl.dispose();
    super.dispose();
  }

  int get _width => int.tryParse(_widthCtrl.text) ?? 0;
  int get _height => int.tryParse(_heightCtrl.text) ?? 0;

  /// 当前这组参数。
  YuvOptions get _options => YuvOptions(
        width: _width,
        height: _height,
        format: _format,
        matrix: _matrix,
        range: _range,
        frameIndex: _frameIndex,
      );

  /// 参数合法且至少能凑出一帧，才允许确定。
  bool get _canConfirm =>
      _options.isComplete && _options.frameCountIn(widget.byteLength) > 0;

  /// 反推高度：已知宽度与格式时，让**一帧刚好占满整个文件**的高度。
  ///
  /// 这是填参数时最实用的辅助 —— 宽度通常是知道的（1920、640 之类的常见值），
  /// 高度反而容易记错。点一下就填上。
  ///
  /// ## 为什么按「单帧占满」来推，而不是别的解释
  ///
  /// 一份数据的高度**本质上是多解的**。27648 字节、宽 96 的 I420，既可以是
  /// 单帧 96×192，也可以是三帧 96×64，还可以是六帧 96×32 —— 全都能整除，
  /// 全都合法。这正是裸 YUV 的根本问题，不是这个函数能解决的。
  ///
  /// 所以取「单帧占满」这一解：它跟解码器报错时给的提示（`_describeMismatch`
  /// 里那个反推）是同一个语义，两处口径一致，不会一个说 192 一个说 64。
  /// 如果这其实是段视频，用户看到下方帧数显示「1 帧」就知道该往下调了。
  void _guessHeight() {
    final int w = _width;
    if (w <= 0) {
      return;
    }

    // frameSize 随高度单调递增，所以一路往上扫、超过文件大小就停。
    // 记住最后一个装得下的高度 —— 精确相等时它就是精确解。
    int best = 0;
    for (int h = 1; h <= kMaxImageDimension; h++) {
      final int size = _format.frameSize(w, h);
      if (size <= 0 || size > widget.byteLength) {
        break;
      }
      best = h;
    }

    if (best > 0) {
      setState(() => _heightCtrl.text = '$best');
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('裸 YUV 参数'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                '${widget.fileName} · '
                '${_formatBytes(widget.byteLength)}',
                style: Theme.of(context).textTheme.bodySmall,
              ),
              const SizedBox(height: 4),
              Text(
                'YUV 文件没有头部，这些参数无法从数据里读出，只能由你告知。',
                style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
              ),
              const SizedBox(height: 16),
              _buildSizeRow(),
              const SizedBox(height: 12),
              _buildFormatDropdown(),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Expanded(child: _buildMatrixDropdown()),
                  const SizedBox(width: 12),
                  Expanded(child: _buildRangeDropdown()),
                ],
              ),
              const SizedBox(height: 16),
              _buildFeedback(context),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed:
              _canConfirm ? () => Navigator.of(context).pop(_options) : null,
          child: const Text('解码'),
        ),
      ],
    );
  }

  Widget _buildSizeRow() {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: <Widget>[
        Expanded(child: _numberField(_widthCtrl, '宽度')),
        const SizedBox(width: 12),
        Expanded(child: _numberField(_heightCtrl, '高度')),
        const SizedBox(width: 8),
        // 反推高度。宽度没填时禁用 —— 没有宽度推不出高度。
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: IconButton(
            icon: const Icon(Icons.calculate_outlined),
            tooltip: '按宽度与格式反推高度（单帧占满整个文件）',
            onPressed: _width > 0 ? _guessHeight : null,
          ),
        ),
      ],
    );
  }

  Widget _numberField(TextEditingController ctrl, String label) {
    return TextField(
      controller: ctrl,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
        isDense: true,
      ),
      keyboardType: TextInputType.number,
      // 只允许数字。宽高是尺寸，负号和小数点都没有意义。
      inputFormatters: <TextInputFormatter>[
        FilteringTextInputFormatter.digitsOnly,
      ],
      // 每敲一个字符都要刷新下方的帧数反馈 —— 这个即时性是整个对话框的重点。
      onChanged: (String _) => setState(() {}),
    );
  }

  Widget _buildFormatDropdown() {
    return DropdownButtonFormField<YuvFormat>(
      initialValue: _format,
      decoration: const InputDecoration(
        labelText: '像素格式',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: <DropdownMenuItem<YuvFormat>>[
        for (final YuvFormat f in YuvFormat.values)
          DropdownMenuItem<YuvFormat>(
            value: f,
            // 一行里给足三样东西：名字、抽样比、别名。裸 YUV 的格式名混乱
            // 得出名（NV12 和 NV21 只差交织顺序，YU12 就是 I420），
            // 把别名摆出来能省掉一次查文档。
            child: Text(
              '${f.label} · ${f.samplingLabel}'
              '${f.aka.isEmpty ? "" : " · ${f.aka}"}',
            ),
          ),
      ],
      onChanged: (YuvFormat? v) {
        if (v != null) {
          setState(() => _format = v);
        }
      },
    );
  }

  Widget _buildMatrixDropdown() {
    return DropdownButtonFormField<YuvMatrix>(
      initialValue: _matrix,
      decoration: const InputDecoration(
        labelText: '色彩矩阵',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: <DropdownMenuItem<YuvMatrix>>[
        for (final YuvMatrix m in YuvMatrix.values)
          DropdownMenuItem<YuvMatrix>(value: m, child: Text(m.description)),
      ],
      onChanged: (YuvMatrix? v) {
        if (v != null) {
          setState(() => _matrix = v);
        }
      },
    );
  }

  Widget _buildRangeDropdown() {
    return DropdownButtonFormField<YuvRange>(
      initialValue: _range,
      decoration: const InputDecoration(
        labelText: '取值范围',
        border: OutlineInputBorder(),
        isDense: true,
      ),
      items: <DropdownMenuItem<YuvRange>>[
        for (final YuvRange r in YuvRange.values)
          DropdownMenuItem<YuvRange>(value: r, child: Text(r.description)),
      ],
      onChanged: (YuvRange? v) {
        if (v != null) {
          setState(() => _range = v);
        }
      },
    );
  }

  /// 实时算账：这组参数把文件切成几帧、余多少字节。
  ///
  /// 这是本对话框存在的真正理由。参数填错时**解码器帮不上忙** —— 字节数够
  /// 它就照解，画出一张斜图还不报错。唯一能提前发现的信号就是余数：
  ///
  ///   - 余 0 字节 → 参数大概率对（尺寸能整除文件）
  ///   - 余数不为 0 → 几乎必定填错了，因为裸 YUV 是逐帧首尾相接写的，
  ///     不会多出零头
  ///
  /// 所以余数非 0 时给橙色警告，但**不禁用「解码」按钮** —— 万一文件真被
  /// 截断过，用户仍然有权解出前几帧看看。判断权在人，我们只负责把事实摆出来。
  Widget _buildFeedback(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    if (!_options.isComplete) {
      return _feedbackBox(
        theme,
        icon: Icons.edit_outlined,
        color: theme.colorScheme.onSurfaceVariant,
        text: '填入宽高后这里会显示能解出几帧。',
      );
    }

    final int frameSize = _options.frameSize;
    final int frames = _options.frameCountIn(widget.byteLength);
    final int remainder =
        frameSize > 0 ? widget.byteLength % frameSize : widget.byteLength;

    if (frames == 0) {
      // 一帧都凑不齐 —— 尺寸填得太大了。差多少字节直接说出来。
      return _feedbackBox(
        theme,
        icon: Icons.error_outline,
        color: theme.colorScheme.error,
        text: '每帧需要 ${_formatBytes(frameSize)}，'
            '文件只有 ${_formatBytes(widget.byteLength)} —— '
            '还差 ${_formatBytes(frameSize - widget.byteLength)}。'
            '尺寸填大了。',
      );
    }

    final String base = '每帧 ${_formatBytes(frameSize)} × $frames 帧';

    if (remainder == 0) {
      return _feedbackBox(
        theme,
        icon: Icons.check_circle_outline,
        color: Colors.green.shade700,
        text: '$base，正好用完整个文件。参数大概率是对的。',
      );
    }

    return _feedbackBox(
      theme,
      icon: Icons.warning_amber_outlined,
      color: Colors.orange.shade800,
      text: '$base，余 ${_formatBytes(remainder)} 用不掉。\n'
          '裸 YUV 是逐帧首尾相接的，不该有零头 —— 宽高或格式可能填错了。'
          '仍可解码，但画面可能是斜的。',
    );
  }

  Widget _feedbackBox(
    ThemeData theme, {
    required IconData icon,
    required Color color,
    required String text,
  }) {
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.08),
        border: Border.all(color: color.withValues(alpha: 0.4)),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: theme.textTheme.bodySmall?.copyWith(color: color),
            ),
          ),
        ],
      ),
    );
  }

  /// 字节数加千位分隔。帧大小动辄六七位，不分隔读不出数量级。
  static String _formatBytes(int n) {
    final String s = '$n';
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) {
        sb.write(',');
      }
      sb.write(s[i]);
    }
    return '$sb 字节';
  }
}
