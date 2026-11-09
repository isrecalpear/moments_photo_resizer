import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'sharpen_option.dart';

/// 图片缩放的尺寸约束。
///
/// 同时限制「总像素量」和「短边」：总像素量不超过 [maxPixels]，
/// 短边保证图片在手机上显示时仍然清晰。
@immutable
class ResizeConstraints {
  const ResizeConstraints({this.maxPixels = 10240000, this.maxShortSide = 1920})
    : assert(maxPixels > 0),
      assert(maxShortSide > 0);

  /// 总像素量上限，默认 10,240,000（约 1024 万像素）。
  final int maxPixels;

  /// 短边的像素上限。
  final int maxShortSide;
}

/// 计算得到的目标尺寸。
@immutable
class ResizePlan {
  const ResizePlan({
    required this.width,
    required this.height,
    required this.resized,
  });

  final int width;
  final int height;

  /// 是否真的需要缩放；`false` 表示原图已经在限制之内。
  final bool resized;

  @override
  String toString() => 'ResizePlan(${width}x$height, resized: $resized)';
}

/// 处理失败时抛出，[message] 可以直接展示给用户。
class ImageProcessingException implements Exception {
  const ImageProcessingException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 压缩结果。
@immutable
class ResizedPhoto {
  const ResizedPhoto({
    required this.bytes,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
    required this.originalBytes,
    required this.interpolation,
    required this.jpegQuality,
    required this.sharpen,
  });

  /// 编码后的 JPEG 字节。
  final Uint8List bytes;

  final int width;
  final int height;

  /// 摆正 EXIF 方向之后的原图尺寸。
  final int originalWidth;
  final int originalHeight;

  /// 原图字节数。
  final int originalBytes;

  /// 生成这张结果时使用的采样算法。
  final img.Interpolation interpolation;

  /// 输出 JPEG 使用的质量（1-100）。
  final int jpegQuality;

  /// 缩放后应用的锐化强度。
  final SharpenOption sharpen;

  int get size => bytes.length;

  /// 体积变化比例：负数表示变小，正数表示变大。
  double get sizeChange {
    if (originalBytes <= 0) {
      return 0;
    }
    return (bytes.length - originalBytes) / originalBytes;
  }

  bool get isSmaller => bytes.length < originalBytes;

  /// 是否保持了原图尺寸（即没有发生缩放）。
  bool get keepsSize => width == originalWidth && height == originalHeight;
}

/// 把任意常见格式的图片解码、按约束缩放并重新编码为 JPEG。
///
/// 缩放计算在后台 isolate 中执行，避免阻塞 UI。
class ImageResizer {
  const ImageResizer({
    this.constraints = const ResizeConstraints(),
    this.jpegQuality = 100,
    this.interpolation = img.Interpolation.average,
  }) : assert(jpegQuality >= 1 && jpegQuality <= 100);

  final ResizeConstraints constraints;
  final int jpegQuality;

  /// 缩放时使用的插值方式，默认 `average` 以保证缩小后的画质。
  final img.Interpolation interpolation;

  /// 计算目标尺寸。纯函数，方便单独测试。
  ///
  /// 只缩小、不放大：原图已经在限制之内时原样返回。缩放比例向下取整，
  /// 保证输出的总像素量不会超过 [maxPixels]。
  static ResizePlan planResize(
    int width,
    int height, {
    int maxPixels = 10240000,
    int maxShortSide = 1920,
  }) {
    if (width <= 0 || height <= 0) {
      throw ArgumentError('图片宽高必须为正数，实际收到 ${width}x$height');
    }
    if (maxPixels <= 0 || maxShortSide <= 0) {
      throw ArgumentError('缩放上限必须为正数');
    }

    final double scaleByPixels = math.sqrt(maxPixels / (width * height));
    final double scaleByShortSide = maxShortSide / math.min(width, height);
    final double scale = math.min(scaleByPixels, scaleByShortSide);

    if (scale >= 1.0) {
      return ResizePlan(width: width, height: height, resized: false);
    }

    final int newWidth = math.max(1, (width * scale).floor());
    final int newHeight = math.max(1, (height * scale).floor());
    return ResizePlan(
      width: newWidth,
      height: newHeight,
      resized: newWidth != width || newHeight != height,
    );
  }

  /// 在后台 isolate 中处理图片。
  Future<ResizedPhoto> process(
    Uint8List input, {
    SharpenOption sharpen = SharpenOption.none,
  }) {
    return compute(_process, _argumentsFor(input, sharpen));
  }

  /// 同步处理，供测试或已经处于后台 isolate 的场景使用。
  ResizedPhoto processSync(
    Uint8List input, {
    SharpenOption sharpen = SharpenOption.none,
  }) => _process(_argumentsFor(input, sharpen));

