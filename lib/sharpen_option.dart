import 'package:image/image.dart' as img;

/// 缩放后的锐化强度。
enum SharpenOption {
  none('关闭'),
  light('轻度'),
  standard('标准'),
  strong('强');

  const SharpenOption(this.label);

  /// 界面上展示的名称。
  final String label;

  bool get enabled => this != SharpenOption.none;

  /// 3x3 锐化卷积核；关闭时返回 `null`。
  ///
  /// 力度整体再减半（相对原图的锐化量）：轻度 ×0.5、标准 ×1、强 ×2，
  /// 避免过度锐化产生边缘光晕。
  List<num>? get kernel => switch (this) {
    SharpenOption.none => null,
    SharpenOption.light => const <num>[
      0,
      -0.125,
      0,
      -0.125,
      1.5,
      -0.125,
      0,
      -0.125,
      0,
    ],
    SharpenOption.standard => const <num>[
      0,
      -0.25,
      0,
      -0.25,
      2,
      -0.25,
      0,
      -0.25,
      0,
    ],
    SharpenOption.strong => const <num>[0, -0.5, 0, -0.5, 3, -0.5, 0, -0.5, 0],
  };
}

/// 对缩放后的图片应用锐化；[SharpenOption.none] 时原样返回。
img.Image applySharpen(img.Image image, SharpenOption option) {
  final List<num>? kernel = option.kernel;
  if (kernel == null) {
    return image;
  }
  return img.convolution(image, filter: kernel);
}
