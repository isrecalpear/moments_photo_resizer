import 'dart:typed_data';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugDefaultTargetPlatformOverride;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moments_photo_resizer/comparison_view.dart';
import 'package:moments_photo_resizer/image_resizer.dart';
import 'package:moments_photo_resizer/main.dart';
import 'package:moments_photo_resizer/sharpen_option.dart';

Uint8List _sourceJpeg() {
  final img.Image image = img.Image(width: 400, height: 300);
  img.fill(image, color: img.ColorRgb8(40, 90, 140));
  return img.encodeJpg(image);
}

void main() {
  late Uint8List original;
  late ResizedPhoto resized;

  setUpAll(() {
    original = _sourceJpeg();
    resized = const ImageResizer(
      constraints: ResizeConstraints(maxShortSide: 150),
    ).processSync(original);
  });

  Future<void> pumpResultView(
    WidgetTester tester, {
    ValueChanged<int>? onJpegQualityChanged,
    ValueChanged<SharpenOption>? onSharpenChanged,
  }) async {
    ResultViewMode mode = ResultViewMode.result;
    await tester.pumpWidget(
      MaterialApp(
        theme: ThemeData(useMaterial3: true),
        home: Scaffold(
          body: Padding(
            padding: const EdgeInsets.all(16),
            child: StatefulBuilder(
              builder: (BuildContext context, StateSetter setState) {
                return ResultView(
                  original: original,
                  result: resized,
                  mode: mode,
                  onModeChanged: (ResultViewMode next) {
                    setState(() => mode = next);
                  },
                  jpegQuality: 100,
                  onJpegQualityChanged: onJpegQualityChanged ?? (int value) {},
                  sharpen: SharpenOption.none,
                  onSharpenChanged: onSharpenChanged ?? (SharpenOption v) {},
                  renderBackend: 'CPU 多核',
                  onPickAgain: () {},
                  onSave: () {},
                );
              },
            ),
          ),
        ),
      ),
    );
  }

  testWidgets('结果页包含模式切换、质量滑条、锐化滑条和操作按钮', (WidgetTester tester) async {
    await pumpResultView(tester);

    expect(find.text('结果'), findsOneWidget);
    expect(find.text('对比'), findsOneWidget);
    expect(find.text('JPEG 质量'), findsOneWidget);
    expect(find.text('锐化'), findsOneWidget);
    expect(
      find.byKey(const ValueKey<String>('quality-slider')),
      findsOneWidget,
    );
    expect(
      find.byKey(const ValueKey<String>('sharpen-slider')),
      findsOneWidget,
    );
    expect(find.text('换一张'), findsOneWidget);
    expect(find.text('保存图片'), findsOneWidget);
    expect(find.byType(ComparisonView), findsNothing);
    // 采样算法与 GPU 加速在二级菜单里，结果页没有算法下拉框。
    expect(find.byType(DropdownMenu<img.Interpolation>), findsNothing);
  });

  testWidgets('信息卡片展示渲染方式', (WidgetTester tester) async {
    await pumpResultView(tester);

    expect(find.text('渲染方式'), findsOneWidget);
    expect(find.text('CPU 多核'), findsOneWidget);
  });

  testWidgets('切到对比模式后显示左右对比和缩放工具', (WidgetTester tester) async {
    await pumpResultView(tester);

    await tester.tap(find.text('对比'));
    await tester.pumpAndSettle();

    expect(find.byType(ComparisonView), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ComparisonView),
        matching: find.text('原图'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ComparisonView),
        matching: find.text('压缩后'),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(ComparisonZoomBar),
        matching: find.text('100%'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(ComparisonZoomBar),
        matching: find.text('150%'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('结果模式同样可以缩放', (WidgetTester tester) async {
    await pumpResultView(tester);

    expect(find.byType(SinglePhotoView), findsOneWidget);
    expect(find.byType(InteractiveViewer), findsOneWidget);
    expect(
      find.descendant(
        of: find.byType(ComparisonZoomBar),
        matching: find.text('100%'),
      ),
      findsOneWidget,
    );

    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(
      find.descendant(
        of: find.byType(ComparisonZoomBar),
        matching: find.text('150%'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('信息区触控板只在移动端出现', (WidgetTester tester) async {
    await pumpResultView(tester);
    // 测试环境的默认平台是 Android。
    expect(
      find.byKey(const ValueKey<String>('preview-touchpad')),
      findsOneWidget,
    );

    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    await pumpResultView(tester);
    expect(
      find.byKey(const ValueKey<String>('preview-touchpad')),
      findsNothing,
    );
    // 必须在测试结束前恢复，否则测试框架会报「debug 变量被修改」。
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('质量滑条松手后才触发重新渲染', (WidgetTester tester) async {
    int? selected;
    await pumpResultView(
      tester,
      onJpegQualityChanged: (int value) => selected = value,
    );

    final Slider slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('quality-slider')),
    );
    // 75 / 85 / 95 / 100 四个推荐档位，默认 100%。
    expect(slider.divisions, 3);
    expect(slider.max, 3);
    expect(slider.value, 3);

    // 拖动过程中只更新本地显示，不触发渲染。
    slider.onChanged!(0.0);
    await tester.pump();
    expect(selected, isNull);
    expect(find.text('75%'), findsOneWidget);

    // 松手后才触发。
    tester
        .widget<Slider>(find.byKey(const ValueKey<String>('quality-slider')))
        .onChangeEnd!(0.0);
    await tester.pump();
    expect(selected, 75);
  });

  testWidgets('锐化滑条松手后才触发重新渲染', (WidgetTester tester) async {
    SharpenOption? selected;
    await pumpResultView(
      tester,
      onSharpenChanged: (SharpenOption value) => selected = value,
    );

    final Slider slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('sharpen-slider')),
    );
    expect(slider.divisions, SharpenOption.values.length - 1);
    expect(slider.value, 0);

    // 拖动中不触发。
    slider.onChanged!(3.0);
    await tester.pump();
    expect(selected, isNull);

    // 松手后触发。
    tester
        .widget<Slider>(find.byKey(const ValueKey<String>('sharpen-slider')))
        .onChangeEnd!(3.0);
    await tester.pump();
    expect(selected, SharpenOption.strong);
  });

  testWidgets('质量滑条展示四个推荐档位', (WidgetTester tester) async {
    await pumpResultView(tester);

    for (final int preset in <int>[75, 85, 95, 100]) {
      expect(find.text('$preset'), findsOneWidget);
    }
  });
}