  /// 一次性预渲染同一张原图在多种采样算法与 JPEG 质量下的所有结果。
  ///
  /// 充分利用多核：每种采样算法在独立 isolate 中并行处理，一次解码即可
  /// 产出该算法下的全部质量档位；原图无需缩小时只有一个 isolate 编码所有
  /// 质量，再复用到各采样算法。并发数会根据源图像素量自动限制，避免大图
  /// 同时解码占满内存。
  ///
  /// 每批结果完成时回调 [onBatch]（已完成的组合数 / 总数），调用方可以据此
  /// 增量写入缓存并刷新进度条。
  Future<List<ResizedPhoto>> processAll(
    Uint8List input, {
    List<img.Interpolation>? interpolations,
    List<int>? qualities,
    SharpenOption sharpen = SharpenOption.none,
    void Function(List<ResizedPhoto> batch, int completed, int total)? onBatch,
  }) async {
    final List<img.Interpolation> algorithms =
        interpolations ?? img.Interpolation.values;
    final List<int> qualityList = qualities ?? const <int>[75, 85, 95, 100];
    if (algorithms.isEmpty || qualityList.isEmpty) {
      return <ResizedPhoto>[];
    }

    final int total = algorithms.length * qualityList.length;
    int completed = 0;
    final List<ResizedPhoto> results = <ResizedPhoto>[];

    final (int, int)? sourceSize = _probeSize(input);
    final int? pixels = sourceSize == null
        ? null
        : sourceSize.$1 * sourceSize.$2;
    final bool needsResize = sourceSize == null
        ? true
        : planResize(
            sourceSize.$1,
            sourceSize.$2,
            maxPixels: constraints.maxPixels,
            maxShortSide: constraints.maxShortSide,
          ).resized;

    try {
      // 无需缩放时采样算法不起作用：只解码一次，编码所有质量后复用。
      if (!needsResize) {
        final _BatchResult batch = await compute(
          _qualityBatch,
          _batchArguments(
            input,
            img.Interpolation.average.index,
            qualityList,
            sharpen,
          ),
        );
        final List<ResizedPhoto> photos = <ResizedPhoto>[
          for (final img.Interpolation algorithm in algorithms)
            for (int i = 0; i < batch.encoded.length; i++)
              batch.toPhoto(algorithm, i, sharpen),
        ];
        results.addAll(photos);
        onBatch?.call(photos, photos.length, total);
        return results;
      }

      final int concurrency = _concurrencyForPixels(pixels);
      for (int start = 0; start < algorithms.length; start += concurrency) {
        final List<img.Interpolation> chunk = algorithms
            .skip(start)
            .take(concurrency)
            .toList();
        final List<Future<_BatchResult>> pending = <Future<_BatchResult>>[
          for (final img.Interpolation algorithm in chunk)
            compute(
              _algorithmBatch,
              _batchArguments(input, algorithm.index, qualityList, sharpen),
            ),
        ];

        // 按完成顺序回收，便于实时汇报进度。
        while (pending.isNotEmpty) {
          final int index = await Future.any(<Future<int>>[
            for (int i = 0; i < pending.length; i++)
              pending[i].then<int>(
                (_) => i,
                onError: (Object error, StackTrace stackTrace) => i,
              ),
          ]);
          final _BatchResult batch = await pending.removeAt(index);
          final List<ResizedPhoto> photos = <ResizedPhoto>[
            for (int i = 0; i < batch.encoded.length; i++)
              batch.toPhoto(batch.interpolation, i, sharpen),
          ];
          results.addAll(photos);
          completed += photos.length;
          onBatch?.call(photos, completed, total);
        }
      }
      return results;
    } on ImageProcessingException {
      rethrow;
    } catch (error) {
      throw ImageProcessingException('图片处理失败：$error');
    }
  }

  List<Object?> _batchArguments(
    Uint8List input,
    int interpolationIndex,
    List<int> qualities,
    SharpenOption sharpen,
  ) => <Object?>[
    input,
    interpolationIndex,
    constraints.maxPixels,
    constraints.maxShortSide,
    List<int>.of(qualities),
    sharpen.index,
  ];

  /// 只读取图片头信息里的宽高，不解码像素。
  static (int, int)? _probeSize(Uint8List input) {
    try {
      final img.Decoder? decoder = img.findDecoderForData(input);
      final img.DecodeInfo? info = decoder?.startDecode(input);
      if (info == null || info.width <= 0 || info.height <= 0) {
        return null;
      }
      return (info.width, info.height);
    } catch (_) {
      return null;
    }
  }

  /// 根据像素量限制并行解码的 isolate 数量，避免同时占用过多内存。
  static int _concurrencyForPixels(int? pixels) {
    if (pixels == null) {
      return 2;
    }
    if (pixels > 24000000) {
      return 1;
    }
    if (pixels > 12000000) {
      return 2;
    }
    return 4;
  }

  static _BatchResult _algorithmBatch(List<Object?> args) {
    try {
      return _runBatch(args, resize: true);
    } on ImageProcessingException {
      rethrow;
    } catch (error) {
      throw ImageProcessingException('图片处理失败：$error');
    }
  }

  static _BatchResult _qualityBatch(List<Object?> args) {
    try {
      return _runBatch(args, resize: false);
    } on ImageProcessingException {
      rethrow;
    } catch (error) {
      throw ImageProcessingException('图片处理失败：$error');
    }
  }

