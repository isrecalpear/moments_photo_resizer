import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moments_photo_resizer/compression_cache.dart';
import 'package:moments_photo_resizer/image_resizer.dart';
import 'package:moments_photo_resizer/sharpen_option.dart';

Uint8List _sourceJpeg() {
  final img.Image image = img.Image(width: 400, height: 300);
  img.fill(image, color: img.ColorRgb8(40, 90, 140));
  return img.encodeJpg(image);
}

void main() {
  late Uint8List input;
  late int calls;
  late CompressionCache cache;

  setUp(() {
    input = _sourceJpeg();
    calls = 0;
    cache = CompressionCache(
      compress:
          (
            Uint8List bytes,
            img.Interpolation interpolation,
            int jpegQuality,
            SharpenOption sharpen,
          ) async {
            calls++;
            return ImageResizer(
              interpolation: interpolation,
              jpegQuality: jpegQuality,
              constraints: const ResizeConstraints(maxShortSide: 150),
            ).processSync(bytes, sharpen: sharpen);
          },
    );
  });

  test('未缓存时 lookup 返回 null', () {
    expect(
      cache.lookup(img.Interpolation.average, 85, SharpenOption.none),
      isNull,
    );
    expect(cache.cachedCount, 0);
  });

  test('相同参数的第二次调用命中缓存', () async {
    final ResizedPhoto first = await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    final ResizedPhoto second = await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );

    expect(calls, 1);
    expect(identical(first, second), isTrue);
    expect(cache.cachedCount, 1);
  });

  test('采样算法不同会分别计算并缓存', () async {
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.linear,
      85,
      SharpenOption.none,
    );
    expect(calls, 2);

    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.linear,
      85,
      SharpenOption.none,
    );
    expect(calls, 2);
    expect(cache.cachedCount, 2);
  });

  test('JPEG 质量不同会分别计算并缓存', () async {
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.average,
      95,
      SharpenOption.none,
    );
    expect(calls, 2);

    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.average,
      95,
      SharpenOption.none,
    );
    expect(calls, 2);
    expect(cache.cachedCount, 2);
  });

  test('锐化不同会分别计算并缓存', () async {
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.strong,
    );
    expect(calls, 2);

    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.strong,
    );
    expect(calls, 2);
    expect(cache.cachedCount, 2);
  });

  test('算法、质量与锐化组合不同时各自缓存', () async {
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.linear,
      95,
      SharpenOption.strong,
    );
    expect(calls, 2);

    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    await cache.process(
      input,
      img.Interpolation.linear,
      95,
      SharpenOption.strong,
    );
    expect(calls, 2);
    expect(cache.cachedCount, 2);
  });

  test('clear 之后旧结果失效，会重新计算', () async {
    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    expect(calls, 1);

    cache.clear();
    expect(cache.cachedCount, 0);
    expect(
      cache.lookup(img.Interpolation.average, 85, SharpenOption.none),
      isNull,
    );

    await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.none,
    );
    expect(calls, 2);
  });

  test('put 可以直接写入外部渲染的结果', () async {
    final ResizedPhoto result = await cache.process(
      input,
      img.Interpolation.average,
      85,
      SharpenOption.standard,
    );

    final CompressionCache prefilled = CompressionCache(
      compress:
          (
            Uint8List bytes,
            img.Interpolation interpolation,
            int quality,
            SharpenOption sharpen,
          ) => fail('命中预渲染结果时不应重新计算'),
    );
    prefilled.put(result);

    expect(prefilled.cachedCount, 1);
    expect(
      prefilled.lookup(img.Interpolation.average, 85, SharpenOption.standard),
      same(result),
    );
  });
}
