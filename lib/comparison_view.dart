import 'dart:typed_data';

import 'package:flutter/material.dart';

/// 控制左右对比视图的同步缩放。
///
/// 左右两个 [InteractiveViewer] 共用同一个 [transformation]，
/// 因此缩放和平移始终同步；[scale] 是当前缩放比例，
/// 供外部工具条展示（例如「150%」）。
class ComparisonController extends ChangeNotifier {
  ComparisonController({this.minScale = 1, this.maxScale = 32})
    : assert(minScale > 0),
      assert(maxScale > minScale) {
    transformation.addListener(_handleTransformationChanged);
  }

  /// 预设的缩放档位，按钮逐档放大/缩小，最高 3200%。
  static const List<double> _zoomSteps = <double>[
    1,
    1.5,
    2,
    3,
    4,
    6,
    8,
    12,
    16,
    24,
    32,
  ];

  final double minScale;
  final double maxScale;

  /// 左右两侧共享的变换矩阵。
  final TransformationController transformation = TransformationController();

  double _scale = 1;
  Size _paneSize = Size.zero;

  /// 当前缩放比例，1 表示原始大小。
  double get scale => _scale;

  /// 预览面板的尺寸（单图或对比视图的每一侧）。
  Size get paneSize => _paneSize;

  bool get canZoomIn => _scale < maxScale - 0.01;

  bool get canZoomOut => _scale > minScale + 0.01;

  @override
  void dispose() {
    transformation.removeListener(_handleTransformationChanged);
    transformation.dispose();
    super.dispose();
  }

  void _handleTransformationChanged() {
    final double next = transformation.value.getMaxScaleOnAxis().clamp(
      minScale,
      maxScale,
    );
    if ((next - _scale).abs() > 0.001) {
      _scale = next;
      notifyListeners();
    }
  }

  /// 由 [ComparisonView] 在布局时回填，用于以面板中心为锚点缩放。
  void updatePaneSize(Size size) {
    _paneSize = size;
  }

  void zoomIn() {
    for (final double step in _zoomSteps) {
      if (step > _scale + 0.01 && step <= maxScale) {
        _setScale(step);
        return;
      }
    }
    _setScale(maxScale);
  }

  void zoomOut() {
    for (final double step in _zoomSteps.reversed) {
      if (step < _scale - 0.01 && step >= minScale) {
        _setScale(step);
        return;
      }
    }
    _setScale(minScale);
  }

  void reset() {
    transformation.value = Matrix4.identity();
  }

  /// 以面板中心为锚点，把缩放比例调整到 [target]。
  void _setScale(double target) {
    if (_paneSize.isEmpty) {
      return;
    }
    final Matrix4 matrix = transformation.value;
    final double current = matrix.getMaxScaleOnAxis();
    final double clamped = target.clamp(minScale, maxScale);
    if ((clamped - current).abs() < 0.001) {
      return;
    }

    final double factor = clamped / current;
    final Offset translation = Offset(matrix.entry(0, 3), matrix.entry(1, 3));
    final Offset center = Offset(_paneSize.width / 2, _paneSize.height / 2);
    final Offset nextTranslation = center * (1 - factor) + translation * factor;
    _apply(clamped, nextTranslation);
  }

  /// 连续缩放（供移动端「触控板」的双指捏合使用）。
  void zoomBy(double factor) {
    if (_paneSize.isEmpty || !factor.isFinite || factor <= 0) {
      return;
    }
    final Matrix4 matrix = transformation.value;
    final double current = matrix.getMaxScaleOnAxis();
    final double target = (current * factor).clamp(minScale, maxScale);
    if ((target - current).abs() < 0.001) {
      return;
    }

    final double applied = target / current;
    final Offset translation = Offset(matrix.entry(0, 3), matrix.entry(1, 3));
    final Offset center = Offset(_paneSize.width / 2, _paneSize.height / 2);
    final Offset nextTranslation =
        center * (1 - applied) + translation * applied;
    _apply(target, nextTranslation);
  }

  /// 平移（供移动端「触控板」的拖动使用）。
  void panBy(Offset delta) {
    if (_paneSize.isEmpty || delta == Offset.zero) {
      return;
    }
    final Matrix4 matrix = transformation.value;
    final double scale = matrix.getMaxScaleOnAxis();
    final Offset translation =
        Offset(matrix.entry(0, 3), matrix.entry(1, 3)) + delta;
    _apply(scale, translation);
  }

  void _apply(double scale, Offset translation) {
    final Offset clamped = _clampTranslation(translation, scale);
    transformation.value = Matrix4.identity()
      ..setEntry(0, 0, scale)
      ..setEntry(1, 1, scale)
      ..setEntry(0, 3, clamped.dx)
      ..setEntry(1, 3, clamped.dy);
  }

