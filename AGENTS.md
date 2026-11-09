# AGENTS.md — 图压压（moments_photo_resizer）

本文件是给 AI 编码代理和所有贡献者的项目级协作约定。它只写「这个仓库实际怎么做事」；
产品功能、平台行为与参数说明以 [README.md](README.md) 为准，不要在这里重复一遍。

## 项目定位

Flutter 跨平台图片压缩应用「图压压」：把一张照片缩放到适合发朋友圈的尺寸，并重新编码成
更小的 JPEG。尺寸约束是「总像素 ≤ 10,240,000 且短边 ≤ 1920」，两个约束取更严格者，
**只缩小、不放大**；按 EXIF 方向摆正后输出 JPEG。支持 Android / iOS / iPadOS /
Windows / macOS / Linux / Web。一次只处理一张图，输出统一为 JPEG（不保留透明通道）。

## 技术栈与版本

- Flutter 3.44.4（stable）/ Dart 3.12.2；`pubspec.yaml` 的 SDK 约束为 `^3.11.0`，
  版本号 `1.0.0+1`。
- 运行依赖：`image ^4.8.0`（解码 / 缩放 / 编码 / 卷积）、`image_picker ^1.2.1`（选图）、
  `file_picker ^11.0.2`（桌面「另存为」、Web 下载）、`gal ^2.3.3`（写系统相册）、
  `cupertino_icons ^1.0.8`。
- 开发依赖：`flutter_test`、`flutter_lints ^6.0.0`。
- `analysis_options.yaml` 只 `include: package:flutter_lints/flutter.yaml`，没有
  关闭或新增任何 lint 规则。
- **没有状态管理库**（无 provider / riverpod / bloc）：页面状态都在 `StatefulWidget`
  的 `setState` 里，跨页面共享靠构造参数传递。
- 平台 IO 只通过插件封装，业务代码不直接 `import 'dart:io'`。

## 目录结构与模块职责

### lib/（9 个文件）

| 文件 | 职责 |
| --- | --- |
| `lib/main.dart` | 应用入口与全部界面：`MomentsPhotoResizerApp`、`HomePage`（空状态 / 处理中 / 错误 / 选图）、`ResultView`（结果与左右对比、质量 / 锐化滑条、信息卡）、`_SettingsSheet`（二级「渲染设置」）。同时持有 `ImagePipeline`、`CompressionCache`，并调度后台补齐质量档位。 |
| `lib/image_resizer.dart` | CPU 实现。`ResizeConstraints`（`maxPixels = 10240000`、`maxShortSide = 1920`）、`ResizePlan`、`ResizedPhoto`、`ImageResizer`（`planResize` / `process` / `processAll`，多 isolate 批量渲染）。 |
| `lib/gpu_image_processor.dart` | GPU 实现。`GpuImageProcessor.processAll`：用 `dart:ui` 的 `instantiateImageCodec` 解码、`Canvas.drawImageRect` + `Picture.toImage` 缩放，读回 RGBA 后交给 CPU isolate 编码 JPEG；任何一步失败都抛异常，由 pipeline 回退。 |
| `lib/image_pipeline.dart` | 后端选择。`ImageBackend`、`BatchProcessor`、`ImagePipeline`：优先 GPU，失败时置 `_gpuUnavailable` 并只回调一次 `onGpuFallback`，后续直接走 CPU；`preferGpu` 对应界面开关，`backendLabel` 提供「GPU 加速 / CPU 多核」文案。 |
| `lib/compression_cache.dart` | 内存缓存。`CompressionKey` = 采样算法 + JPEG 质量 + 锐化；提供 `lookup` / `process` / `put` / `clear`。换原图、切换 GPU 开关时必须 `clear()`。 |
| `lib/sharpen_option.dart` | 锐化档位 `SharpenOption`（`none` / `light` / `standard` / `strong`，中文 label）与 3×3 卷积核；`applySharpen` 调 `img.convolution`。 |
| `lib/comparison_view.dart` | 对比与缩放视图：`ComparisonController`（缩放 / 平移，上限 3200%）、`ComparisonView`（左右同步对比）、`ComparisonZoomBar`、`SinglePhotoView`。 |
| `lib/photo_picker.dart` | 统一选图入口 `PhotoPicker.pickImage()`，返回 `PickedPhoto(bytes, name)`；用户取消返回 `null`，空文件抛 `ImagePickException`。只依赖 `dart:typed_data` 与 `image_picker`。 |
| `lib/photo_saver.dart` | 统一保存入口 `PhotoSaver.saveJpeg()`：移动端写系统相册，桌面 / Web 走另存为或浏览器下载。`debugUseGalleryOverride`、`debugGalleryWriter`、`debugFileWriter` 供测试注入。 |

