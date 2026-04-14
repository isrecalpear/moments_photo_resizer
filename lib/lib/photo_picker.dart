import 'dart:io' show Platform;
import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:image_picker/image_picker.dart';
import 'package:file_picker/file_picker.dart';
import 'package:permission_handler/permission_handler.dart';

class PhotoPicker {
  static Future<String?> pickImage() async {
    try {
      if (kIsWeb) {
        final picker = ImagePicker();
        final XFile? image = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 100,
        );
        return image?.path;
      } else if (Platform.isAndroid || Platform.isIOS) {
        final picker = ImagePicker();
        final XFile? image = await picker.pickImage(
          source: ImageSource.gallery,
          imageQuality: 100,
        );
        return image?.path;
      } else if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        FilePickerResult? result = await FilePicker.pickFiles(
          type: FileType.image,
          allowMultiple: false,
        );
        if (result != null && result.files.single.path != null) {
          return result.files.single.path!;
        }
        return null;
      } else {
        throw UnsupportedError(
          'Unsupported platform: ${Platform.operatingSystem}',
        );
      }
    } catch (e) {
      return null;
    }
  }

  static Future<bool> checkPermission() async {
    if (Platform.isAndroid) {
      PermissionStatus status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
        return status.isGranted;
      }
      return true;
    }
    if (Platform.isIOS) {
      return true;
    }
    return true;
  }
}
