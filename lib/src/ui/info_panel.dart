import 'package:flutter/material.dart';
import 'package:image_viewer/src/platform/image_file.dart';
import 'package:image_viewer/src/ui/image_bridge.dart';

/// 右侧的格式信息面板。
///
/// ## 为什么它是这个项目的主要产出之一
///
/// 「能把图显示出来」只证明解码器没崩。真正有教学价值的是**这张图是怎么
/// 存的**：几位色深、哪个头部版本、有没有压缩、色度怎么抽样。这些信息在
/// 别的看图软件里通常看不到，而它们正是手写解码器时唯一需要关心的东西。
///
/// 面板不认识任何具体格式 —— 它遍历 [ImageMetadata.toDisplayMap]。所以
/// 加 PNG / JPEG / WebP 时这个文件一行都不用改，新字段自动出现。
class InfoPanel extends StatelessWidget {
  const InfoPanel({
    required this.file,
    required this.image,
    super.key,
  });

  final ImageFile file;
  final DisplayImage image;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Container(
      width: 300,
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerLow,
        border: Border(
          left: BorderSide(color: theme.dividerColor),
        ),
      ),
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 12),
        children: <Widget>[
          _section(context, '文件'),
          // 文件名可能很长，允许换行而不是省略号 —— 看图时文件名往往
          // 是分辨哪张图的唯一线索。
          _row(context, '名称', file.name, wrap: true),
          _row(context, '大小', file.sizeLabel),
          _row(context, '来源', file.source.label),
          if (file.extension.isNotEmpty)
            _row(context, '扩展名', '.${file.extension}'),
          if (file.path != null) _row(context, '路径', file.path!, wrap: true),

          _section(context, '图像'),
          _row(context, '尺寸', '${image.width} × ${image.height}'),
          _row(context, '像素总数', _formatCount(image.width * image.height)),
          // 解码后一律是 RGBA8888，所以内存占用是可以直接算出来的。
          _row(context, '解码后占用',
              ImageFile.formatByteSize(image.width * image.height * 4)),
          _row(context, '含透明像素', image.hasTransparency ? '是' : '否'),

          _section(context, '格式'),
          // 这一段全部来自元数据，不同格式条目数不一样。
          for (final MapEntry<String, String> e
              in image.source.metadata.toDisplayMap().entries)
            _row(context, e.key, e.value, wrap: e.value.length > 24),
        ],
      ),
    );
  }

  /// 分组标题。
  Widget _section(BuildContext context, String title) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(left: 16, right: 16, top: 16, bottom: 6),
      child: Text(
        title,
        style: theme.textTheme.labelLarge?.copyWith(
          color: theme.colorScheme.primary,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  /// 一行「键：值」。
  ///
  /// 键固定宽度、值占剩下的空间，这样多行之间键值对齐，扫读时容易。
  Widget _row(BuildContext context, String key, String value,
      {bool wrap = false}) {
    final ThemeData theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              key,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
          Expanded(
            child: SelectableText(
              value,
              maxLines: wrap ? null : 1,
              style: theme.textTheme.bodySmall,
            ),
          ),
        ],
      ),
    );
  }

  /// 给大数字加千位分隔，`1920000` → `1,920,000`。
  ///
  /// 像素总数动辄七八位，不分隔基本读不出数量级。
  static String _formatCount(int n) {
    final String s = '$n';
    final StringBuffer sb = StringBuffer();
    for (int i = 0; i < s.length; i++) {
      if (i > 0 && (s.length - i) % 3 == 0) {
        sb.write(',');
      }
      sb.write(s[i]);
    }
    return sb.toString();
  }
}