### test/（8 个文件）

| 文件 | 覆盖范围 |
| --- | --- |
| `test/image_resizer_test.dart` | `planResize`（像素 / 短边 / 只缩不放）、`process`（采样算法、锐化、压缩、错误）、`processAll`（批量与进度）。 |
| `test/image_pipeline_test.dart` | GPU 优先、失败自动回退且只提示一次、关闭 GPU、重新开启可重试、`processOne`。 |
| `test/photo_saver_test.dart` | 平台分派、相册权限与错误映射、文件名规则（`debug*` 注入，无真实 IO）。 |
| `test/compression_cache_test.dart` | 缓存未命中、算法 / 质量 / 锐化三个维度分别命中与失效、`clear`、`put`。 |
| `test/comparison_view_test.dart` | 左右对比与共享变换、缩放比例显示、逐档缩放、上限 3200%。 |
| `test/result_view_test.dart` | 结果页模式切换、质量四点档、滑条松手才触发渲染、渲染方式信息卡、移动端触控板。 |
| `test/home_page_test.dart` | 选图器返回前保持界面、后台补齐质量档位、参数调整静默换图、锐化滑条冻结、二级菜单内容。 |
| `test/app_test.dart` | 首页冒烟测试（标题与唯一选图入口）。 |

## 开发命令

```powershell
flutter pub get
flutter analyze
flutter test
flutter run -d windows      # 也可 -d chrome / -d android / -d ios
```

桌面与 Web 构建（未在对应宿主平台上构建时，`flutter build` 会直接报错，属预期）：

```powershell
flutter build windows
flutter build macos
flutter build linux
flutter build web           # 必须保持可编译，验证没有误引入 dart:io
```

### Android 分架构 release APK（重要）

本机 PATH 上的 `java` 是 **JRE 25**（`jre-25.0.2.10-hotspot`），没有 `javac`，直接跑
Gradle 会失败。构建前必须把 `JAVA_HOME` 指向 **JDK 21**：

```powershell
$env:JAVA_HOME = 'C:\Program Files\Eclipse Adoptium\jdk-21.0.5.11-hotspot'
$env:Path = "$env:JAVA_HOME\bin;$env:Path"
javac -version              # 期望 javac 21.0.5

flutter build apk --release --split-per-abi
```

产物在 `build/app/outputs/flutter-apk/`：

- `app-arm64-v8a-release.apk`
- `app-armeabi-v7a-release.apk`
- `app-x86_64-release.apk`

（同目录还会有对应 `.sha1` 文件。）不加 `--split-per-abi` 时产出单个 `app-release.apk`。

**签名现状**：`android/app/build.gradle.kts` 的 `buildTypes.release` 使用
`signingConfigs.getByName("debug")`，即 release 包暂时复用 debug 签名。正式发布前必须
换成自己的 keystore 与 signingConfig，不要把这个配置当成可发布状态。

## 架构约束与代码约定

1. **平台 IO 只走 `PhotoPicker` / `PhotoSaver`。** 业务代码不得直接 `import 'dart:io'`
   或调用平台文件 API，否则 Web 端会编译失败。新增读取 / 保存能力时，扩这两个封装。
2. **只缩小、不放大。** 目标尺寸由 `ImageResizer.planResize` 按「总像素」和「短边」
   两个比例取小值并向下取整；原图已在限制内时 `ResizePlan.resized == false`，不得放大。
   相关默认值集中在 `ResizeConstraints`，改默认值要同步 README。
