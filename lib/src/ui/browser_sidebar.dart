import 'package:file_selector/file_selector.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show AssetManifest, rootBundle;
import 'package:image_viewer/src/platform/file_source.dart';
import 'package:image_viewer/src/platform/image_file.dart';

/// 左侧的来源侧栏：内置样图 + 目录浏览。
///
/// ## 两个来源为什么都要有
///
/// 内置样图（assets）是**唯一在六个平台上都有**的来源 —— Web 和移动端拿不到
/// 本地文件系统，空手启动时如果什么都看不到，用户没法判断 App 是不是坏了。
/// 十二张样图覆盖了三种格式的关键分支，打开就能看到解码器在干活。
///
/// 目录浏览只在 [FileSource.canBrowse] 为真的平台显示。Web 上连这一节都不画
/// —— 与其摆一个点了没反应的按钮，不如干脆不摆。
class BrowserSidebar extends StatefulWidget {
  const BrowserSidebar({
    required this.onOpenAsset,
    required this.onOpenPath,
    this.selected,
    super.key,
  });

  /// 点了内置样图。参数是 asset key，如 `assets/samples/x.bmp`。
  final ValueChanged<String> onOpenAsset;

  /// 点了目录里的文件。参数是绝对路径。
  final ValueChanged<String> onOpenPath;

  /// 当前打开的那一项（asset key 或路径），用于高亮。
  final String? selected;

  @override
  State<BrowserSidebar> createState() => _BrowserSidebarState();
}

class _BrowserSidebarState extends State<BrowserSidebar> {
  static const FileSource _fs = FileSource();

  /// null = manifest 还没读完；空列表 = 读完了但一张样图都没打包进来。
  ///
  /// 区分这两者是为了别在启动的那一帧闪一下「没有找到样图」—— 那会让人以为
  /// assets 配错了。
  List<String>? _assets;

  String? _dir;
  List<DirectoryEntry> _entries = const <DirectoryEntry>[];

  /// 列目录失败的原因。macOS 沙盒下最常见。
  String? _dirError;

  bool _loading = false;

  @override
  void initState() {
    super.initState();
    _loadAssets();
  }

  /// 枚举打包进来的样图。
  ///
  /// 从 `AssetManifest` 读而不是把文件名写死在代码里 —— `tool/gen_samples.dart`
  /// 加一张新样图时，这里应该自动出现，不该还要改一次 UI 代码。
  ///
  /// 用 `rootBundle` 而不是 `DefaultAssetBundle.of(context)`：后者会注册一条
  /// InheritedWidget 依赖，在 `initState` 里调用会触发断言。样图是打包资源，
  /// 本来也不需要跟着 context 走。
  Future<void> _loadAssets() async {
    final AssetManifest manifest =
        await AssetManifest.loadFromAssetBundle(rootBundle);
    final List<String> keys = manifest
        .listAssets()
        .where((String k) => k.startsWith('assets/samples/'))
        .toList()
      ..sort();
    if (mounted) {
      setState(() => _assets = keys);
    }
  }

  /// 让用户挑一个目录。
  ///
  /// **macOS 上这一步不只是「方便」，而是必需的。** 沙盒 App 只能读用户经由
  /// 系统对话框明确选中的路径 —— 我们没法自己 `Directory('/Users/x/Pictures')`
  /// 列出来。所以这里不提供「输入路径跳转」，那在沙盒下必然失败。
  Future<void> _pickDirectory() async {
    final String? picked = await getDirectoryPath(
      initialDirectory: _dir ?? _fs.homeDirectory,
      confirmButtonText: '浏览此文件夹',
    );
    if (picked != null) {
      await _openDirectory(picked);
    }
  }

  /// 列出一个目录，失败时把原因留在 [_dirError] 上而不是抛出去。
  ///
  /// `FileSource.listDirectory` 已经兜住了单个条目 `statSync` 失败的情况，
  /// 但 `dir.list()` 本身在整个目录不可读时会抛 —— 那正是 macOS 沙盒拒绝
  /// 访问时走的路径。侧栏必须自己接住，否则点一下文件夹整个页面就崩了。
  Future<void> _openDirectory(String path) async {
    setState(() {
      _loading = true;
      _dirError = null;
    });
    try {
      final List<DirectoryEntry> entries = await _fs.listDirectory(path);
      if (mounted) {
        setState(() {
          _dir = path;
          _entries = entries;
          _loading = false;
        });
      }
    } on Object catch (e) {
      if (mounted) {
        setState(() {
          // 路径仍然切过去：让用户看见自己在哪、能往上退一级。
          _dir = path;
          _entries = const <DirectoryEntry>[];
          _dirError = _explainListFailure(e);
          _loading = false;
        });
      }
    }
  }

