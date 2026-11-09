import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;

import 'comparison_view.dart';
import 'compression_cache.dart';
import 'image_pipeline.dart';
import 'image_resizer.dart';
import 'photo_picker.dart';
import 'photo_saver.dart';
import 'sharpen_option.dart';

void main() {
  runApp(const MomentsPhotoResizerApp());
}

class MomentsPhotoResizerApp extends StatelessWidget {
  const MomentsPhotoResizerApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: '图压压',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorSchemeSeed: const Color(0xFF2F6F5E),
        useMaterial3: true,
      ),
      home: const HomePage(),
    );
  }
}

class HomePage extends StatefulWidget {
  const HomePage({super.key, this.pickImage = PhotoPicker.pickImage});

  /// 选图入口；默认使用系统选择器，测试或预览时可注入固定图片。
  final Future<PickedPhoto?> Function() pickImage;

  @override
  State<HomePage> createState() => _HomePageState();
}

/// 结果页的展示模式。
enum ResultViewMode {
  /// 只看压缩后的结果。
  result,

  /// 原图与结果左右对比。
  compare,
}

const List<DropdownMenuEntry<img.Interpolation>> _interpolationEntries =
    <DropdownMenuEntry<img.Interpolation>>[
      DropdownMenuEntry<img.Interpolation>(
        value: img.Interpolation.average,
        label: '区域平均',
      ),
      DropdownMenuEntry<img.Interpolation>(
        value: img.Interpolation.linear,
        label: '双线性',
      ),
      DropdownMenuEntry<img.Interpolation>(
        value: img.Interpolation.cubic,
        label: '双三次',
      ),
      DropdownMenuEntry<img.Interpolation>(
        value: img.Interpolation.nearest,
        label: '最近邻',
      ),
    ];

/// JPEG 质量的推荐档位，滑条会吸附到这些固定档位。
const List<int> _qualityPresets = <int>[75, 85, 95, 100];

/// 取最接近 [quality] 的推荐档位下标。
int _nearestQualityIndex(int quality) {
  int best = 0;
  for (int i = 1; i < _qualityPresets.length; i++) {
    if ((_qualityPresets[i] - quality).abs() <
        (_qualityPresets[best] - quality).abs()) {
      best = i;
    }
  }
  return best;
}

class _HomePageState extends State<HomePage> {
  /// 默认采样算法：选图后自动在后台补齐它的全部质量档位。
  static const img.Interpolation _defaultInterpolation =
      img.Interpolation.average;

  late final ImagePipeline _pipeline = ImagePipeline(
    onGpuFallback: _handleGpuFallback,
  );

  late final CompressionCache _compressionCache = CompressionCache(
    compress: _compressWith,
  );

  bool _busy = false;
  String _busyTitle = '正在处理图片…';
  String _busySubtitle = '大图解码和缩放需要一点时间';

  /// 是否正在等待系统选图器返回。
  bool _picking = false;
  String? _error;
  PickedPhoto? _source;
  ResizedPhoto? _result;
  ResultViewMode _mode = ResultViewMode.result;
  img.Interpolation _interpolation = _defaultInterpolation;
  int _jpegQuality = 100;
  SharpenOption _sharpen = SharpenOption.none;
  String _backendLabel = 'CPU 多核';

  /// 参数调整时的静默重算：保留原界面，完成后直接替换结果照片。
  bool _renderingParams = false;

  /// 锐化渲染进行中时冻结锐化滑条，避免连续提交过多渲染作业。
  bool _sharpenLocked = false;
  int _paramGeneration = 0;

  /// 后台渲染：为当前采样算法补齐所有质量档位（默认算法在选图后自动开始）。
  bool _backgroundRendering = false;
  int _backgroundDone = 0;
  int _backgroundTotal = 0;
  img.Interpolation? _backgroundAlgorithm;
  SharpenOption? _backgroundSharpen;
  int _backgroundGeneration = 0;

  Future<ResizedPhoto> _compressWith(
    Uint8List bytes,
    img.Interpolation interpolation,
    int jpegQuality,
    SharpenOption sharpen,
  ) {
    return _pipeline.processOne(
      bytes,
      interpolation: interpolation,
      jpegQuality: jpegQuality,
      sharpen: sharpen,
    );
  }

