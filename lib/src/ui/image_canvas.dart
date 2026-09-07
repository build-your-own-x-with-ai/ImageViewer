import 'package:flutter/material.dart';
import 'package:image_viewer/src/ui/checkerboard.dart';
import 'package:image_viewer/src/ui/image_bridge.dart';

/// 图像在窗口里怎么摆。
enum ViewMode {
  /// 缩放到完整可见（可能上下或左右留白）。打开新图时的默认。
  fit('适配窗口', Icons.fit_screen),

  /// 1:1 —— 一个图像像素对一个逻辑像素。
  ///
  /// 教学项目里这个模式很重要：看解码结果有没有错位、有没有斜纹，
  /// 必须在 1:1 下看，任何缩放都会用插值把细节抹掉。
  actual('原始尺寸', Icons.crop_original),

  /// 缩放到铺满窗口（超出部分裁掉）。
  fill('填充窗口', Icons.crop_free);

  const ViewMode(this.label, this.icon);

  final String label;
  final IconData icon;
}

/// 可缩放平移的图像画布。
///
/// 缩放范围与放大时的采样方式是这个组件的两个关键决策，见下面注释。
class ImageCanvas extends StatefulWidget {
  const ImageCanvas({required this.image, super.key});

  final DisplayImage image;

  @override
  State<ImageCanvas> createState() => _ImageCanvasState();
}

/// 缩放下限。比这更小就只是一个色块，没有观察价值。
const double _minScale = 0.05;

/// 缩放上限 64 倍。
///
/// 定这么高是刻意的：教学项目里「放大到能看见单个像素的方格」是核心用途 ——
/// 查 RLE 解码错位、查 alpha 边缘、查 YUV 色度上采样，都得放到几十倍才看得清。
/// 配合下面的最近邻采样，64 倍时一个图像像素是一个 64×64 的实心方块。
const double _maxScale = 64.0;

class _ImageCanvasState extends State<ImageCanvas> {
  final TransformationController _controller = TransformationController();

  ViewMode _mode = ViewMode.fit;

  /// 上一帧的视口尺寸，用来判断窗口是不是被拖动了。
  Size? _viewport;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  void didUpdateWidget(ImageCanvas oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 换图时回到适配窗口。沿用上一张图的缩放没有意义 —— 尺寸可能差几十倍，
    // 用户会看到一张「不知道飞到哪去了」的图。
    if (oldWidget.image != widget.image) {
      _mode = ViewMode.fit;
      if (_viewport != null) {
        _applyMode(_viewport!);
      }
    }
  }

  /// 当前缩放倍率。矩阵的 x 轴缩放分量就是它（这里不存在非等比缩放）。
  double get _scale => _controller.value.getMaxScaleOnAxis();

  /// 把图像按 [mode] 摆进 [viewport]。
  void _applyMode(Size viewport) {
    final double iw = widget.image.width.toDouble();
    final double ih = widget.image.height.toDouble();
    if (iw <= 0 || ih <= 0) {
      return;
    }

    final double sx = viewport.width / iw;
    final double sy = viewport.height / ih;
    final double scale = switch (_mode) {
      // fit 取较小的那个（两边都装得下），fill 取较大的（铺满、超出裁掉）。
      ViewMode.fit => sx < sy ? sx : sy,
      ViewMode.fill => sx > sy ? sx : sy,
      ViewMode.actual => 1.0,
    };

    _setScaleCentered(scale.clamp(_minScale, _maxScale), viewport);
  }

  /// 以视口中心为锚点设置缩放倍率。
  void _setScaleCentered(double scale, Size viewport) {
    final double iw = widget.image.width.toDouble();
    final double ih = widget.image.height.toDouble();

    // 让图像中心落在视口中心：先缩放，再把缩放后的图挪到中间。
    // Matrix4 的乘法顺序是右乘先作用，所以 translate 写在 scale 前面。
    final double tx = viewport.width / 2 - scale * iw / 2;
    final double ty = viewport.height / 2 - scale * ih / 2;

    _controller.value = Matrix4.identity()
      ..translateByDouble(tx, ty, 0, 1)
      ..scaleByDouble(scale, scale, 1, 1);
  }

  /// 按倍数缩放，锚点是视口中心。
  void _zoomBy(double factor) {
    final Size? viewport = _viewport;
    if (viewport == null) {
      return;
    }
    final double target = (_scale * factor).clamp(_minScale, _maxScale);
    setState(() => _setScaleCentered(target, viewport));
  }