  static _BatchResult _runBatch(List<Object?> args, {required bool resize}) {
    final Uint8List input = args[0] as Uint8List;
    final int interpolationIndex = args[1] as int;
    final int maxPixels = args[2] as int;
    final int maxShortSide = args[3] as int;
    final List<int> qualities = (args[4] as List<Object?>).cast<int>();
    final SharpenOption sharpen = SharpenOption.values[args[5] as int];

    final img.Image? decoded = _decode(input);
    if (decoded == null) {
      throw const ImageProcessingException(
        '无法识别这张图片，请换一张 JPG / PNG / WebP 格式的照片。',
      );
    }

    final img.Image oriented = img.bakeOrientation(decoded);
    final img.Interpolation interpolation =
        img.Interpolation.values[interpolationIndex];
    final ResizePlan plan = planResize(
      oriented.width,
      oriented.height,
      maxPixels: maxPixels,
      maxShortSide: maxShortSide,
    );
    final img.Image resized = resize && plan.resized
        ? img.copyResize(
            oriented,
            width: plan.width,
            height: plan.height,
            interpolation: interpolation,
          )
        : oriented;
    final img.Image target = applySharpen(resized, sharpen);

    return _BatchResult(
      interpolation: interpolation,
      width: target.width,
      height: target.height,
      originalWidth: oriented.width,
      originalHeight: oriented.height,
      originalBytes: input.length,
      qualities: qualities,
      encoded: <Uint8List>[
        for (final int quality in qualities)
          img.encodeJpg(
            target,
            quality: quality,
            chroma: img.JpegChroma.yuv420,
          ),
      ],
    );
  }

  List<Object?> _argumentsFor(Uint8List input, SharpenOption sharpen) =>
      <Object?>[
        input,
        constraints.maxPixels,
        constraints.maxShortSide,
        jpegQuality,
        interpolation.index,
        sharpen.index,
      ];

  static ResizedPhoto _process(List<Object?> args) {
    try {
      return _resize(args);
    } on ImageProcessingException {
      rethrow;
    } catch (error) {
      throw ImageProcessingException('图片处理失败：$error');
    }
  }

  /// 解码失败时统一返回 `null`；底层解码器遇到损坏数据可能抛异常，
  /// 这里一并吞掉并交给调用方转换成友好提示。
  static img.Image? _decode(Uint8List input) {
    try {
      return img.decodeImage(input);
    } catch (_) {
      return null;
    }
  }

  static ResizedPhoto _resize(List<Object?> args) {
    final Uint8List input = args[0] as Uint8List;
    final int maxPixels = args[1] as int;
    final int maxShortSide = args[2] as int;
    final int jpegQuality = args[3] as int;
    final img.Interpolation interpolation =
        img.Interpolation.values[args[4] as int];
    final SharpenOption sharpen = SharpenOption.values[args[5] as int];

    final img.Image? decoded = _decode(input);
    if (decoded == null) {
      throw const ImageProcessingException(
        '无法识别这张图片，请换一张 JPG / PNG / WebP 格式的照片。',
      );
    }

    // 按 EXIF 方向把像素摆正，否则竖拍的照片导出后会躺倒。
    final img.Image oriented = img.bakeOrientation(decoded);
    final ResizePlan plan = planResize(
      oriented.width,
      oriented.height,
      maxPixels: maxPixels,
      maxShortSide: maxShortSide,
    );

    final img.Image resized = plan.resized
        ? img.copyResize(
            oriented,
            width: plan.width,
            height: plan.height,
            interpolation: interpolation,
          )
        : oriented;
    final img.Image target = applySharpen(resized, sharpen);

    final Uint8List bytes = img.encodeJpg(
      target,
      quality: jpegQuality,
      chroma: img.JpegChroma.yuv420,
    );

    return ResizedPhoto(
      bytes: bytes,
      width: target.width,
      height: target.height,
      originalWidth: oriented.width,
      originalHeight: oriented.height,
      originalBytes: input.length,
      interpolation: interpolation,
      jpegQuality: jpegQuality,
      sharpen: sharpen,
    );
  }
}

/// 一个 isolate 产出的「某种采样算法下的全部质量档位」结果。
@immutable
class _BatchResult {
  const _BatchResult({
    required this.interpolation,
    required this.width,
    required this.height,
    required this.originalWidth,
    required this.originalHeight,
    required this.originalBytes,
    required this.qualities,
    required this.encoded,
  });

  final img.Interpolation interpolation;
  final int width;
  final int height;
  final int originalWidth;
  final int originalHeight;
  final int originalBytes;
  final List<int> qualities;
  final List<Uint8List> encoded;

  ResizedPhoto toPhoto(
    img.Interpolation algorithm,
    int index,
    SharpenOption sharpen,
  ) {
    return ResizedPhoto(
      bytes: encoded[index],
      width: width,
      height: height,
      originalWidth: originalWidth,
      originalHeight: originalHeight,
      originalBytes: originalBytes,
      interpolation: algorithm,
      jpegQuality: qualities[index],
      sharpen: sharpen,
    );
  }
}
