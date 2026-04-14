import 'dart:math' as math;
import 'package:flutter/material.dart' as material;
import 'package:image/image.dart' as img;
import 'dart:io';
import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/foundation.dart';

class Image {
  final int maxGeometricMean = 3200;
  final int maxShortSide = 1920;

  final String path;
  img.Image? resizedImage;

  Image(this.path);

  Future<img.Image> resizeImage({
    img.Interpolation interpolation = img.Interpolation.nearest,
  }) async {
    final bytes = await File(path).readAsBytes();
    resizedImage = await compute(_processImage, (bytes, interpolation));
    return resizedImage!;
  }

  static Future<img.Image> _processImage((List<int>, img.Interpolation) params) async {
    final (bytes, interpolation) = params;
    
    img.Image? image = img.decodeImage(Uint8List.fromList(bytes));
    if (image == null) {
      throw Exception('Image not found or corrupted!');
    }

    int width = image.width;
    int height = image.height;
    
    if (width == 0 || height == 0) {
      throw ArgumentError('Width and height cannot be zero');
    }

    int pixelArea = width * height;
    double geometricMean = math.sqrt(pixelArea);

    double scaleFactorByGeometric = 3200 / geometricMean;
    double scaleFactorByShortSide = 1920 / math.min(width, height);

    double scaleFactor = math.min(
      scaleFactorByGeometric,
      scaleFactorByShortSide,
    );

    int newWidth = (width * scaleFactor).floor();
    int newHeight = (height * scaleFactor).floor();

    return img.copyResize(
      image,
      width: newWidth,
      height: newHeight,
      interpolation: interpolation,
    );
  }

  Future<img.Image> getResizedImage() async {
    if (resizedImage == null) {
      await resizeImage();
    }
    return resizedImage!;
  }

  Future<material.Image> getResizedImageForUI() async {
    return material.Image.memory(img.encodePng(await getResizedImage()));
  }

  Future<img.Image> getOriginalImage() async {
    final bytes = await File(path).readAsBytes();
    return img.decodeImage(Uint8List.fromList(bytes))!;
  }

  Future<material.Image> getOriginalImageForUI() async {
    return material.Image.memory((await getOriginalImage()).toUint8List());
  }

  Future<void> saveResizedImage(String path) async {
    await getResizedImage();
    await compute(_saveImageIsolate, (path, resizedImage!));
  }

  static Future<void> _saveImageIsolate((String, img.Image) params) async {
    final (path, image) = params;
    final pngBytes = img.encodePng(image);
    await File(path).writeAsBytes(pngBytes);
  }
}