  /// 把平移限制在内容边界内，避免把图片拖出可视区域。
  Offset _clampTranslation(Offset translation, double scale) {
    final double maxX = _paneSize.width * (scale - 1);
    final double maxY = _paneSize.height * (scale - 1);
    return Offset(
      translation.dx.clamp(-maxX, 0.0).toDouble(),
      translation.dy.clamp(-maxY, 0.0).toDouble(),
    );
  }
}

/// 左右对比原图与压缩结果。
///
/// 两侧共用 [controller] 的同一个变换矩阵，缩放和平移始终同步，
/// 因此可以并排比较同一块区域的清晰度和压缩痕迹。
class ComparisonView extends StatelessWidget {
  const ComparisonView({
    super.key,
    required this.original,
    required this.processed,
    required this.controller,
    this.originalLabel = '原图',
    this.processedLabel = '压缩后',
  });

  /// 原图字节（与 [processed] 保持相同宽高比）。
  final Uint8List original;

  /// 压缩后的图片字节。
  final Uint8List processed;

  final ComparisonController controller;
  final String originalLabel;
  final String processedLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            // 中间的分割线占 1dp，左右两侧等宽。
            controller.updatePaneSize(
              Size((constraints.maxWidth - 1) / 2, constraints.maxHeight),
            );
            return Row(
              children: <Widget>[
                Expanded(
                  child: _Pane(
                    bytes: original,
                    label: originalLabel,
                    controller: controller,
                  ),
                ),
                Container(width: 1, color: theme.colorScheme.outlineVariant),
                Expanded(
                  child: _Pane(
                    bytes: processed,
                    label: processedLabel,
                    controller: controller,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Pane extends StatelessWidget {
  const _Pane({
    required this.bytes,
    required this.label,
    required this.controller,
  });

  final Uint8List bytes;
  final String label;
  final ComparisonController controller;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        InteractiveViewer(
          transformationController: controller.transformation,
          minScale: controller.minScale,
          maxScale: controller.maxScale,
          child: Image.memory(
            bytes,
            fit: BoxFit.contain,
            gaplessPlayback: true,
            filterQuality: FilterQuality.medium,
            semanticLabel: label,
          ),
        ),
        Positioned(
          top: 8,
          left: 8,
          child: IgnorePointer(
            child: Material(
              color: theme.colorScheme.surfaceContainerHigh,
              shape: const StadiumBorder(),
              elevation: 1,
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                child: Text(
                  label,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 对比视图的缩放工具条：缩小、比例、放大、还原。
class ComparisonZoomBar extends StatelessWidget {
  const ComparisonZoomBar({super.key, required this.controller});

  final ComparisonController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? child) {
        final ThemeData theme = Theme.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            IconButton(
              onPressed: controller.canZoomOut ? controller.zoomOut : null,
              tooltip: '缩小',
              icon: const Icon(Icons.remove),
            ),
            SizedBox(
              width: 56,
              child: Text(
                '${(controller.scale * 100).round()}%',
                textAlign: TextAlign.center,
                style: theme.textTheme.labelLarge,
              ),
            ),
            IconButton(
              onPressed: controller.canZoomIn ? controller.zoomIn : null,
              tooltip: '放大',
              icon: const Icon(Icons.add),
            ),
            IconButton(
              onPressed: controller.canZoomOut ? controller.reset : null,
              tooltip: '还原',
              icon: const Icon(Icons.zoom_out_map),
            ),
          ],
        );
      },
    );
  }
}

/// 单张结果的缩放预览，与 [ComparisonController] 共享缩放/平移状态。
///
/// 支持双指捏合、滚轮与拖动，也可以在移动端通过下方的信息区作为
/// 「触控板」来操作。
class SinglePhotoView extends StatelessWidget {
  const SinglePhotoView({
    super.key,
    required this.bytes,
    required this.controller,
    this.semanticLabel = '压缩后的图片预览',
  });

  final Uint8List bytes;
  final ComparisonController controller;
  final String semanticLabel;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return ClipRRect(
      borderRadius: BorderRadius.circular(12),
      child: ColoredBox(
        color: theme.colorScheme.surfaceContainerHighest,
        child: LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            controller.updatePaneSize(constraints.biggest);
            return InteractiveViewer(
              transformationController: controller.transformation,
              minScale: controller.minScale,
              maxScale: controller.maxScale,
              child: Image.memory(
                bytes,
                fit: BoxFit.contain,
                gaplessPlayback: true,
                filterQuality: FilterQuality.medium,
                semanticLabel: semanticLabel,
              ),
            );
          },
        ),
      ),
    );
  }
}
