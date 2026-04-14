import 'package:flutter/material.dart';
import 'lib/photo_picker.dart';
import 'lib/image.dart' as image;
import 'package:image/image.dart' as img;

void main() {
  runApp(const MainApp());
}

class MainApp extends StatelessWidget {
  const MainApp({super.key});

  @override
  Widget build(BuildContext context) {
    return const MaterialApp(home: ImagePickerPage());
  }
}

class ImagePickerPage extends StatefulWidget {
  const ImagePickerPage({super.key});

  @override
  State<ImagePickerPage> createState() => _ImagePickerPageState();
}

class _ImagePickerPageState extends State<ImagePickerPage> {
  img.Image? _resizedImage;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('图压压')),
      body: Center(
        child: _resizedImage == null
            ? const Text('请点击按钮选择图片')
            : Image.memory(img.encodePng(_resizedImage!)),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _onOpenImage,
        child: const Icon(Icons.add),
      ),
    );
  }

  void _onOpenImage() async {
    // 选择单张图片
    final String? imagePath = await PhotoPicker.pickImage();
    if (imagePath != null) {
      final selectedImage = image.Image(imagePath);
      final resizedImage = await selectedImage.getResizedImage();
      setState(() {
        _resizedImage = resizedImage;
      });
    }
  }
}