  /// 把列目录的异常翻译成人话。
  ///
  /// 沙盒拒绝访问时抛的是 `PathAccessException`，原文长这样：
  /// `Directory listing failed, path = '/Users/x/Pictures' (OS Error:
  /// Operation not permitted, errno = 1)`。直接摆给用户看，像是程序坏了；
  /// 其实是系统按设计拦下的，且有明确的解法（用「选择文件夹」重新授权）。
  String _explainListFailure(Object error) {
    final String raw = error.toString();
    if (raw.contains('Operation not permitted') ||
        raw.contains('Permission denied')) {
      return '系统不允许读这个文件夹。\n'
          'macOS 沙盒只放行你在「选择文件夹」对话框里明确选中的目录，'
          '请用上方按钮重新选一次。';
    }
    return raw;
  }

  /// 退到父目录。
  ///
  /// 注意这在 macOS 沙盒下**经常会失败** —— 用户授权的是选中的那个文件夹，
  /// 不含它的父目录。所以失败信息要说清楚「重新选一次」，见
  /// [_explainListFailure]。
  Future<void> _goUp() async {
    final String? dir = _dir;
    if (dir == null) {
      return;
    }
    final String? parent = _fs.parentOf(dir);
    if (parent != null) {
      await _openDirectory(parent);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _sectionHeader('内置样图', Icons.collections_outlined),
        // 不可浏览的平台（Web）上这是唯一的 Expanded，样图列表铺满整条侧栏。
        Expanded(flex: 2, child: _assetList()),
        if (_fs.canBrowse) ...<Widget>[
          const Divider(height: 1),
          _directoryHeader(),
          Expanded(flex: 3, child: _directoryBody()),
        ],
      ],
    );
  }

  Widget _sectionHeader(
    String title,
    IconData icon, {
    String? tooltip,
    List<Widget> actions = const <Widget>[],
  }) {
    Widget label = Text(
      title,
      overflow: TextOverflow.ellipsis,
      style: Theme.of(context).textTheme.labelLarge,
    );
    if (tooltip != null) {
      label = Tooltip(message: tooltip, child: label);
    }
    return Padding(
      padding: EdgeInsets.fromLTRB(12, 10, actions.isEmpty ? 12 : 4, 6),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15),
          const SizedBox(width: 8),
          Expanded(child: label),
          ...actions,
        ],
      ),
    );
  }

  Widget _assetList() {
    final List<String>? assets = _assets;
    if (assets == null) {
      return _spinner();
    }
    if (assets.isEmpty) {
      // 这几乎总是「没跑生成脚本」，所以直接把命令写出来。
      return _hint('没有找到内置样图。\n\n'
          '跑一次 `dart tool/gen_samples.dart` 生成，'
          '并确认 pubspec.yaml 里声明了 assets/samples/。');
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: assets.length,
      itemBuilder: (BuildContext context, int i) {
        final String key = assets[i];
        return _tile(
          icon: Icons.image_outlined,
          // 只显示文件名：`assets/samples/` 这段前缀每行都一样，没有信息量。
          label: key.substring(key.lastIndexOf('/') + 1),
          selected: widget.selected == key,
          onTap: () => widget.onOpenAsset(key),
        );
      },
    );
  }

  Widget _directoryHeader() {
    final String? dir = _dir;
    return _sectionHeader(
      // 标题显示当前目录名而不是全路径 —— 侧栏只有 300px，全路径必然被截断，
      // 截断后留下的还是最没用的那一头。全路径挂在 tooltip 上。
      dir == null ? '目录浏览' : _fs.basenameOf(dir),
      Icons.folder_outlined,
      tooltip: dir,
      actions: <Widget>[
        if (dir != null && _fs.parentOf(dir) != null)
          IconButton(
            icon: const Icon(Icons.arrow_upward, size: 16),
            tooltip: '上一级',
            visualDensity: VisualDensity.compact,
            onPressed: _goUp,
          ),
        IconButton(
          icon: const Icon(Icons.folder_open_outlined, size: 16),
          tooltip: '选择文件夹',
          visualDensity: VisualDensity.compact,
          onPressed: _pickDirectory,
        ),
      ],
    );
  }

  Widget _directoryBody() {
    if (_loading) {
      return _spinner();
    }
    final String? error = _dirError;
    if (error != null) {
      return _hint(error, icon: Icons.lock_outline);
    }
    if (_dir == null) {
      // 首次进入不自动打开 home 目录：macOS 沙盒下那一定失败，
      // 一启动就摆一条红色错误，像是 App 坏了。让用户主动选一次。
      return _hint(
        _fs.platformLabel == 'macOS'
            ? '点上方的文件夹图标选一个目录。\n\n'
                'macOS 沙盒只放行你在系统对话框里明确选中的文件夹，'
                '这是系统的设计，不是这里少做了什么。'
            : '点上方的文件夹图标选一个目录。',
        icon: Icons.folder_open_outlined,
      );
    }
    if (_entries.isEmpty) {
      return _hint('这个文件夹里没有可显示的图像文件。\n\n'
          '侧栏按扩展名过滤，改错扩展名的文件不会出现在这里 —— '
          '用「打开文件」直接选它，格式判断只认魔数。');
    }
    return ListView.builder(
      padding: EdgeInsets.zero,
      itemCount: _entries.length,
      itemBuilder: (BuildContext context, int i) {
        final DirectoryEntry e = _entries[i];
        final int? size = e.sizeBytes;
        return _tile(
          icon: e.isDirectory ? Icons.folder : Icons.image_outlined,
          label: e.name,
          tooltip: e.path,
          trailing: size == null ? null : ImageFile.formatByteSize(size),
          selected: widget.selected == e.path,
          onTap: () => e.isDirectory
              ? _openDirectory(e.path)
              : widget.onOpenPath(e.path),
        );
      },
    );
  }

  /// 侧栏里的一行。样图和目录条目共用，两边视觉上就该一致。
  Widget _tile({
    required IconData icon,
    required String label,
    required bool selected,
    required VoidCallback onTap,
    String? tooltip,
    String? trailing,
  }) {
    final ThemeData theme = Theme.of(context);
    Widget row = Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
      child: Row(
        children: <Widget>[
          Icon(
            icon,
            size: 14,
            color: selected
                ? theme.colorScheme.primary
                : theme.colorScheme.onSurfaceVariant,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              label,
              // 末尾截断：样图名的区分度在开头（`gradient_…` / `topdown_…`），
              // 尾部那截 `_61x40_24bpp.bmp` 反而高度雷同。真要看全名有 tooltip。
              overflow: TextOverflow.ellipsis,
              softWrap: false,
              style: theme.textTheme.bodySmall?.copyWith(
                fontWeight: selected ? FontWeight.w600 : null,
                color: selected ? theme.colorScheme.primary : null,
              ),
            ),
          ),
          if (trailing != null) ...<Widget>[
            const SizedBox(width: 6),
            Text(
              trailing,
              style: theme.textTheme.labelSmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ],
      ),
    );
    if (tooltip != null) {
      row = Tooltip(message: tooltip, waitDuration: _tooltipDelay, child: row);
    }
    return Material(
      color: selected ? theme.colorScheme.primary.withValues(alpha: 0.10) : null,
      child: InkWell(onTap: onTap, child: row),
    );
  }

  Widget _spinner() => const Center(
        child: SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );

  /// 空状态/错误状态的说明文字。
  ///
  /// 每一条都写成「发生了什么 + 下一步做什么」。侧栏是空的时候，用户需要的
  /// 不是「暂无数据」，而是知道该点哪儿。
  Widget _hint(String text, {IconData icon = Icons.info_outline}) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 20, color: theme.colorScheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              text,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// tooltip 的等待时长。
///
/// 默认是立刻弹，列表里鼠标一扫过去就一串气泡跳出来，很吵。
const Duration _tooltipDelay = Duration(milliseconds: 600);
