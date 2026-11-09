import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'image_resizer.dart';
import 'sharpen_option.dart';

/// 缓存键：采样算法 + JPEG 质量 + 锐化。
typedef CompressionKey = ({
  img.Interpolation interpolation,
  int jpegQuality,
  SharpenOption sharpen,
});

/// 内存中的压缩结果缓存。
///
/// 同一张原图按「采样算法 + JPEG 质量 + 锐化」缓存压缩结果：调整参数时先查
/// 缓存，来回切换直接复用，不会重复解码、缩放和编码；换一张原图时调用
/// [clear]。
class CompressionCache {
  CompressionCache({required this.compress});

  /// 实际执行压缩的函数，便于替换和测试。
  final Future<ResizedPhoto> Function(
    Uint8List bytes,
    img.Interpolation interpolation,
    int jpegQuality,
    SharpenOption sharpen,
  )
  compress;

  final Map<CompressionKey, ResizedPhoto> _results =
      <CompressionKey, ResizedPhoto>{};

  /// 当前已缓存的结果数量。
  int get cachedCount => _results.length;

  /// 查找指定参数组合的缓存结果，没有则返回 `null`。
  ResizedPhoto? lookup(
    img.Interpolation interpolation,
    int jpegQuality,
    SharpenOption sharpen,
  ) =>
      _results[(
        interpolation: interpolation,
        jpegQuality: jpegQuality,
        sharpen: sharpen,
      )];

  /// 返回指定参数组合的压缩结果：命中缓存直接返回，否则计算并缓存。
  Future<ResizedPhoto> process(
    Uint8List bytes,
    img.Interpolation interpolation,
    int jpegQuality,
    SharpenOption sharpen,
  ) async {
    final CompressionKey key = (
      interpolation: interpolation,
      jpegQuality: jpegQuality,
      sharpen: sharpen,
    );
    final ResizedPhoto? cached = _results[key];
    if (cached != null) {
      return cached;
    }
    final ResizedPhoto result = await compress(
      bytes,
      interpolation,
      jpegQuality,
      sharpen,
    );
    _results[key] = result;
    return result;
  }

  /// 写入一条已经计算好的结果（例如后台渲染的产物）。
  void put(ResizedPhoto result) {
    _results[(
          interpolation: result.interpolation,
          jpegQuality: result.jpegQuality,
          sharpen: result.sharpen,
        )] =
        result;
  }

  /// 清空缓存（例如换了一张原图）。
  void clear() => _results.clear();
}
