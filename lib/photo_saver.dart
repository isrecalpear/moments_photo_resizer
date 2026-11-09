import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        defaultTargetPlatform,
        immutable,
        kIsWeb,
        visibleForTesting;
import 'package:gal/gal.dart';

/// 保存结果的去处。
enum PhotoSaveTarget {
  /// 已写入系统相册（Android / iOS / iPadOS）。
  gallery,

  /// 已通过「另存为」对话框 / 浏览器下载保存为文件。
  file,
}

/// 保存 JPEG 失败时可以直接展示给用户的错误。
@immutable
class PhotoSaveException implements Exception {
  const PhotoSaveException(this.message);

  /// 面向用户的错误提示。
  final String message;

  @override
  String toString() => message;
}

/// [PhotoSaver.saveJpeg] 的返回值：保存去了哪里，以及文件保存时的路径。
@immutable
class PhotoSaveResult {
  /// 已写入系统相册。
  const PhotoSaveResult.gallery()
    : target = PhotoSaveTarget.gallery,
      location = null;

  /// 已保存为文件，[path] 为保存路径（Web 端为下载文件名）。
  const PhotoSaveResult.file(String path)
    : target = PhotoSaveTarget.file,
      location = path;

  /// 保存的去处。
  final PhotoSaveTarget target;

  /// 文件保存路径；写入系统相册时恒为 `null`。
  final String? location;
}

/// 把压缩后的 JPEG 写出去。
///
/// - 移动端（Android / iOS / iPadOS）：直接写入系统相册，不弹系统保存框；
/// - 桌面端（Windows / macOS / Linux）与 Web：保留「另存为」对话框 /
///   浏览器下载，行为与之前一致。
class PhotoSaver {
  const PhotoSaver._();

  /// 没有相册写入权限时的统一提示。
  static const String permissionDeniedMessage = '没有相册保存权限，请在系统设置中允许「图压压」访问照片。';

  /// 测试用：强制覆盖是否写入系统相册；为 `null` 时按运行平台自动判断。
  @visibleForTesting
  static bool? debugUseGalleryOverride;

  /// 测试用：替换真实的系统相册写入实现，参数为（字节、文件名）。
  @visibleForTesting
  static Future<void> Function(Uint8List bytes, String name)?
  debugGalleryWriter;

  /// 测试用：替换桌面端 / Web 的「另存为」实现，返回 `null` 表示用户取消。
  @visibleForTesting
  static Future<String?> Function(Uint8List bytes, String fileName)?
  debugFileWriter;

  /// 当前平台是否直接写入系统相册。
  static bool get usesGallery =>
      debugUseGalleryOverride ??
      (!kIsWeb &&
          (defaultTargetPlatform == TargetPlatform.android ||
              defaultTargetPlatform == TargetPlatform.iOS));

  /// 保存 JPEG 字节。
  ///
  /// 写入系统相册时返回 [PhotoSaveResult.gallery]；保存为文件时返回
  /// [PhotoSaveResult.file]（用户取消则返回 `null`）。
  static Future<PhotoSaveResult?> saveJpeg({
    required Uint8List bytes,
    required String fileName,
  }) async {
    final String safeName = _ensureJpegExtension(fileName);

    if (usesGallery) {
      final String galleryName = _galleryName(safeName);
      final Future<void> Function(Uint8List bytes, String name) writer =
          debugGalleryWriter ?? _writeToGallery;
      await writer(bytes, galleryName);
      return const PhotoSaveResult.gallery();
    }

    final Future<String?> Function(Uint8List bytes, String fileName) writer =
        debugFileWriter ?? _saveFile;
    final String? location = await writer(bytes, safeName);
    if (location == null) {
      return null;
    }
    return PhotoSaveResult.file(location);
  }

  /// 统一补上 `.jpg` 扩展名；已经是 `.jpg` / `.jpeg` 时保持不变。
  static String _ensureJpegExtension(String fileName) {
    final String lower = fileName.toLowerCase();
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) {
      return fileName;
    }
    return '$fileName.jpg';
  }

  /// 送给 gal 的文件名。
  ///
  /// Android 端的 gal 会按字节猜测格式并自动补扩展名，传带扩展名的名字会
  /// 变成 `xxx.jpg.jpg`，所以只传不带扩展名的 stem；iOS 端把 name 当作
  /// `originalFilename`，需要带 `.jpg`。
  static String _galleryName(String safeName) {
    if (defaultTargetPlatform == TargetPlatform.iOS) {
      return safeName;
    }
    final int dot = safeName.lastIndexOf('.');
    if (dot > 0) {
      return safeName.substring(0, dot);
    }
    return safeName;
  }

  /// 桌面端 / Web 的默认实现：系统「另存为」对话框或浏览器下载。
  static Future<String?> _saveFile(Uint8List bytes, String fileName) {
    return FilePicker.saveFile(
      dialogTitle: '保存压缩后的图片',
      fileName: fileName,
      type: FileType.custom,
      allowedExtensions: const <String>['jpg', 'jpeg'],
      bytes: bytes,
    );
  }

  /// 移动端的默认实现：先确认 / 申请相册权限，再交给 gal 写入系统相册。
  static Future<void> _writeToGallery(Uint8List bytes, String name) async {
    try {
      bool granted = await Gal.hasAccess();
      if (!granted) {
        granted = await Gal.requestAccess();
      }
      if (!granted) {
        throw const PhotoSaveException(permissionDeniedMessage);
      }
      // gal 内部还会再检查一次权限，但前置检查不能省：被拒绝时这里就要给出
      // 可操作的中文提示，而不是把原生错误直接抛给界面。
      await Gal.putImageBytes(bytes, name: name);
    } on GalException catch (error) {
      throw PhotoSaveException(_describeGalException(error));
    }
  }

  /// 把 gal 的原生错误翻译成可以直接展示的中文提示。
  static String _describeGalException(GalException error) {
    switch (error.type) {
      case GalExceptionType.accessDenied:
        return permissionDeniedMessage;
      case GalExceptionType.notEnoughSpace:
        return '设备存储空间不足，无法保存到相册。';
      case GalExceptionType.notSupportedFormat:
        return '系统相册不支持该图片格式。';
      case GalExceptionType.unexpected:
        final String detail =
            error.platformException.message ?? error.platformException.code;
        return '保存到相册失败：$detail';
    }
  }
}