  void _switchMode(ViewMode mode) {
    final Size? viewport = _viewport;
    setState(() {
      _mode = mode;
      if (viewport != null) {
        _applyMode(viewport);
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final Size viewport = constraints.biggest;

        // 首帧、以及窗口尺寸变化时重新摆位。放在 build 里用 post-frame 回调，
        // 因为此刻正在布局，不能同步 setState。
        if (_viewport != viewport) {
          _viewport = viewport;
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) {
              setState(() => _applyMode(viewport));
            }
          });
        }

        return Stack(
          children: <Widget>[
            Positioned.fill(child: _buildViewer(viewport)),
            Positioned(
              right: 12,
              bottom: 12,
              child: _buildControls(context),
            ),
          ],
        );
      },
    );
  }

  Widget _buildViewer(Size viewport) {
    return InteractiveViewer(
      transformationController: _controller,
      minScale: _minScale,
      maxScale: _maxScale,
      // 允许把图拖出视口边界。放大到 64 倍看角落的像素时，
      // 不给这个余量就够不到边缘。
      boundaryMargin: const EdgeInsets.all(double.infinity),
      // 图像本身不裁剪，由外层 ClipRect 控制 —— InteractiveViewer 自己裁
      // 会把上面那个无限 boundaryMargin 也算进去，反而出问题。
      clipBehavior: Clip.none,
      child: ValueListenableBuilder<Matrix4>(
        valueListenable: _controller,
        builder: (BuildContext context, Matrix4 matrix, Widget? child) {
          final double scale = matrix.getMaxScaleOnAxis();
          return SizedBox(
            width: widget.image.width.toDouble(),
            height: widget.image.height.toDouble(),
            child: CustomPaint(
              // 棋盘格垫在图下面，且只在真有透明像素时画。
              painter: widget.image.hasTransparency
                  ? const CheckerboardPainter()
                  : null,
              child: RawImage(
                image: widget.image.texture,
                // **放大用最近邻、缩小用线性**，这是本项目的关键渲染决策。
                //
                // 放大时若用插值，相邻像素会被抹成渐变 —— 而「像素的边界在
                // 哪」正是我们要看的东西（解码错位表现为一道斜纹，插值之后
                // 就成了一片模糊）。所以 scale >= 1 时一律 none，保证一个
                // 图像像素是一个实心方块。
                //
                // 缩小时反过来：不插值会走样，一张 4000 宽的图缩到 800
                // 会出现摩尔纹，那是采样假象、不是解码结果。
                filterQuality:
                    scale >= 1.0 ? FilterQuality.none : FilterQuality.medium,
              ),
            ),
          );
        },
      ),
    );
  }

  /// 右下角的缩放条：三种摆放模式 + 增减倍率 + 当前倍率读数。
  Widget _buildControls(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return Card(
      elevation: 3,
      color: theme.colorScheme.surface.withValues(alpha: 0.92),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            for (final ViewMode mode in ViewMode.values)
              IconButton(
                icon: Icon(mode.icon),
                iconSize: 20,
                tooltip: mode.label,
                isSelected: _mode == mode,
                onPressed: () => _switchMode(mode),
              ),
            const SizedBox(
              height: 24,
              child: VerticalDivider(width: 12),
            ),
            IconButton(
              icon: const Icon(Icons.remove),
              iconSize: 20,
              tooltip: '缩小',
              onPressed: () => _zoomBy(1 / 1.5),
            ),
            // 倍率读数。放大时用整数（64x），缩小时留一位小数（0.3x），
            // 因为缩小区间里整数会全都显示成 0x。
            ValueListenableBuilder<Matrix4>(
              valueListenable: _controller,
              builder: (BuildContext context, Matrix4 matrix, Widget? child) {
                final double scale = matrix.getMaxScaleOnAxis();
                final String label = scale >= 1
                    ? '${scale.round()}x'
                    : '${scale.toStringAsFixed(2)}x';
                return SizedBox(
                  width: 52,
                  child: Text(
                    label,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelMedium,
                  ),
                );
              },
            ),
            IconButton(
              icon: const Icon(Icons.add),
              iconSize: 20,
              tooltip: '放大',
              onPressed: () => _zoomBy(1.5),
            ),
          ],
        ),
      ),
    );
  }
}