  /// GPU 不可用时提示一次，并刷新界面上的后端标记。
  void _handleGpuFallback() {
    if (!mounted) {
      return;
    }
    setState(() => _backendLabel = _pipeline.backendLabel);
    _showMessage('GPU 加速不可用，已自动回退到多核 CPU 渲染');
  }

  Future<void> _pickAndProcess() async {
    if (_busy || _picking) {
      return;
    }

    // 选图期间保持当前界面（空状态或上一次的结果），
    // 等真正拿到图片后再切换到渲染界面。
    setState(() {
      _picking = true;
      _error = null;
    });

    try {
      final PickedPhoto? picked = await widget.pickImage();
      if (!mounted) {
        return;
      }
      setState(() => _picking = false);
      if (picked == null) {
        return;
      }
      await _processSource(picked);
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _picking = false);
      _handleProcessingError(error);
    }
  }

  /// 处理一张新原图：先渲染当前组合，再在后台补齐该算法的质量档位。
  Future<void> _processSource(PickedPhoto picked) async {
    setState(() {
      _busy = true;
      _busyTitle = '正在生成当前结果…';
      _busySubtitle = '完成后会在后台补齐当前算法的其他质量档位';
      _renderingParams = false;
      _sharpenLocked = false;
      _backgroundRendering = false;
      _error = null;
    });

    _compressionCache.clear();
    _backgroundGeneration++;
    final int generation = ++_paramGeneration;

    try {
      final ResizedPhoto current = await _compressionCache.process(
        picked.bytes,
        _interpolation,
        _jpegQuality,
        _sharpen,
      );
      if (!mounted || generation != _paramGeneration) {
        return;
      }
      setState(() {
        _source = picked;
        _result = current;
        _busy = false;
        _busyTitle = '正在处理图片…';
        _busySubtitle = '大图解码和缩放需要一点时间';
        _backendLabel = _pipeline.backendLabel;
      });
      _startBackgroundQualityRendering(_interpolation, _sharpen);
    } catch (error) {
      _handleProcessingError(error);
    }
  }

  void _handleProcessingError(Object error) {
    if (!mounted) {
      return;
    }
    setState(() {
      _busy = false;
      _renderingParams = false;
      _sharpenLocked = false;
      _error = _describeError(error);
    });
    _showMessage(_error!);
  }

  /// 切换 GPU 加速：清空缓存后静默重算当前组合（保留原界面）。
  Future<void> _setUseGpu(bool value) async {
    if (_pipeline.preferGpu == value) {
      return;
    }
    setState(() {
      _pipeline.preferGpu = value;
      if (value) {
        _pipeline.resetGpuAvailability();
      }
      _backendLabel = _pipeline.backendLabel;
    });
    _compressionCache.clear();
    _backgroundGeneration++;
    await _rerenderCurrent();
  }

  /// 后台补齐指定算法的全部质量档位（已在算或已全部缓存时跳过）。
  void _startBackgroundQualityRendering(
    img.Interpolation algorithm,
    SharpenOption sharpen,
  ) {
    final PickedPhoto? source = _source;
    if (source == null) {
      return;
    }
    if (_backgroundRendering &&
        _backgroundAlgorithm == algorithm &&
        _backgroundSharpen == sharpen) {
      return;
    }

    final List<int> missing = <int>[
      for (final int quality in _qualityPresets)
        if (_compressionCache.lookup(algorithm, quality, sharpen) == null)
          quality,
    ];
    final int generation = ++_backgroundGeneration;
    _backgroundAlgorithm = algorithm;
    _backgroundSharpen = sharpen;

    if (missing.isEmpty) {
      if (_backgroundRendering && mounted) {
        setState(() => _backgroundRendering = false);
      }
      return;
    }

    setState(() {
      _backgroundRendering = true;
      _backgroundTotal = _qualityPresets.length;
      _backgroundDone = _qualityPresets.length - missing.length;
    });
    _runBackgroundQuality(source, algorithm, sharpen, missing, generation);
  }

  Future<void> _runBackgroundQuality(
    PickedPhoto source,
    img.Interpolation algorithm,
    SharpenOption sharpen,
    List<int> missing,
    int generation,
  ) async {
    try {
      await _pipeline.processAll(
        source.bytes,
        interpolations: <img.Interpolation>[algorithm],
        qualities: missing,
        sharpen: sharpen,
        onBatch: (List<ResizedPhoto> batch, int completed, int total) {
          if (generation != _backgroundGeneration) {
            return;
          }
          for (final ResizedPhoto photo in batch) {
            _compressionCache.put(photo);
          }
          if (!mounted) {
            return;
          }
          setState(() {
            _backgroundDone =
                (_qualityPresets.length - missing.length) + completed;
            _backendLabel = _pipeline.backendLabel;
          });
        },
      );
    } catch (_) {
      // 后台渲染失败不打扰用户；切换时按需计算兜底。
    } finally {
      if (generation == _backgroundGeneration && mounted) {
        setState(() => _backgroundRendering = false);
      }
    }
  }

  Future<void> _changeInterpolation(img.Interpolation? interpolation) async {
    if (interpolation == null || interpolation == _interpolation) {
      return;
    }
    await _applySettings(interpolation: interpolation);
  }

  Future<void> _changeJpegQuality(int jpegQuality) async {
    if (jpegQuality == _jpegQuality) {
      return;
    }
    await _applySettings(jpegQuality: jpegQuality);
  }

  Future<void> _changeSharpen(SharpenOption sharpen) async {
    if (sharpen == _sharpen) {
      return;
    }
    await _applySettings(sharpen: sharpen);
  }

  /// 应用新的采样算法 / JPEG 质量 / 锐化：保留原界面静默重算，
  /// 渲染完成后直接替换结果照片。
  Future<void> _applySettings({
    img.Interpolation? interpolation,
    int? jpegQuality,
    SharpenOption? sharpen,
  }) async {
    final img.Interpolation nextInterpolation = interpolation ?? _interpolation;
    final int nextQuality = jpegQuality ?? _jpegQuality;
    final SharpenOption nextSharpen = sharpen ?? _sharpen;
    final PickedPhoto? source = _source;
    final bool sharpenChanged = sharpen != null && sharpen != _sharpen;

    if (source == null) {
      setState(() {
        _interpolation = nextInterpolation;
        _jpegQuality = nextQuality;
        if (sharpenChanged) {
          _sharpen = nextSharpen;
        }
      });
      return;
    }
    if (_busy) {
      return;
    }

    final int generation = ++_paramGeneration;
    setState(() {
      _interpolation = nextInterpolation;
      _jpegQuality = nextQuality;
      _sharpen = nextSharpen;
      if (sharpenChanged) {
        _sharpenLocked = true;
      }
    });

    final ResizedPhoto? cached = _compressionCache.lookup(
      nextInterpolation,
      nextQuality,
      nextSharpen,
    );
    if (cached != null) {
      setState(() {
        _result = cached;
        _sharpenLocked = false;
        _backendLabel = _pipeline.backendLabel;
      });
      _startBackgroundQualityRendering(nextInterpolation, nextSharpen);
      return;
    }

    setState(() => _renderingParams = true);
    try {
      final ResizedPhoto resized = await _compressionCache.process(
        source.bytes,
        nextInterpolation,
        nextQuality,
        nextSharpen,
      );
      if (!mounted || generation != _paramGeneration) {
        return;
      }
      setState(() {
        _result = resized;
        _renderingParams = false;
        _sharpenLocked = false;
        _backendLabel = _pipeline.backendLabel;
      });
      _startBackgroundQualityRendering(nextInterpolation, nextSharpen);
    } catch (error) {
      if (!mounted || generation != _paramGeneration) {
        return;
      }
      setState(() {
        _renderingParams = false;
        _sharpenLocked = false;
      });
      _showMessage(_describeError(error));
    }
  }

  /// 强制用当前参数重算（切换 GPU 后端后使用），保留原界面。
  Future<void> _rerenderCurrent() async {
    final PickedPhoto? source = _source;
    if (source == null) {
      return;
    }
    final int generation = ++_paramGeneration;
    setState(() {
      _renderingParams = true;
      _sharpenLocked = true;
    });
    try {
      final ResizedPhoto resized = await _pipeline.processOne(
        source.bytes,
        interpolation: _interpolation,
        jpegQuality: _jpegQuality,
        sharpen: _sharpen,
      );
      _compressionCache.put(resized);
      if (!mounted || generation != _paramGeneration) {
        return;
      }
      setState(() {
        _result = resized;
        _renderingParams = false;
        _sharpenLocked = false;
        _backendLabel = _pipeline.backendLabel;
      });
      _startBackgroundQualityRendering(_interpolation, _sharpen);
    } catch (error) {
      if (!mounted || generation != _paramGeneration) {
        return;
      }
      setState(() {
        _renderingParams = false;
        _sharpenLocked = false;
      });
      _showMessage(_describeError(error));
    }
  }

  /// 打开二级菜单：采样算法、GPU 加速（锐化已放在一级菜单）。
  Future<void> _openSettings() async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (BuildContext context) => _SettingsSheet(
        interpolation: _interpolation,
        useGpu: _pipeline.preferGpu,
        onInterpolationChanged: _changeInterpolation,
        onUseGpuChanged: _setUseGpu,
      ),
    );
  }

  Future<void> _save() async {
    final ResizedPhoto? result = _result;
    if (result == null || _busy) {
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });

    try {
      final PhotoSaveResult? saved = await PhotoSaver.saveJpeg(
        bytes: result.bytes,
        fileName: '${_source?.baseName ?? 'photo'}_compressed',
      );
      if (!mounted) {
        return;
      }
      setState(() => _busy = false);
      if (saved == null) {
        return;
      }
      if (saved.target == PhotoSaveTarget.gallery) {
        _showMessage('已保存到系统相册');
        return;
      }
      final String? location = saved.location;
      if (location != null) {
        _showMessage('已保存：$location');
      }
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() {
        _busy = false;
        _error = _describeError(error);
      });
      _showMessage(_error!);
    }
  }

  String _describeError(Object error) {
    if (error is ImageProcessingException) {
      return error.message;
    }
    if (error is ImagePickException) {
      return error.message;
    }
    if (error is PhotoSaveException) {
      return error.message;
    }
    return '操作失败：$error';
  }

  void _showMessage(String message) {
    if (!mounted) {
      return;
    }
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(content: Text(message), behavior: SnackBarBehavior.floating),
      );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('图压压'),
        actions: <Widget>[
          IconButton(
            tooltip: '渲染设置',
            icon: const Icon(Icons.tune),
            onPressed: _openSettings,
          ),
        ],
      ),
      body: SafeArea(
        child: Padding(padding: const EdgeInsets.all(16), child: _buildBody()),
      ),
      floatingActionButton: _result == null
          ? FloatingActionButton.extended(
              onPressed: (_busy || _picking) ? null : _pickAndProcess,
              icon: const Icon(Icons.add_photo_alternate_outlined),
              label: const Text('选择图片'),
            )
          : null,
    );
  }

  Widget _buildBody() {
    if (_busy) {
      return _BusyView(title: _busyTitle, subtitle: _busySubtitle);
    }

    final ResizedPhoto? result = _result;
    final PickedPhoto? source = _source;
    if (result == null || source == null) {
      final String? error = _error;
      if (error != null) {
        return _ErrorView(message: error, onRetry: _pickAndProcess);
      }
      return const _EmptyView();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_renderingParams) const LinearProgressIndicator(minHeight: 2),
        if (_backgroundRendering)
          _BackgroundProgress(done: _backgroundDone, total: _backgroundTotal),
        Expanded(
          child: ResultView(
            original: source.bytes,
            result: result,
            mode: _mode,
            onModeChanged: (mode) => setState(() => _mode = mode),
            jpegQuality: _jpegQuality,
            onJpegQualityChanged: _changeJpegQuality,
            sharpen: _sharpen,
            onSharpenChanged: _changeSharpen,
            sharpenEnabled: !_sharpenLocked,
            renderBackend: _backendLabel,
            onPickAgain: _pickAndProcess,
            onSave: _save,
          ),
        ),
      ],
    );
  }
}

