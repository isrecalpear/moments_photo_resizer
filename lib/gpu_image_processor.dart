import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:image/image.dart' as img;

import 'image_resizer.dart';
import 'sharpen_option.dart';

/// GPU 加速的图片处理器。
///
/// 解码与缩放交给 Flutter 引擎（Impeller / Skia）在 GPU 上完成，
/// JPEG 编码仍然交给多核 CPU isolate。任何一步失败（例如平台没有
/// 可用的 GPU 光栅化）都会抛出异常，由 `ImagePipeline` 自动回退到
/// 纯 CPU 多核实现。
class GpuImageProcessor {
  const GpuImageProcessor({this.constraints = const ResizeConstraints()});

  final ResizeConstraints constraints;

  /// 与 [ImageResizer.processAll] 相同的批量接口。
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

    final ui.Image source = await _decode(input);
    try {
      final int originalWidth = source.width;
      final int originalHeight = source.height;
      final ResizePlan plan = ImageResizer.planResize(
        originalWidth,
        originalHeight,
        maxPixels: constraints.maxPixels,
        maxShortSide: constraints.maxShortSide,
      );
      final int total = algorithms.length * qualityList.length;

      // 无需缩放：采样算法不起作用，只读一次像素、编码所有质量后复用。
      if (!plan.resized) {
        final Uint8List rgba = _bytesFromData(
          await source.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
        final _EncodedBatch encoded = await compute(_encodeBatch, <Object?>[
          rgba,
          originalWidth,
          originalHeight,
          List<int>.of(qualityList),
          sharpen.index,
        ]);
        final List<ResizedPhoto> photos = <ResizedPhoto>[
          for (final img.Interpolation algorithm in algorithms)
            for (int i = 0; i < encoded.qualities.length; i++)
              encoded.toPhoto(
                algorithm,
                i,
                originalWidth,
                originalHeight,
                input.length,
                sharpen,
              ),
        ];
        onBatch?.call(photos, photos.length, total);
        return photos;
      }

      // 逐个算法在 GPU 上缩放并读回像素，再并行交给 CPU isolate 编码。
      final List<Future<_AlgorithmBatch>> pending = <Future<_AlgorithmBatch>>[];
      for (final img.Interpolation algorithm in algorithms) {
        final Uint8List rgba = await _renderScaled(
          source,
          plan.width,
          plan.height,
          _filterQuality(algorithm),
        );
        pending.add(
          compute(_encodeBatch, <Object?>[
            rgba,
            plan.width,
            plan.height,
            List<int>.of(qualityList),
            sharpen.index,
          ]).then(
            (_EncodedBatch encoded) =>
                _AlgorithmBatch(algorithm: algorithm, encoded: encoded),
          ),
        );
      }

      final List<ResizedPhoto> results = <ResizedPhoto>[];
      int completed = 0;
      while (pending.isNotEmpty) {
        final int index = await Future.any(<Future<int>>[
          for (int i = 0; i < pending.length; i++)
            pending[i].then<int>(
              (_) => i,
              onError: (Object error, StackTrace stackTrace) => i,
            ),
        ]);
        final _AlgorithmBatch batch = await pending.removeAt(index);
        final List<ResizedPhoto> photos = <ResizedPhoto>[
          for (int i = 0; i < batch.encoded.qualities.length; i++)
            batch.encoded.toPhoto(
              batch.algorithm,
              i,
              originalWidth,
              originalHeight,
              input.length,
              sharpen,
            ),
        ];
        results.addAll(photos);
        completed += photos.length;
        onBatch?.call(photos, completed, total);
      }
      return results;
    } finally {
      source.dispose();
    }
  }

  static Future<ui.Image> _decode(Uint8List input) async {
    final ui.Codec codec = await ui.instantiateImageCodec(input);
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec.dispose();
    }
  }

  /// 用 Canvas 在 GPU 上把原图缩放到目标尺寸，再读回 RGBA 像素。
  static Future<Uint8List> _renderScaled(
    ui.Image source,
    int width,
    int height,
    ui.FilterQuality filterQuality,
  ) async {
    final ui.PictureRecorder recorder = ui.PictureRecorder();
    final ui.Canvas canvas = ui.Canvas(recorder);
    canvas.drawImageRect(
      source,
      ui.Rect.fromLTWH(0, 0, source.width.toDouble(), source.height.toDouble()),
      ui.Rect.fromLTWH(0, 0, width.toDouble(), height.toDouble()),
      ui.Paint()
        ..filterQuality = filterQuality
        ..isAntiAlias = true,
    );
    final ui.Picture picture = recorder.endRecording();
    try {
      final ui.Image scaled = await picture.toImage(width, height);
      try {
        return _bytesFromData(
          await scaled.toByteData(format: ui.ImageByteFormat.rawRgba),
        );
      } finally {
        scaled.dispose();
      }
    } finally {
      picture.dispose();
    }
  }

  static Uint8List _bytesFromData(ByteData? data) {
    if (data == null) {
      throw StateError('GPU 像素读取失败');
    }
    return data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
  }

  static ui.FilterQuality _filterQuality(img.Interpolation interpolation) {
    switch (interpolation) {
      case img.Interpolation.nearest:
        return ui.FilterQuality.none;
      case img.Interpolation.linear:
        return ui.FilterQuality.low;
      case img.Interpolation.average:
        return ui.FilterQuality.medium;
      case img.Interpolation.cubic:
        return ui.FilterQuality.high;
    }
  }

  /// 在 CPU isolate 中把 RGBA 像素编码成多个质量档位的 JPEG。
  static _EncodedBatch _encodeBatch(List<Object?> args) {
    final Uint8List rgba = args[0] as Uint8List;
    final int width = args[1] as int;
    final int height = args[2] as int;
    final List<int> qualities = (args[3] as List<Object?>).cast<int>();
    final SharpenOption sharpen = SharpenOption.values[args[4] as int];

    final img.Image decoded = img.Image.fromBytes(
      width: width,
      height: height,
      bytes: rgba.buffer,
      bytesOffset: rgba.offsetInBytes,
      numChannels: 4,
      order: img.ChannelOrder.rgba,
    );
    final img.Image image = applySharpen(decoded, sharpen);

    return _EncodedBatch(
      width: image.width,
      height: image.height,
      qualities: qualities,
      encoded: <Uint8List>[
        for (final int quality in qualities)
          img.encodeJpg(image, quality: quality, chroma: img.JpegChroma.yuv420),
      ],
    );
  }
}

class _AlgorithmBatch {
  const _AlgorithmBatch({required this.algorithm, required this.encoded});

  final img.Interpolation algorithm;
  final _EncodedBatch encoded;
}

class _EncodedBatch {
  const _EncodedBatch({
    required this.width,
    required this.height,
    required this.qualities,
    required this.encoded,
  });

  final int width;
  final int height;
  final List<int> qualities;
  final List<Uint8List> encoded;

  ResizedPhoto toPhoto(
    img.Interpolation algorithm,
    int index,
    int originalWidth,
    int originalHeight,
    int originalBytes,
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
