import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'gpu_image_processor.dart';
import 'image_resizer.dart';
import 'sharpen_option.dart';

/// 实际参与渲染的后端。
enum ImageBackend {
  /// Flutter 引擎 GPU 光栅化（解码 + 缩放）。
  gpu,

  /// 纯 CPU 多 isolate 实现。
  cpu,
}

/// 批量渲染函数签名，便于测试时注入替身。
typedef BatchProcessor =
    Future<List<ResizedPhoto>> Function(
      Uint8List input, {
      List<img.Interpolation>? interpolations,
      List<int>? qualities,
      SharpenOption sharpen,
      void Function(List<ResizedPhoto> batch, int completed, int total)?
      onBatch,
    });

/// 选择 GPU / CPU 后端的图片渲染管线。
///
/// 优先使用 GPU：解码和缩放由 Flutter 引擎完成；JPEG 编码仍走多核 CPU
/// isolate。如果 GPU 路径不可用或中途失败，会自动回退到纯 CPU 多核实现，
/// 并通过 [onGpuFallback] 通知界面。用户也可以通过 [preferGpu] 主动关闭
/// GPU 加速。
class ImagePipeline {
  ImagePipeline({
    ResizeConstraints constraints = const ResizeConstraints(),
    BatchProcessor? gpuBatch,
    BatchProcessor? cpuBatch,
    this.onGpuFallback,
    this.preferGpu = true,
  }) : _gpu =
           gpuBatch ?? GpuImageProcessor(constraints: constraints).processAll,
       _cpu = cpuBatch ?? ImageResizer(constraints: constraints).processAll;

  final BatchProcessor _gpu;
  final BatchProcessor _cpu;

  /// GPU 失败并回退到 CPU 时回调（只回调一次，避免重复提示）。
  final VoidCallback? onGpuFallback;

  /// 是否优先使用 GPU（用户可以在界面上关闭）。
  bool preferGpu;

  bool _gpuUnavailable = false;
  bool _fallbackNotified = false;
  ImageBackend _lastBackend = ImageBackend.cpu;

  /// GPU 当前是否实际可用（已启用且未失败过）。
  bool get gpuActive => preferGpu && !_gpuUnavailable;

  /// GPU 是否因为失败被禁用。
  bool get gpuUnavailable => _gpuUnavailable;

  /// 最近一次渲染实际使用的后端。
  ImageBackend get lastBackend => _lastBackend;

  String get backendLabel =>
      _lastBackend == ImageBackend.gpu ? 'GPU 加速' : 'CPU 多核';

  /// 用户重新开启 GPU 加速时，允许再次尝试。
  void resetGpuAvailability() {
    _gpuUnavailable = false;
    _fallbackNotified = false;
  }

  /// 批量渲染；GPU 失败时自动回退 CPU。
  Future<List<ResizedPhoto>> processAll(
    Uint8List input, {
    List<img.Interpolation>? interpolations,
    List<int>? qualities,
    SharpenOption sharpen = SharpenOption.none,
    void Function(List<ResizedPhoto> batch, int completed, int total)? onBatch,
  }) async {
    if (gpuActive) {
      try {
        final List<ResizedPhoto> results = await _gpu(
          input,
          interpolations: interpolations,
          qualities: qualities,
          sharpen: sharpen,
          onBatch: onBatch,
        );
        _lastBackend = ImageBackend.gpu;
        return results;
      } catch (_) {
        _gpuUnavailable = true;
        if (!_fallbackNotified) {
          _fallbackNotified = true;
          onGpuFallback?.call();
        }
      }
    }

    _lastBackend = ImageBackend.cpu;
    return _cpu(
      input,
      interpolations: interpolations,
      qualities: qualities,
      sharpen: sharpen,
      onBatch: onBatch,
    );
  }

  /// 只渲染一个「算法 + 质量 + 锐化」组合。
  Future<ResizedPhoto> processOne(
    Uint8List input, {
    required img.Interpolation interpolation,
    required int jpegQuality,
    SharpenOption sharpen = SharpenOption.none,
  }) async {
    final List<ResizedPhoto> results = await processAll(
      input,
      interpolations: <img.Interpolation>[interpolation],
      qualities: <int>[jpegQuality],
      sharpen: sharpen,
    );
    if (results.isEmpty) {
      throw const ImageProcessingException('没有生成任何可用的压缩结果。');
    }
    return results.first;
  }
}
