import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:moments_photo_resizer/comparison_view.dart';

Uint8List _tinyPng() {
  final img.Image image = img.Image(width: 8, height: 8);
  img.fill(image, color: img.ColorRgb8(30, 60, 90));
  return img.encodePng(image);
}

Widget _host(ComparisonController controller) {
  return MaterialApp(
    theme: ThemeData(useMaterial3: true),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          children: <Widget>[
            Expanded(
              child: ComparisonView(
                original: _tinyPng(),
                processed: _tinyPng(),
                controller: controller,
              ),
            ),
            ComparisonZoomBar(controller: controller),
          ],
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('左右对比展示标签并共享同一个变换控制器', (WidgetTester tester) async {
    final ComparisonController controller = ComparisonController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    expect(find.text('原图'), findsOneWidget);
    expect(find.text('压缩后'), findsOneWidget);
    expect(find.text('100%'), findsOneWidget);

    final List<InteractiveViewer> viewers = tester
        .widgetList<InteractiveViewer>(find.byType(InteractiveViewer))
        .toList();
    expect(viewers, hasLength(2));
    expect(
      identical(
        viewers[0].transformationController,
        viewers[1].transformationController,
      ),
      isTrue,
    );
  });

  testWidgets('放大后显示缩放比例，可逐档缩放和还原', (WidgetTester tester) async {
    final ComparisonController controller = ComparisonController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);
    expect(controller.scale, closeTo(1.5, 0.001));

    await tester.tap(find.byTooltip('放大'));
    await tester.pump();
    expect(find.text('200%'), findsOneWidget);

    await tester.tap(find.byTooltip('缩小'));
    await tester.pump();
    expect(find.text('150%'), findsOneWidget);

    await tester.tap(find.byTooltip('还原'));
    await tester.pump();
    expect(find.text('100%'), findsOneWidget);
    expect(controller.scale, 1);
  });

  testWidgets('初始状态下还原按钮不可用', (WidgetTester tester) async {
    final ComparisonController controller = ComparisonController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    final IconButton resetButton = tester.widget<IconButton>(
      find.widgetWithIcon(IconButton, Icons.zoom_out_map),
    );
    expect(resetButton.onPressed, isNull);
  });

  testWidgets('最多可以放大到 3200%', (WidgetTester tester) async {
    final ComparisonController controller = ComparisonController();
    addTearDown(controller.dispose);

    await tester.pumpWidget(_host(controller));

    for (int i = 0; i < 12; i++) {
      final IconButton zoomIn = tester.widget<IconButton>(
        find.widgetWithIcon(IconButton, Icons.add),
      );
      if (zoomIn.onPressed == null) {
        break;
      }
      await tester.tap(find.byTooltip('放大'));
      await tester.pump();
    }

    expect(find.text('3200%'), findsOneWidget);
    expect(controller.scale, 32);
    expect(
      tester
          .widget<IconButton>(find.widgetWithIcon(IconButton, Icons.add))
          .onPressed,
      isNull,
    );
  });
}
