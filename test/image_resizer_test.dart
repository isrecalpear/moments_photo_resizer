import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moments_photo_resizer/image_resizer.dart';
import 'package:moments_photo_resizer/sharpen_option.dart';

Uint8List _solidJpeg(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  img.fill(image, color: img.ColorRgb8(90, 140, 210));
  return img.encodeJpg(image);
}

Uint8List _gradientJpeg(int width, int height) {
  final img.Image image = img.Image(width: width, height: height);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      image.setPixelRgb(
        x,
        y,
        (x * 255) ~/ width,
        (y * 255) ~/ height,
        (x * y) % 256,
      );
    }
  }
  return img.encodeJpg(image);
}

void main() {
  group('ImageResizer.planResize', () {
    test('按短边限制缩小 4:3 照片', () {
      final ResizePlan plan = ImageResizer.planResize(4000, 3000);
      expect(plan.resized, isTrue);
      expect(plan.width, 2560);
      expect(plan.height, 1920);
    });

    test('不放大尺寸较小的图片', () {
      final ResizePlan plan = ImageResizer.planResize(320, 240);
      expect(plan.resized, isFalse);
      expect(plan.width, 320);
      expect(plan.height, 240);
    });

    test('超宽图片受总像素量限制', () {
      final ResizePlan plan = ImageResizer.planResize(12000, 2000);
      expect(plan.resized, isTrue);
      expect(plan.width * plan.height, lessThanOrEqualTo(10240000));
      expect(plan.width / plan.height, closeTo(6, 0.02));
    });

    test('各种尺寸的总像素量都不超过 10,240,000', () {
      const List<(int, int)> sizes = <(int, int)>[
        (12000, 2000),
        (6000, 4000),
        (10000, 10000),
        (3840, 2160),
        (8000, 6000),
        (2000, 3000),
      ];
      for (final (int width, int height) in sizes) {
        final ResizePlan plan = ImageResizer.planResize(width, height);
        expect(
          plan.width * plan.height,
          lessThanOrEqualTo(10240000),
          reason: '${width}x$height 缩放后为 ${plan.width}x${plan.height}',
        );
        expect(math.min(plan.width, plan.height), lessThanOrEqualTo(1920));
        expect(
          plan.width / plan.height,
          closeTo(width / height, 0.02),
          reason: '${width}x$height 的宽高比应保持不变',
        );
      }
    });

    test('非法尺寸抛出 ArgumentError', () {
      expect(() => ImageResizer.planResize(0, 100), throwsArgumentError);
      expect(() => ImageResizer.planResize(100, -1), throwsArgumentError);
    });

    test('合法尺寸但上限非法时抛出 ArgumentError', () {
      expect(
        () => ImageResizer.planResize(100, 100, maxPixels: 0),
        throwsArgumentError,
      );
      expect(
        () => ImageResizer.planResize(100, 100, maxShortSide: 0),
        throwsArgumentError,
      );
    });
  });

  group('ImageResizer.process', () {
    const ImageResizer smallOutput = ImageResizer(
      constraints: ResizeConstraints(maxShortSide: 150),
    );

    test('缩放并输出 JPEG', () {
      final ResizedPhoto result = smallOutput.processSync(_solidJpeg(400, 300));
      expect(result.width, 200);
      expect(result.height, 150);
      expect(result.originalWidth, 400);
      expect(result.originalHeight, 300);
      expect(result.bytes[0], 0xFF);
      expect(result.bytes[1], 0xD8);

      final img.Image? decoded = img.decodeJpg(result.bytes);
      expect(decoded, isNotNull);
      expect(decoded!.width, 200);
      expect(decoded.height, 150);
    });

    test('默认参数下输出总像素量不超过 10,240,000', () {
      final ResizedPhoto result = const ImageResizer().processSync(
        _solidJpeg(3000, 2000),
      );
      expect(result.keepsSize, isFalse);
      expect(result.width * result.height, lessThanOrEqualTo(10240000));
      expect(math.min(result.width, result.height), lessThanOrEqualTo(1920));
    });

    test('小图只重新编码，不改变尺寸', () {
      const ImageResizer resizer = ImageResizer();
      final ResizedPhoto result = resizer.processSync(_solidJpeg(320, 240));
      expect(result.width, 320);
      expect(result.height, 240);
      expect(result.keepsSize, isTrue);
    });

    test('JPEG 质量参数影响输出体积', () {
      final Uint8List input = _gradientJpeg(240, 180);
      final ResizedPhoto low = const ImageResizer(
        jpegQuality: 20,
      ).processSync(input);
      final ResizedPhoto high = const ImageResizer(
        jpegQuality: 95,
      ).processSync(input);
      expect(low.size, lessThan(high.size));
    });

    test('不同采样算法缩小时得到不同的像素结果', () {
      final Uint8List input = _gradientJpeg(400, 300);
      const ResizeConstraints constraints = ResizeConstraints(
        maxShortSide: 100,
      );

      final Uint8List nearest = const ImageResizer(
        constraints: constraints,
        interpolation: img.Interpolation.nearest,
      ).processSync(input).bytes;
      final Uint8List average = const ImageResizer(
        constraints: constraints,
        interpolation: img.Interpolation.average,
      ).processSync(input).bytes;

      expect(nearest, isNot(equals(average)));
    });

    test('采样算法不影响无需缩放的图片尺寸', () {
      final Uint8List input = _solidJpeg(320, 240);
      final ResizedPhoto nearest = const ImageResizer(
        interpolation: img.Interpolation.nearest,
      ).processSync(input);
      final ResizedPhoto cubic = const ImageResizer(
        interpolation: img.Interpolation.cubic,
      ).processSync(input);
      expect(nearest.width, 320);
      expect(cubic.width, 320);
      expect(nearest.keepsSize, isTrue);
      expect(cubic.keepsSize, isTrue);
    });

    test('无法解码的数据抛出 ImageProcessingException', () {
      const ImageResizer resizer = ImageResizer();
      expect(
        () => resizer.processSync(Uint8List.fromList(<int>[1, 2, 3, 4])),
        throwsA(isA<ImageProcessingException>()),
      );
    });

    test('异步处理通过 compute 返回结果', () async {
      final ResizedPhoto result = await smallOutput.process(
        _solidJpeg(400, 300),
      );
      expect(result.width, 200);
      expect(result.height, 150);
    });

    test('异步处理时异常也能穿过 isolate 传回', () async {
      await expectLater(
        const ImageResizer().process(Uint8List.fromList(<int>[1, 2, 3, 4])),
        throwsA(isA<ImageProcessingException>()),
      );
    });

    test('体积变化比例：变小为负数', () {
      final Uint8List input = _gradientJpeg(240, 180);
      final ResizedPhoto result = const ImageResizer(
        jpegQuality: 10,
      ).processSync(input);
      expect(result.sizeChange, lessThan(0));
      expect(result.isSmaller, isTrue);
    });
  });

  group('ImageResizer.processAll', () {
    const ImageResizer batchResizer = ImageResizer(
      constraints: ResizeConstraints(maxShortSide: 150),
    );

    test('一次预渲染所有采样算法与质量组合', () async {
      final List<ResizedPhoto> results = await batchResizer.processAll(
        _gradientJpeg(400, 300),
        interpolations: <img.Interpolation>[
          img.Interpolation.average,
          img.Interpolation.nearest,
        ],
        qualities: <int>[60, 95],
      );

      expect(results, hasLength(4));
      for (final ResizedPhoto photo in results) {
        expect(photo.width, 200);
        expect(photo.height, 150);
        expect(photo.originalWidth, 400);
        expect(photo.originalHeight, 300);
      }
      expect(
        results.map((ResizedPhoto p) => p.interpolation).toSet(),
        <img.Interpolation>{
          img.Interpolation.average,
          img.Interpolation.nearest,
        },
      );
      expect(results.map((ResizedPhoto p) => p.jpegQuality).toSet(), <int>{
        60,
        95,
      });

      ResizedPhoto photoOf(img.Interpolation interpolation, int quality) =>
          results.firstWhere(
            (ResizedPhoto p) =>
                p.interpolation == interpolation && p.jpegQuality == quality,
          );

      expect(
        photoOf(img.Interpolation.average, 60).size,
        lessThan(photoOf(img.Interpolation.average, 95).size),
      );
      expect(
        photoOf(img.Interpolation.average, 60).bytes,
        isNot(equals(photoOf(img.Interpolation.nearest, 60).bytes)),
      );
    });

    test('批量任务边算边汇报进度', () async {
      final List<int> progress = <int>[];
      final List<int> batchSizes = <int>[];
      final List<ResizedPhoto> results = await batchResizer.processAll(
        _gradientJpeg(400, 300),
        interpolations: <img.Interpolation>[
          img.Interpolation.average,
          img.Interpolation.nearest,
        ],
        qualities: <int>[60, 85],
        onBatch: (List<ResizedPhoto> batch, int completed, int total) {
          expect(total, 4);
          batchSizes.add(batch.length);
          progress.add(completed);
        },
      );

      expect(results, hasLength(4));
      expect(batchSizes.fold<int>(0, (int sum, int size) => sum + size), 4);
      expect(progress, isNotEmpty);
      expect(progress.last, 4);
      // 进度必须单调递增且不超过总数。
      for (int i = 1; i < progress.length; i++) {
        expect(progress[i], greaterThan(progress[i - 1]));
      }
    });

    test('无需缩放时各算法复用同一份编码结果', () async {
      final List<int> progress = <int>[];
      final List<ResizedPhoto> results = await const ImageResizer().processAll(
        _solidJpeg(320, 240),
        interpolations: <img.Interpolation>[
          img.Interpolation.average,
          img.Interpolation.nearest,
        ],
        qualities: <int>[60, 85],
        onBatch: (List<ResizedPhoto> batch, int completed, int total) {
          progress.add(completed);
          expect(total, 4);
        },
      );

      expect(results, hasLength(4));
      expect(progress, <int>[4]);
      expect(results.every((ResizedPhoto p) => p.keepsSize), isTrue);

      ResizedPhoto photoOf(img.Interpolation interpolation, int quality) =>
          results.firstWhere(
            (ResizedPhoto p) =>
                p.interpolation == interpolation && p.jpegQuality == quality,
          );

      final ResizedPhoto average = photoOf(img.Interpolation.average, 85);
      final ResizedPhoto nearest = photoOf(img.Interpolation.nearest, 85);
      expect(identical(average.bytes, nearest.bytes), isTrue);
    });

    test('传入空列表时返回空结果', () async {
      final List<ResizedPhoto> results = await const ImageResizer().processAll(
        _solidJpeg(10, 10),
        interpolations: const <img.Interpolation>[],
        qualities: <int>[85],
      );
      expect(results, isEmpty);
    });

    test('锐化强度会影响输出像素，并在结果中记录', () async {
      final Uint8List input = _gradientJpeg(240, 180);
      final ResizedPhoto none = const ImageResizer().processSync(input);
      final ResizedPhoto strong = const ImageResizer().processSync(
        input,
        sharpen: SharpenOption.strong,
      );

      expect(none.sharpen, SharpenOption.none);
      expect(strong.sharpen, SharpenOption.strong);
      expect(strong.bytes, isNot(equals(none.bytes)));
      expect(img.decodeJpg(strong.bytes), isNotNull);
    });

    test('批量渲染会透传锐化参数', () async {
      final List<ResizedPhoto> results = await const ImageResizer().processAll(
        _solidJpeg(400, 300),
        interpolations: <img.Interpolation>[img.Interpolation.average],
        qualities: <int>[85],
        sharpen: SharpenOption.standard,
      );
      expect(results, hasLength(1));
      expect(results.single.sharpen, SharpenOption.standard);
    });
  });
}