/// 后台补齐质量档位的进度提示：细进度条 + 计数，不遮挡内容、不阻塞操作。
class _BackgroundProgress extends StatelessWidget {
  const _BackgroundProgress({required this.done, required this.total});

  final int done;
  final int total;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final double ratio = total > 0 ? (done / total).clamp(0.0, 1.0) : 0.0;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(2),
              child: LinearProgressIndicator(value: ratio, minHeight: 4),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '后台渲染 $done/$total',
            style: theme.textTheme.labelSmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

/// 空状态的引导：主操作由右下角的 FAB 承担，这里不再重复放按钮。
class _EmptyView extends StatelessWidget {
  const _EmptyView();

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: colors.primaryContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.photo_library_outlined,
              size: 56,
              color: colors.onPrimaryContainer,
            ),
          ),
          const SizedBox(height: 24),
          Text('还没有选择照片', style: theme.textTheme.titleLarge),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              '点击右下角的按钮选择一张照片，自动缩放到适合朋友圈的尺寸，'
              '并导出体积更小的 JPEG。',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: colors.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _ErrorView extends StatelessWidget {
  const _ErrorView({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Container(
            width: 120,
            height: 120,
            decoration: BoxDecoration(
              color: colors.errorContainer,
              shape: BoxShape.circle,
            ),
            child: Icon(
              Icons.error_outline,
              size: 56,
              color: colors.onErrorContainer,
            ),
          ),
          const SizedBox(height: 24),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 320),
            child: Text(
              message,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyLarge,
            ),
          ),
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: onRetry,
            icon: const Icon(Icons.refresh),
            label: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

class _BusyView extends StatelessWidget {
  const _BusyView({required this.title, required this.subtitle});

  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const CircularProgressIndicator(),
          const SizedBox(height: 24),
          Text(title, style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 360),
            child: Text(
              subtitle,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// 结果页视图：单张结果与左右对比两种模式，公开以便预览和测试。
class ResultView extends StatefulWidget {
  const ResultView({
    super.key,
    required this.original,
    required this.result,
    required this.mode,
    required this.onModeChanged,
    required this.jpegQuality,
    required this.onJpegQualityChanged,
    required this.sharpen,
    required this.onSharpenChanged,
    this.sharpenEnabled = true,
    required this.renderBackend,
    required this.onPickAgain,
    required this.onSave,
  });

  final Uint8List original;
  final ResizedPhoto result;
  final ResultViewMode mode;
  final ValueChanged<ResultViewMode> onModeChanged;
  final int jpegQuality;
  final ValueChanged<int> onJpegQualityChanged;
  final SharpenOption sharpen;
  final ValueChanged<SharpenOption> onSharpenChanged;

  /// 锐化滑条是否可用；渲染进行中会临时冻结。
  final bool sharpenEnabled;

  /// 当前实际使用的渲染后端（GPU / CPU 多核）。
  final String renderBackend;
  final VoidCallback onPickAgain;
  final VoidCallback onSave;

  @override
  State<ResultView> createState() => _ResultViewState();
}

class _ResultViewState extends State<ResultView> {
  final ComparisonController _comparisonController = ComparisonController();

  /// 仅移动端（Android / iOS / iPadOS）提供信息区触控板。
  bool get _isMobilePlatform =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  @override
  void didUpdateWidget(ResultView oldWidget) {
    super.didUpdateWidget(oldWidget);
    // 只有换了一张原图才重置缩放；切换采样算法时保留缩放位置，
    // 方便在同一处细节上对比不同算法。
    if (!identical(widget.original, oldWidget.original)) {
      _comparisonController.reset();
    }
  }

  @override
  void dispose() {
    _comparisonController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget summary = _SizeSummary(
      result: widget.result,
      renderBackend: widget.renderBackend,
    );

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Expanded(child: _buildPreview()),
        const SizedBox(height: 12),
        _buildToolbar(),
        const SizedBox(height: 12),
        if (_isMobilePlatform)
          _PreviewTouchpad(controller: _comparisonController, child: summary)
        else
          summary,
        if (_isMobilePlatform)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: <Widget>[
                Icon(
                  Icons.touch_app_outlined,
                  size: 14,
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
                const SizedBox(width: 4),
                Text(
                  '信息区可拖动 / 双指缩放照片',
                  style: Theme.of(context).textTheme.labelSmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        const SizedBox(height: 12),
        Row(
          children: <Widget>[
            Expanded(
              child: OutlinedButton.icon(
                onPressed: widget.onPickAgain,
                icon: const Icon(Icons.refresh),
                label: const Text('换一张'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: FilledButton.icon(
                onPressed: widget.onSave,
                icon: const Icon(Icons.save_alt),
                label: const Text('保存图片'),
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPreview() {
    if (widget.mode == ResultViewMode.compare) {
      return ComparisonView(
        original: widget.original,
        processed: widget.result.bytes,
        controller: _comparisonController,
      );
    }
    return SinglePhotoView(
      bytes: widget.result.bytes,
      controller: _comparisonController,
    );
  }

  Widget _buildToolbar() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          alignment: WrapAlignment.spaceBetween,
          crossAxisAlignment: WrapCrossAlignment.center,
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            SegmentedButton<ResultViewMode>(
              segments: const <ButtonSegment<ResultViewMode>>[
                ButtonSegment<ResultViewMode>(
                  value: ResultViewMode.result,
                  label: Text('结果'),
                ),
                ButtonSegment<ResultViewMode>(
                  value: ResultViewMode.compare,
                  label: Text('对比'),
                ),
              ],
              selected: <ResultViewMode>{widget.mode},
              showSelectedIcon: false,
              onSelectionChanged: (Set<ResultViewMode> selection) {
                widget.onModeChanged(selection.first);
              },
            ),
            ComparisonZoomBar(controller: _comparisonController),
          ],
        ),
        const SizedBox(height: 4),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final Widget qualitySlider = _QualitySlider(
              quality: widget.jpegQuality,
              onChanged: widget.onJpegQualityChanged,
            );
            final Widget sharpenSlider = _SharpenSlider(
              sharpen: widget.sharpen,
              enabled: widget.sharpenEnabled,
              onChanged: widget.onSharpenChanged,
            );
            // 宽屏时两个滑条并排，窄屏时上下排列。
            if (constraints.maxWidth >= 640) {
              return Row(
                children: <Widget>[
                  Expanded(child: qualitySlider),
                  const SizedBox(width: 16),
                  Expanded(child: sharpenSlider),
                ],
              );
            }
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                qualitySlider,
                const SizedBox(height: 4),
                sharpenSlider,
              ],
            );
          },
        ),
      ],
    );
  }
}

/// JPEG 质量滑条：吸附到 60 / 75 / 85 / 95 四个推荐档位。
///
/// 拖动时只更新本地显示，松手（[Slider.onChangeEnd]）后才触发渲染，
/// 避免拖动过程中反复重算。
class _QualitySlider extends StatefulWidget {
  const _QualitySlider({required this.quality, required this.onChanged});

  final int quality;
  final ValueChanged<int> onChanged;

  @override
  State<_QualitySlider> createState() => _QualitySliderState();
}

class _QualitySliderState extends State<_QualitySlider> {
  late int _index = _nearestQualityIndex(widget.quality);

  @override
  void didUpdateWidget(_QualitySlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.quality != widget.quality) {
      _index = _nearestQualityIndex(widget.quality);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final int current = _qualityPresets[_index];

    return Row(
      children: <Widget>[
        Text(
          'JPEG 质量',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Slider(
                key: const ValueKey<String>('quality-slider'),
                value: _index.toDouble(),
                min: 0,
                max: (_qualityPresets.length - 1).toDouble(),
                divisions: _qualityPresets.length - 1,
                label: '$current%',
                onChanged: (double value) {
                  final int nextIndex = value.round();
                  if (nextIndex != _index) {
                    setState(() => _index = nextIndex);
                  }
                },
                onChangeEnd: (double value) {
                  final int next = _qualityPresets[value.round()];
                  if (next != widget.quality) {
                    widget.onChanged(next);
                  }
                },
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: _qualityPresets
                      .map(
                        (int preset) => Text(
                          '$preset',
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: theme.colorScheme.onSurfaceVariant,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: Text(
            '$current%',
            textAlign: TextAlign.right,
            style: theme.textTheme.labelLarge,
          ),
        ),
      ],
    );
  }
}

/// 锐化滑条：关闭 / 轻度 / 标准 / 强。
///
/// 拖动时只更新本地显示，松手后才触发渲染；渲染进行中滑条会被冻结
/// （[enabled] 为 false），避免连续提交过多渲染作业。
class _SharpenSlider extends StatefulWidget {
  const _SharpenSlider({
    required this.sharpen,
    required this.onChanged,
    this.enabled = true,
  });

  final SharpenOption sharpen;
  final ValueChanged<SharpenOption> onChanged;
  final bool enabled;

  @override
  State<_SharpenSlider> createState() => _SharpenSliderState();
}

class _SharpenSliderState extends State<_SharpenSlider> {
  late int _index = widget.sharpen.index;

  @override
  void didUpdateWidget(_SharpenSlider oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.sharpen != widget.sharpen) {
      _index = widget.sharpen.index;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final Color muted = theme.colorScheme.onSurfaceVariant;
    final SharpenOption current = SharpenOption.values[_index];

    return Row(
      children: <Widget>[
        Text('锐化', style: theme.textTheme.labelLarge?.copyWith(color: muted)),
        Expanded(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Slider(
                key: const ValueKey<String>('sharpen-slider'),
                value: _index.toDouble(),
                min: 0,
                max: (SharpenOption.values.length - 1).toDouble(),
                divisions: SharpenOption.values.length - 1,
                label: current.label,
                onChanged: widget.enabled
                    ? (double value) {
                        final int nextIndex = value.round();
                        if (nextIndex != _index) {
                          setState(() => _index = nextIndex);
                        }
                      }
                    : null,
                onChangeEnd: widget.enabled
                    ? (double value) {
                        final SharpenOption next =
                            SharpenOption.values[value.round()];
                        if (next != widget.sharpen) {
                          widget.onChanged(next);
                        }
                      }
                    : null,
              ),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: SharpenOption.values
                      .map(
                        (SharpenOption option) => Text(
                          option.label,
                          style: theme.textTheme.labelSmall?.copyWith(
                            color: muted,
                          ),
                        ),
                      )
                      .toList(),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        SizedBox(
          width: 48,
          child: Text(
            current.label,
            textAlign: TextAlign.right,
            style: theme.textTheme.labelLarge,
          ),
        ),
      ],
    );
  }
}

/// 二级菜单：采样算法、GPU 加速（锐化已放到一级菜单）。
class _SettingsSheet extends StatefulWidget {
  const _SettingsSheet({
    required this.interpolation,
    required this.useGpu,
    required this.onInterpolationChanged,
    required this.onUseGpuChanged,
  });

  final img.Interpolation interpolation;
  final bool useGpu;
  final ValueChanged<img.Interpolation?> onInterpolationChanged;
  final ValueChanged<bool> onUseGpuChanged;

  @override
  State<_SettingsSheet> createState() => _SettingsSheetState();
}

class _SettingsSheetState extends State<_SettingsSheet> {
  late img.Interpolation _interpolation = widget.interpolation;
  late bool _useGpu = widget.useGpu;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text('渲染设置', style: theme.textTheme.titleLarge),
            const SizedBox(height: 16),
            // 分组标题在左、下拉框在右，与下方的 GPU 开关排版一致。
            Row(
              children: <Widget>[
                Text('采样算法', style: theme.textTheme.bodyLarge),
                const Spacer(),
                DropdownMenu<img.Interpolation>(
                  initialSelection: _interpolation,
                  width: 168,
                  textStyle: theme.textTheme.bodyMedium,
                  dropdownMenuEntries: _interpolationEntries,
                  onSelected: (img.Interpolation? value) {
                    if (value == null || value == _interpolation) {
                      return;
                    }
                    setState(() => _interpolation = value);
                    widget.onInterpolationChanged(value);
                  },
                ),
              ],
            ),
            const SizedBox(height: 16),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('GPU 加速（可用时）'),
              subtitle: const Text('不可用时自动回退到多核 CPU 渲染'),
              value: _useGpu,
              onChanged: (bool value) {
                setState(() => _useGpu = value);
                widget.onUseGpuChanged(value);
              },
            ),
          ],
        ),
      ),
    );
  }
}

class _SizeSummary extends StatelessWidget {
  const _SizeSummary({required this.result, required this.renderBackend});

  final ResizedPhoto result;
  final String renderBackend;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final ColorScheme colors = theme.colorScheme;
    final double changePercent = result.sizeChange * 100;
    final bool smaller = changePercent < 0;

    final String changeText;
    if (changePercent.abs() < 0.05) {
      changeText = '体积基本不变';
    } else if (smaller) {
      changeText = '体积减少 ${(-changePercent).toStringAsFixed(1)}%';
    } else {
      changeText = '体积增加 ${changePercent.toStringAsFixed(1)}%';
    }

    return Card.filled(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _InfoRow(
              label: '原图',
              value:
                  '${result.originalWidth} × ${result.originalHeight} · '
                  '${_formatBytes(result.originalBytes)}',
            ),
            const SizedBox(height: 8),
            _InfoRow(
              label: '压缩后',
              value:
                  '${result.width} × ${result.height} · '
                  '${_formatBytes(result.size)}',
            ),
            const SizedBox(height: 8),
            _InfoRow(
              label: '体积变化',
              value: changeText,
              valueColor: smaller ? colors.primary : colors.error,
            ),
            const SizedBox(height: 8),
            _InfoRow(label: '导出格式', value: 'JPEG · 质量 ${result.jpegQuality}%'),
            const SizedBox(height: 8),
            _InfoRow(label: '渲染方式', value: renderBackend),
            if (result.keepsSize) ...<Widget>[
              const SizedBox(height: 12),
              Text(
                '这张图已经在尺寸限制之内，只重新编码为 JPEG 来减小体积。',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: colors.onSurfaceVariant,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value, this.valueColor});

  final String label;
  final String value;
  final Color? valueColor;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 80,
          child: Text(
            label,
            style: theme.textTheme.labelMedium?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: theme.textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w600,
              color: valueColor,
            ),
          ),
        ),
      ],
    );
  }
}

