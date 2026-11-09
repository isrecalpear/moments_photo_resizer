import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:moments_photo_resizer/main.dart';

void main() {
  testWidgets('首页展示标题与唯一的选图入口', (WidgetTester tester) async {
    await tester.pumpWidget(const MomentsPhotoResizerApp());

    expect(find.text('图压压'), findsOneWidget);
    expect(find.text('还没有选择照片'), findsOneWidget);

    // 选图入口只保留右下角的 FAB，空状态里不再重复放按钮。
    expect(find.text('选择图片'), findsOneWidget);
    expect(find.byType(FloatingActionButton), findsOneWidget);
    expect(find.byType(FilledButton), findsNothing);
  });
}
