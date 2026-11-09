import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moments_photo_resizer/main.dart';
import 'package:moments_photo_resizer/photo_picker.dart';

Uint8List _bigJpeg() {
  final img.Image image = img.Image(width: 3000, height: 2000);
  img.fill(image, color: img.ColorRgb8(40, 90, 140));
  return img.encodeJpg(image);
}

Uint8List _smallJpeg() {
  final img.Image image = img.Image(width: 400, height: 300);
  img.fill(image, color: img.ColorRgb8(40, 90, 140));
  return img.encodeJpg(image);
}

Future<void> _pumpUntil(
  WidgetTester tester,
  bool Function() condition, {
  Duration timeout = const Duration(seconds: 60),
}) async {
  final Stopwatch stopwatch = Stopwatch()..start();
  while (!condition()) {
    if (stopwatch.elapsed > timeout) {
      fail('等待超时：${stopwatch.elapsed}');
    }
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
}

void main() {
  testWidgets('先显示当前结果，随后在后台补齐默认算法的质量档位', (WidgetTester tester) async {
    final Uint8List bytes = _bigJpeg();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          pickImage: () async => PickedPhoto(bytes: bytes, name: 'demo.jpg'),
        ),
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    await _pumpUntil(
      tester,
      () => find.byType(ResultView).evaluate().isNotEmpty,
    );

    // 当前组合已经可以先看到，同时后台在补齐质量档位。
    expect(find.byType(ResultView), findsOneWidget);
    expect(find.textContaining('后台渲染'), findsOneWidget);

    // 后台渲染完成后进度条自动消失。
    await _pumpUntil(
      tester,
      () => find.textContaining('后台渲染').evaluate().isEmpty,
    );
    expect(find.textContaining('后台渲染'), findsNothing);
    expect(find.byType(ResultView), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('选图器返回前保持当前界面，拿到图片后才进入渲染', (WidgetTester tester) async {
    final Completer<PickedPhoto?> picker = Completer<PickedPhoto?>();
    final Uint8List bytes = _smallJpeg();

    await tester.pumpWidget(
      MaterialApp(home: HomePage(pickImage: () => picker.future)),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    // 系统选图器还没返回：界面保持空状态，不应出现渲染提示或转圈。
    expect(find.text('还没有选择照片'), findsOneWidget);
    expect(find.text('正在生成当前结果…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    // 选图期间 FAB 暂时禁用，避免重复打开选择器。
    expect(
      tester
          .widget<FloatingActionButton>(find.byType(FloatingActionButton))
          .onPressed,
      isNull,
    );

    picker.complete(PickedPhoto(bytes: bytes, name: 'demo.jpg'));
    await tester.pump();

    await _pumpUntil(
      tester,
      () => find.byType(ResultView).evaluate().isNotEmpty,
    );
    expect(find.byType(ResultView), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('二级菜单包含采样算法、锐化和 GPU 加速', (WidgetTester tester) async {
    await tester.pumpWidget(const MaterialApp(home: HomePage()));

    await tester.tap(find.byTooltip('渲染设置'));
    await tester.pumpAndSettle();

    expect(find.text('渲染设置'), findsOneWidget);
    expect(find.text('采样算法'), findsWidgets);
    expect(find.text('GPU 加速（可用时）'), findsOneWidget);
  });

  testWidgets('调整质量时保留原界面，渲染完成后直接切换结果照片', (WidgetTester tester) async {
    final Uint8List bytes = _smallJpeg();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          pickImage: () async => PickedPhoto(bytes: bytes, name: 'demo.jpg'),
        ),
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    await _pumpUntil(
      tester,
      () => find.byType(ResultView).evaluate().isNotEmpty,
    );
    expect(find.byType(ResultView), findsOneWidget);

    // 拖动质量滑条并松手：不切换到「正在渲染」页面。
    final Slider slider = tester.widget<Slider>(
      find.byKey(const ValueKey<String>('quality-slider')),
    );
    slider.onChanged!(1.0);
    await tester.pump();
    tester
        .widget<Slider>(find.byKey(const ValueKey<String>('quality-slider')))
        .onChangeEnd!(1.0);
    await tester.pump();

    expect(find.byType(ResultView), findsOneWidget);
    expect(find.text('正在生成当前结果…'), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);

    // 渲染完成后结果照片直接更新。
    await _pumpUntil(
      tester,
      () => find.textContaining('质量 85%').evaluate().isNotEmpty,
    );
    expect(find.textContaining('质量 85%'), findsOneWidget);
    expect(find.byType(ResultView), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));

  testWidgets('调整锐化时滑条冻结，渲染完成后解锁', (WidgetTester tester) async {
    final Uint8List bytes = _smallJpeg();

    await tester.pumpWidget(
      MaterialApp(
        home: HomePage(
          pickImage: () async => PickedPhoto(bytes: bytes, name: 'demo.jpg'),
        ),
      ),
    );

    await tester.tap(find.byType(FloatingActionButton));
    await tester.pump();

    await _pumpUntil(
      tester,
      () => find.byType(ResultView).evaluate().isNotEmpty,
    );

    Slider sharpenSlider() => tester.widget<Slider>(
      find.byKey(const ValueKey<String>('sharpen-slider')),
    );

    expect(sharpenSlider().onChanged, isNotNull);
    // 松手触发渲染后，锐化滑条立即冻结。
    sharpenSlider().onChangeEnd!(1.0);
    await tester.pump();
    expect(sharpenSlider().onChanged, isNull);

    // 渲染完成后自动解锁。
    await _pumpUntil(tester, () => sharpenSlider().onChanged != null);
    expect(sharpenSlider().onChanged, isNotNull);
    expect(find.byType(ResultView), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