/// 移动端「触控板」：把下方信息区的拖动 / 双指捏合转发给预览的缩放状态。
///
/// 单指拖动 = 平移，双指捏合 = 缩放，操作的是上方的结果照片。
class _PreviewTouchpad extends StatefulWidget {
  const _PreviewTouchpad({required this.controller, required this.child});

  final ComparisonController controller;
  final Widget child;

  @override
  State<_PreviewTouchpad> createState() => _PreviewTouchpadState();
}

class _PreviewTouchpadState extends State<_PreviewTouchpad> {
  double _lastGestureScale = 1;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      key: const ValueKey<String>('preview-touchpad'),
      behavior: HitTestBehavior.opaque,
      onScaleStart: (ScaleStartDetails details) {
        _lastGestureScale = 1;
      },
      onScaleUpdate: (ScaleUpdateDetails details) {
        // details.scale 是相对手势起点的累计缩放，这里换算成增量。
        final double factor = details.scale / _lastGestureScale;
        _lastGestureScale = details.scale;
        if ((factor - 1).abs() > 0.001) {
          widget.controller.zoomBy(factor);
        }
        if (details.focalPointDelta != Offset.zero) {
          widget.controller.panBy(details.focalPointDelta);
        }
      },
      child: widget.child,
    );
  }
}

String _formatBytes(int bytes) {
  const int kb = 1024;
  const int mb = kb * 1024;
  if (bytes >= mb) {
    return '${(bytes / mb).toStringAsFixed(2)} MB';
  }
  if (bytes >= kb) {
    return '${(bytes / kb).toStringAsFixed(1)} KB';
  }
  return '$bytes B';
}
