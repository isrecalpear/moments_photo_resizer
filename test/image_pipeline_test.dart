import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moments_photo_resizer/image_pipeline.dart';
import 'package:moments_photo_resizer/image_resizer.dart';
import 'package:moments_photo_resizer/sharpen_option.dart';

ResizedPhoto _photo(img.Interpolation interpolation, int quality) {
  return ResizedPhoto(
    bytes: Uint8List.fromList(<int>[1, 2, 3]),
    width: 10,
    height: 10,
    originalWidth: 20,
    originalHeight: 20,
    originalBytes: 100,
    interpolation: interpolation,
    jpegQuality: quality,
    sharpen: SharpenOption.none,
  );
}

void main() {
  final Uint8List input = Uint8List.fromList(<int>[1, 2, 3, 4]);

  test('GPU 可用时使用 GPU 后端', () async {
    bool cpuCalled = false;
    final ImagePipeline pipeline = ImagePipeline(
      gpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async => <ResizedPhoto>[_photo(img.Interpolation.average, 85)],
      cpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async {
            cpuCalled = true;
            return <ResizedPhoto>[];
          },
    );

    final List<ResizedPhoto> results = await pipeline.processAll(input);
    expect(results, hasLength(1));
    expect(cpuCalled, isFalse);
    expect(pipeline.lastBackend, ImageBackend.gpu);
    expect(pipeline.backendLabel, 'GPU 加速');
  });

  test('GPU 失败时自动回退到多核 CPU，并只提示一次', () async {
    int fallbacks = 0;
    int cpuCalls = 0;
    final ImagePipeline pipeline = ImagePipeline(
      gpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async => throw StateError('no gpu'),
      cpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async {
            cpuCalls++;
            return <ResizedPhoto>[_photo(img.Interpolation.average, 85)];
          },
      onGpuFallback: () => fallbacks++,
    );

    final List<ResizedPhoto> results = await pipeline.processAll(input);
    expect(results, hasLength(1));
    expect(pipeline.lastBackend, ImageBackend.cpu);
    expect(pipeline.gpuActive, isFalse);
    expect(fallbacks, 1);

    // 再次渲染不再尝试 GPU，也不会重复提示。
    await pipeline.processAll(input);
    expect(cpuCalls, 2);
    expect(fallbacks, 1);
  });

  test('关闭 GPU 时直接使用 CPU', () async {
    bool gpuCalled = false;
    final ImagePipeline pipeline = ImagePipeline(
      preferGpu: false,
      gpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async {
            gpuCalled = true;
            return <ResizedPhoto>[];
          },
      cpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async => <ResizedPhoto>[_photo(img.Interpolation.average, 85)],
    );

    await pipeline.processAll(input);
    expect(gpuCalled, isFalse);
    expect(pipeline.lastBackend, ImageBackend.cpu);
  });

  test('重新开启 GPU 后可以再次尝试', () async {
    int gpuCalls = 0;
    final ImagePipeline pipeline = ImagePipeline(
      gpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async {
            gpuCalls++;
            if (gpuCalls == 1) {
              throw StateError('first attempt fails');
            }
            return <ResizedPhoto>[_photo(img.Interpolation.average, 85)];
          },
      cpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async => <ResizedPhoto>[_photo(img.Interpolation.average, 85)],
    );

    await pipeline.processAll(input);
    expect(pipeline.gpuActive, isFalse);

    pipeline.resetGpuAvailability();
    await pipeline.processAll(input);
    expect(gpuCalls, 2);
    expect(pipeline.lastBackend, ImageBackend.gpu);
  });

  test('processOne 返回单个组合的结果', () async {
    final ImagePipeline pipeline = ImagePipeline(
      gpuBatch:
          (
            Uint8List bytes, {
            List<img.Interpolation>? interpolations,
            List<int>? qualities,
            SharpenOption sharpen = SharpenOption.none,
            void Function(List<ResizedPhoto>, int, int)? onBatch,
          }) async => <ResizedPhoto>[_photo(img.Interpolation.linear, 75)],
    );

    final ResizedPhoto photo = await pipeline.processOne(
      input,
      interpolation: img.Interpolation.linear,
      jpegQuality: 75,
      sharpen: SharpenOption.light,
    );
    expect(photo.jpegQuality, 75);
    expect(photo.interpolation, img.Interpolation.linear);
  });
}
