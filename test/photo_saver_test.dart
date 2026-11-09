import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moments_photo_resizer/photo_saver.dart';

const MethodChannel _galChannel = MethodChannel('gal');

/// 替换 gal 的 MethodChannel，方便模拟权限状态与原生错误。
void _mockGal(Future<Object?>? Function(MethodCall call)? handler) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(_galChannel, handler);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final Uint8List sampleBytes = Uint8List.fromList(<int>[1, 2, 3, 4, 5]);

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    PhotoSaver.debugUseGalleryOverride = null;
    PhotoSaver.debugGalleryWriter = null;
    PhotoSaver.debugFileWriter = null;
    _mockGal(null);
  });

  group('平台分派', () {
    test('usesGallery 按平台计算，debugUseGalleryOverride 优先', () {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(PhotoSaver.usesGallery, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(PhotoSaver.usesGallery, isTrue);

      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      expect(PhotoSaver.usesGallery, isFalse);

      debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
      expect(PhotoSaver.usesGallery, isFalse);

      PhotoSaver.debugUseGalleryOverride = true;
      expect(PhotoSaver.usesGallery, isTrue);

      PhotoSaver.debugUseGalleryOverride = false;
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(PhotoSaver.usesGallery, isFalse);
    });

    test('Android 走系统相册，文件名不带扩展名', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final List<String> calls = <String>[];
      Uint8List? galleryBytes;
      String? galleryName;
      PhotoSaver.debugGalleryWriter = (Uint8List bytes, String name) async {
        calls.add('gallery');
        galleryBytes = bytes;
        galleryName = name;
      };
      PhotoSaver.debugFileWriter = (Uint8List bytes, String fileName) async {
        calls.add('file');
        return 'unexpected';
      };

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo_compressed',
      );

      expect(calls, <String>['gallery']);
      expect(galleryBytes, sampleBytes);
      expect(galleryName, 'photo_compressed');
      expect(result, isNotNull);
      expect(result!.target, PhotoSaveTarget.gallery);
      expect(result.location, isNull);
    });

    test('iOS 走系统相册，文件名保留 .jpg 扩展名', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final List<String> calls = <String>[];
      Uint8List? galleryBytes;
      String? galleryName;
      PhotoSaver.debugGalleryWriter = (Uint8List bytes, String name) async {
        calls.add('gallery');
        galleryBytes = bytes;
        galleryName = name;
      };
      PhotoSaver.debugFileWriter = (Uint8List bytes, String fileName) async {
        calls.add('file');
        return 'unexpected';
      };

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo_compressed',
      );

      expect(calls, <String>['gallery']);
      expect(galleryBytes, sampleBytes);
      expect(galleryName, 'photo_compressed.jpg');
      expect(result, isNotNull);
      expect(result!.target, PhotoSaveTarget.gallery);
      expect(result.location, isNull);
    });

    test('Windows 仍走「另存为」并返回保存路径', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final List<String> calls = <String>[];
      String? fileArg;
      PhotoSaver.debugGalleryWriter = (Uint8List bytes, String name) async {
        calls.add('gallery');
      };
      PhotoSaver.debugFileWriter = (Uint8List bytes, String fileName) async {
        calls.add('file');
        fileArg = fileName;
        return r'C:\Users\test\photo.jpg';
      };

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo_compressed',
      );

      expect(calls, <String>['file']);
      expect(fileArg, 'photo_compressed.jpg');
      expect(result, isNotNull);
      expect(result!.target, PhotoSaveTarget.file);
      expect(result.location, r'C:\Users\test\photo.jpg');
    });

    test('用户取消「另存为」时返回 null', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      PhotoSaver.debugFileWriter = (Uint8List bytes, String fileName) async =>
          null;

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo',
      );

      expect(result, isNull);
    });

    test('debugUseGalleryOverride 可以强制切换保存方式', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      PhotoSaver.debugUseGalleryOverride = true;
      final List<String> calls = <String>[];
      PhotoSaver.debugGalleryWriter = (Uint8List bytes, String name) async {
        calls.add('gallery');
      };
      PhotoSaver.debugFileWriter = (Uint8List bytes, String fileName) async {
        calls.add('file');
        return 'unexpected';
      };

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo',
      );

      expect(calls, <String>['gallery']);
      expect(result!.target, PhotoSaveTarget.gallery);
      expect(result.location, isNull);
    });
  });

  group('文件名处理', () {
    test('文件保存分支自动补 .jpg，已有扩展名不重复添加', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final List<String> names = <String>[];
      PhotoSaver.debugFileWriter = (Uint8List bytes, String fileName) async {
        names.add(fileName);
        return '/tmp/$fileName';
      };

      await PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo');
      await PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo.jpg');
      await PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo.JPEG');

      expect(names, <String>['photo.jpg', 'photo.jpg', 'photo.JPEG']);
    });
  });

  group('系统相册权限与错误映射', () {
    test('没有权限且申请被拒绝时抛出中文友好错误', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      int putCalls = 0;
      _mockGal((MethodCall call) async {
        if (call.method == 'hasAccess') {
          return false;
        }
        if (call.method == 'requestAccess') {
          return false;
        }
        if (call.method == 'putImageBytes') {
          putCalls++;
          return null;
        }
        return null;
      });

      await expectLater(
        PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo'),
        throwsA(
          isA<PhotoSaveException>().having(
            (PhotoSaveException error) => error.message,
            'message',
            PhotoSaver.permissionDeniedMessage,
          ),
        ),
      );
      expect(putCalls, 0);
    });

    test('无需申请时直接写入相册，Android 传不带扩展名的 name', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final List<MethodCall> calls = <MethodCall>[];
      _mockGal((MethodCall call) async {
        calls.add(call);
        if (call.method == 'hasAccess') {
          return true;
        }
        if (call.method == 'requestAccess') {
          return true;
        }
        return null;
      });

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo_compressed',
      );

      expect(result, isNotNull);
      expect(result!.target, PhotoSaveTarget.gallery);
      expect(result.location, isNull);
      expect(
        calls.map((MethodCall call) => call.method),
        contains('hasAccess'),
      );

      final MethodCall put = calls.singleWhere(
        (MethodCall call) => call.method == 'putImageBytes',
      );
      final Map<Object?, Object?> args = put.arguments as Map<Object?, Object?>;
      expect(args['name'], 'photo_compressed');
      expect(args['bytes'], sampleBytes);
      expect(args['album'], isNull);
    });

    test('申请后获得权限则继续写入相册', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final List<String> methods = <String>[];
      _mockGal((MethodCall call) async {
        methods.add(call.method);
        if (call.method == 'hasAccess') {
          return false;
        }
        if (call.method == 'requestAccess') {
          return true;
        }
        return null;
      });

      final PhotoSaveResult? result = await PhotoSaver.saveJpeg(
        bytes: sampleBytes,
        fileName: 'photo',
      );

      expect(result, isNotNull);
      expect(result!.target, PhotoSaveTarget.gallery);
      expect(methods, contains('requestAccess'));
      expect(
        methods.where((String method) => method == 'putImageBytes'),
        hasLength(1),
      );
    });

    test('iOS 写入相册时 name 带 .jpg 扩展名', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final List<MethodCall> calls = <MethodCall>[];
      _mockGal((MethodCall call) async {
        calls.add(call);
        if (call.method == 'hasAccess') {
          return true;
        }
        if (call.method == 'requestAccess') {
          return true;
        }
        return null;
      });

      await PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo');

      final MethodCall put = calls.singleWhere(
        (MethodCall call) => call.method == 'putImageBytes',
      );
      final Map<Object?, Object?> args = put.arguments as Map<Object?, Object?>;
      expect(args['name'], 'photo.jpg');
      expect(args['bytes'], sampleBytes);
    });

    test('gal 返回 ACCESS_DENIED 时映射为权限提示', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      _mockGal((MethodCall call) async {
        if (call.method == 'hasAccess') {
          return true;
        }
        if (call.method == 'requestAccess') {
          return true;
        }
        throw PlatformException(
          code: 'ACCESS_DENIED',
          message: 'denied by user',
        );
      });

      await expectLater(
        PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo'),
        throwsA(
          isA<PhotoSaveException>().having(
            (PhotoSaveException error) => error.message,
            'message',
            PhotoSaver.permissionDeniedMessage,
          ),
        ),
      );
    });

    test('gal 的其它原生错误也映射为中文提示', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final Map<String, String> expectedMessages = <String, String>{
        'NOT_ENOUGH_SPACE': '设备存储空间不足，无法保存到相册。',
        'NOT_SUPPORTED_FORMAT': '系统相册不支持该图片格式。',
        'UNEXPECTED': '保存到相册失败：native boom',
      };

      for (final MapEntry<String, String> entry in expectedMessages.entries) {
        _mockGal((MethodCall call) async {
          if (call.method == 'hasAccess') {
            return true;
          }
          if (call.method == 'requestAccess') {
            return true;
          }
          throw PlatformException(code: entry.key, message: 'native boom');
        });

        await expectLater(
          PhotoSaver.saveJpeg(bytes: sampleBytes, fileName: 'photo'),
          throwsA(
            isA<PhotoSaveException>().having(
              (PhotoSaveException error) => error.message,
              'message',
              entry.value,
            ),
          ),
          reason: 'code=${entry.key}',
        );
      }
    });
  });
}
