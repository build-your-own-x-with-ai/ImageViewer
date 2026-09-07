import 'package:flutter/material.dart';
import 'package:image_viewer/src/core/errors.dart';

/// 打不开一个文件时显示的东西。
///
/// ## 为什么值得单独一个文件
///
/// 「打不开」有好几种，**每一种的下一步动作都不一样**：
///
/// | 情况 | 用户该做什么 |
/// |---|---|
/// | 没人认领这段字节 | 可能是裸 YUV，手动给参数试试 |
/// | 认领了但字节坏了 | 拿 hex 编辑器跳到出错偏移看 |
/// | 格式合法但特性没实现 | 什么也做不了，换张图 |
/// | 连文件都没读到 | 是权限/路径问题，跟解码无关 |
///
/// 把它们糊成一句「加载失败」，等于把解码器辛苦区分出来的信息全扔了。
/// `decode_service.dart` 里的 `hasDecoderFor` 和 `errors.dart` 里的三个
/// 异常类型，存在的意义就是让这里能分开说。
class ErrorView extends StatelessWidget {
  const ErrorView({
    required this.error,
    this.fileName,
    this.onTryYuv,
    this.onRetry,
    super.key,
  });

  /// 抓到的异常。故意收 [Object] 而不是 [ImageDecodeException] ——
  /// 读文件阶段的 `PathAccessException`、isolate 里的意外错误也要能显示，
  /// 而不是在错误处理的路上再抛一次类型错误。
  final Object error;

  /// 出错的文件名，有就显示。
  final String? fileName;

  /// 打开 YUV 参数对话框。为 null 时不显示该按钮。
  final VoidCallback? onTryYuv;

  /// 重试。
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final _Presentation p = _classify();

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 460),
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Icon(p.icon, size: 40, color: theme.colorScheme.error),
              const SizedBox(height: 16),
              Text(p.title, style: theme.textTheme.titleMedium),
              if (fileName != null) ...<Widget>[
                const SizedBox(height: 4),
                Text(
                  fileName!,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
              const SizedBox(height: 14),
              Text(
                p.body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodyMedium?.copyWith(height: 1.5),
              ),
              if (p.detail != null) ...<Widget>[
                const SizedBox(height: 16),
                _detailBox(theme, p.detail!),
              ],
              const SizedBox(height: 22),
              _actions(p),
            ],
          ),
        ),
      ),
    );
  }

  /// 把异常分门别类。
  ///
  /// **`is` 的顺序在这里是有意义的**：[UnknownImageFormat] 和
  /// [UnsupportedImageFeature] 都继承 [ImageDecodeException]，先判父类
  /// 就永远走不到两个子类分支 —— 而且分析器不会报错，只是所有错误都退化成
  /// 最笼统的那条文案。窄的在前。
  _Presentation _classify() {
    final Object e = error;

    if (e is UnknownImageFormat) {
      return _Presentation(
        icon: Icons.help_outline,
        title: '没有解码器认领这个文件',
        body: '六个解码器都靠魔数嗅探，没有一个认出开头的字节。\n\n'
            '如果这是**裸 YUV 流**，那是正常的 —— 裸流没有文件头，'
            '按定义就嗅探不出来，只能你告诉它宽、高和格式。',
        detail: e.message,
        suggestYuv: true,
      );
    }

    if (e is UnsupportedImageFeature) {
      return _Presentation(
        icon: Icons.construction_outlined,
        title: '文件没问题，是这里还没实现',
        body: '格式解析下来是合法的，但用到了本项目尚未支持的特性。'
            '换一张图，或者去 docs/formats/ 看看这个分支的实现计划。',
        detail: _decodeDetail(e),
      );
    }

    if (e is ImageDecodeException) {
      return _Presentation(
        icon: Icons.broken_image_outlined,
        title: '解码失败',
        // 有解码器认领了它，所以格式是对的 —— 问题出在字节内容上。
        body: '有解码器认出了格式并开始解析，但中途发现数据不对。'
            '文件很可能被截断或损坏了。',
        detail: _decodeDetail(e),
      );
    }

    // 走到这里通常连解码都没开始：路径没权限、文件被删了、读一半断了。
    return _Presentation(
      icon: Icons.error_outline,
      title: '读取文件失败',
      body: '还没走到解码这一步。检查文件是否还在、是否有读取权限。',
      detail: e.toString(),
    );
  }

  /// 解码异常的技术细节：格式 + 偏移 + 原文。
  ///
  /// 偏移必须显示。「第 138 字节处位深是 7」能让人直接拿 hex 编辑器跳过去
  /// 核对；「解码失败」只能让人重新猜一遍。
  String _decodeDetail(ImageDecodeException e) {
    final StringBuffer sb = StringBuffer();
    if (e.format != null && e.format!.isNotEmpty) {
      sb.write('[${e.format}] ');
    }
    sb.write(e.message);
    final int? offset = e.offset;
    if (offset != null) {
      sb.write('\n偏移 $offset（0x${offset.toRadixString(16).toUpperCase()}）');
    }
    return sb.toString();
  }

  /// 技术细节框。等宽字体 —— 里面有偏移量和数值，对齐了才好读。
  Widget _detailBox(ThemeData theme, String detail) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(6),
      ),
      child: SelectableText(
        detail,
        style: theme.textTheme.bodySmall?.copyWith(
          fontFamily: 'monospace',
          fontFamilyFallback: const <String>['Menlo', 'Consolas'],
          height: 1.45,
        ),
      ),
    );
  }

  Widget _actions(_Presentation p) {
    final List<Widget> buttons = <Widget>[
      // 只在「没人认领」时推荐 YUV。文件损坏时弹这个按钮属于误导 ——
      // 那是一张坏了的 BMP，不是裸流。
      if (p.suggestYuv && onTryYuv != null)
        FilledButton.icon(
          icon: const Icon(Icons.tune, size: 16),
          label: const Text('按裸 YUV 解码…'),
          onPressed: onTryYuv,
        ),
      if (onRetry != null)
        OutlinedButton.icon(
          icon: const Icon(Icons.refresh, size: 16),
          label: const Text('重试'),
          onPressed: onRetry,
        ),
    ];
    if (buttons.isEmpty) {
      return const SizedBox.shrink();
    }
    return Wrap(spacing: 10, runSpacing: 8, children: buttons);
  }
}

/// 一种错误该怎么显示。
///
/// 用一个小类而不是 record：字段带文档，且 `suggestYuv` 这种带判断的字段
/// 需要解释为什么不是永远为真。
class _Presentation {
  const _Presentation({
    required this.icon,
    required this.title,
    required this.body,
    this.detail,
    this.suggestYuv = false,
  });

  final IconData icon;

  /// 一句话说清是哪一类问题。
  final String title;

  /// 给人看的解释：发生了什么、下一步做什么。
  final String body;

  /// 给机器/开发者看的原文：格式、偏移、异常 message。
  final String? detail;

  /// 是否推荐「按裸 YUV 解码」。只有嗅探未命中时为真。
  final bool suggestYuv;
}
