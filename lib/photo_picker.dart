import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:image_picker/image_picker.dart';

/// 选图失败时抛出，[message] 可以直接展示给用户。
class ImagePickException implements Exception {
  const ImagePickException(this.message);

  final String message;

  @override
  String toString() => message;
}

/// 用户选中的原始图片。
@immutable
class PickedPhoto {
  const PickedPhoto({required this.bytes, required this.name});

  /// 原始文件内容，未做任何压缩。
  final Uint8List bytes;

  /// 原始文件名（可能包含扩展名，部分平台可能为空）。
  final String name;

  /// 去掉扩展名和路径后的文件名，用于生成默认的保存文件名。
  String get baseName {
    final int slash = math.max(name.lastIndexOf('/'), name.lastIndexOf(r'\'));
    final String fileName = slash >= 0 ? name.substring(slash + 1) : name;
    final int dot = fileName.lastIndexOf('.');
    final String stem = dot > 0 ? fileName.substring(0, dot) : fileName;
    return stem.isEmpty ? 'photo' : stem;
  }
}

/// 通过系统相册 / 文件选择器获取图片。
///
/// 这里只依赖 `dart:typed_data` 和 `image_picker`，因此 Web 与桌面端都能编译
/// 和运行；不再直接访问 `dart:io`。
class PhotoPicker {
  const PhotoPicker._();

  /// 打开系统选择器让用户挑一张图片；用户取消时返回 `null`。
  static Future<PickedPhoto?> pickImage() async {
    final ImagePicker picker = ImagePicker();
    final XFile? file = await picker.pickImage(source: ImageSource.gallery);
    if (file == null) {
      return null;
    }

    final Uint8List bytes = await file.readAsBytes();
    if (bytes.isEmpty) {
      throw const ImagePickException('选中的文件是空文件，请重新选择。');
    }

    return PickedPhoto(
      bytes: bytes,
      name: file.name.isEmpty ? 'photo' : file.name,
    );
  }
}