3. **GPU 失败自动回退 CPU。** GPU 路径抛异常后 `ImagePipeline` 负责回退并只提示一次，
   不要在下层吞异常或自行重试；用户重新开启 GPU 时用 `resetGpuAvailability()`。
4. **参数调整 = 后台静默重算 + 缓存。** 切换算法 / 质量 / 锐化 / GPU 时保留当前界面，
   完成后直接替换 `_result`；先查 `CompressionCache`，再决定是否渲染。缓存键是
   「算法 + 质量 + 锐化」，新增会影响输出像素的参数时必须扩展 `CompressionKey`，
   否则会命中过期结果。
5. **锐化滑条冻结。** 锐化渲染期间 `_sharpenLocked = true`，渲染完成后解锁，避免连续
   提交大量渲染作业；质量 / 锐化滑条只在松手后触发渲染。
6. **测试不碰真实平台。** 选图通过 `HomePage(pickImage: ...)` 注入；保存通过
   `PhotoSaver.debugUseGalleryOverride` / `debugGalleryWriter` / `debugFileWriter`；
   平台判断用 `debugDefaultTargetPlatformOverride`；GPU / CPU 用
   `ImagePipeline(gpuBatch:, cpuBatch:)` 注入替身。测试不得读写真实相册或文件系统。
7. 代码风格跟随 `flutter_lints`；注释与用户可见文案用中文。公开类 / 方法保留 `///` 文档，
   错误类型（`ImagePickException` / `ImageProcessingException` / `PhotoSaveException`）
   的 `message` 要能直接展示给用户。

## 提交规范

- 使用 Conventional Commits，**标题用中文祈使句**，一次提交只做一件事：
  - `feat: 支持按短边限制输出尺寸`
  - `fix: 修复 GPU 回退后仍重复尝试的问题`
  - `refactor: 抽出 PhotoSaver 平台分派`
  - `test: 覆盖后台补齐质量档位`
  - `chore: 升级 image 到 4.8.0`
  - `docs: 补充 Android 分架构构建说明`
- 按功能 / 模块**分批提交**，不要把格式化、重构和新功能混在同一次提交里；提交前先
  `git status` 确认没有误带构建产物或无关文件。
- 不提交 `build/`、`.dart_tool/`、`*.iml`、`.idea/`；这些已由根目录 `.gitignore`
  忽略。

## 修改代码后的检查清单

- [ ] `flutter analyze` 无 error / warning。
- [ ] `flutter test` 全部通过；改动的行为有对应测试，测试仍不依赖真实 IO。
- [ ] 涉及界面或渲染链路的改动，至少 `flutter run -d windows`（或 chrome）人工过一遍。
- [ ] 改动 `PhotoPicker` / `PhotoSaver` / 任何可能引入平台 API 的代码后，
      `flutter build web` 仍能编译。
- [ ] 涉及 Android 的改动，用上面 JDK 21 的命令重新 `flutter build apk --release
      --split-per-abi` 验证。
- [ ] `git status` 中没有 `build/`、`.dart_tool/`、keystore、签名密码等应忽略的内容。

## 需要人工确认的事项

以下内容不要由代理自行决定或补全，遇到时先问项目维护者：

1. **release 签名**：替换 debug 签名的 keystore 路径、别名、密码，以及是否使用
   `key.properties` / 环境变量；当前仓库没有正式签名配置。
2. **发布身份**：`applicationId = "net.isrecal.tuyaya"`、应用名「图压压」、版本号与
   `versionCode` 是否就是商店上架版本。
3. **应用商店信息**：各平台的图标、截图、描述、隐私政策、内容分级等物料不在仓库内，
   需人工提供。
4. **权限文案**：修改 `AndroidManifest.xml` 权限或 iOS `Info.plist` 用途说明前，需确认
   对应的审核要求（当前只有 Android `WRITE_EXTERNAL_STORAGE`（`maxSdkVersion=29`）
   与 iOS 相册读取 / 添加说明）。
5. **本机工具链路径**：`JAVA_HOME`、Flutter SDK（`android/local.properties` 里的
   `flutter.sdk`）与 Android SDK（`sdk.dir`）因机器而异，换机器时需按实际路径调整。
