# 图压压（moments_photo_resizer）

把照片缩放到适合发朋友圈的尺寸，并重新编码成体积更小的 JPEG。基于 Flutter，
支持桌面端（Windows / Linux / macOS）、移动端（Android / iOS / iPadOS）和 Web。

## 功能

- 从系统相册 / 文件选择器选择一张图片；**选图期间保持当前界面**，等系统
  选择器返回图片后才进入渲染流程（移动端不会在相册还没关闭时就跳到「正在渲染」）；
- 自动缩小：**总像素量 ≤ 10,240,000（约 1024 万像素）** 且 `短边 ≤ 1920`，
  两个约束取更严格的那个；**只缩小、不放大**；
- **二级菜单（右上角「渲染设置」）**：采样算法与 GPU 加速收进这里；主界面保留
  结果 / 对比切换、缩放工具、JPEG 质量滑条和锐化滑条；
- **采样算法**：区域平均（默认）、双线性、双三次、最近邻；
- **锐化（一级菜单）**：主界面的锐化滑条提供关闭 / 轻度 / 标准 / 强四档，
  在缩放后应用 3×3 卷积核；滑条**松手后才开始渲染**，拖动过程中不会反复重算；
  **调整锐化后滑条会临时冻结**，后台渲染完成后自动解锁，避免连续提交过多渲染作业；
- **参数调整不打断操作**：切换算法 / 质量 / 锐化 / GPU 时**不会跳到「正在渲染」
  页面**，原界面（含预览、对比、缩放位置）保持不变，后台渲染完成后直接替换结果
  照片；顶部只显示一条细进度线；
- **后台渲染机制**：选图后先渲染当前组合并展示，随后自动在后台补齐**默认采样
  算法**（区域平均）的 60 / 75 / 85 / 95 全部质量档位；其他采样算法在切换过去时
  再渲染它的质量档位。已渲染的组合全部缓存在内存中，来回切换零计算；
- **GPU 加速**：解码与缩放交给 Flutter 引擎（Impeller / Skia）在 GPU 上完成，
  JPEG 编码交给多核 CPU isolate；GPU 不可用或失败时自动回退到纯 CPU 多核实现，
  界面会提示并在「渲染方式」中显示当前后端；可在二级菜单里手动关闭 GPU 加速；
- 按 EXIF 方向把照片摆正，竖拍照片不会「躺倒」；
- **JPEG 质量用滑条选择**：75 / 85 / 95 / 100（默认）四个推荐档位，松手后才渲染；
- **左右对比**：结果页可切换「结果 / 对比」，对比模式下左为原图、右为压缩后，
  两侧缩放与平移同步，可用按钮或手势放大到 **3200%** 查看细节，并实时显示缩放比例；
- **结果模式也能缩放**：单张结果同样支持按钮 / 滚轮 / 拖动缩放平移，最高 3200%；
- **移动端触控板**：仅 Android / iOS / iPadOS，下方的信息展示区可以作为
  「触控板」——单指拖动平移、双指捏合缩放上方的结果照片；
- 「保存图片」：移动端（Android / iOS / iPadOS）**直接把 JPEG 写入系统相册**
  （Android 存到 `Pictures`，iOS / iPadOS 存到「最近项目」），不弹保存对话框、
  也不需要用户选择路径；桌面端仍是系统「另存为」，Web 仍是浏览器下载。Android 10
  及以上不需要存储权限，Android 9 及以下首次保存会请求写外部存储权限。

## 目录结构

```
lib/
├── main.dart              # 应用入口与页面（空状态 / 处理中 / 结果页 / 二级设置菜单）
├── comparison_view.dart   # 左右对比视图 + 同步缩放（ComparisonController / ComparisonZoomBar）
├── compression_cache.dart # 按「采样算法 + 质量 + 锐化」缓存压缩结果
├── image_pipeline.dart    # GPU / CPU 后端选择，GPU 失败时自动回退
├── gpu_image_processor.dart # Flutter 引擎 GPU 解码 + 缩放，CPU isolate 编码
├── image_resizer.dart     # 尺寸计算 + CPU 解码/缩放/JPEG 编码 + 多核批量渲染
├── sharpen_option.dart    # 锐化档位与 3×3 卷积核
├── photo_picker.dart      # 统一选图（image_picker，各平台走系统选择器）
└── photo_saver.dart       # 统一保存（移动端写系统相册，桌面 / Web 走另存为）
test/
├── image_resizer_test.dart  # 尺寸规划、像素上限、采样算法、锐化、压缩与错误处理
├── image_pipeline_test.dart # GPU 优先、失败回退、开关与重试
├── photo_saver_test.dart    # 平台分派、相册权限 / 错误映射、文件名规则
├── compression_cache_test.dart # 算法 / 质量 / 锐化的缓存命中与失效
├── comparison_view_test.dart # 对比视图、同步缩放与比例显示
├── result_view_test.dart     # 结果页的模式切换 / 质量滑条 / 信息卡片
├── home_page_test.dart       # 选图时机、后台渲染进度、二级菜单、静默换图
└── app_test.dart             # 首页冒烟测试
```

## 开发

```powershell
flutter pub get
flutter run -d windows   # 或 chrome / android / ios ...
flutter analyze
flutter test
flutter build web        # 验证 Web 端可以编译
```

## 默认压缩参数

参数集中在 `lib/image_resizer.dart` 的 `ImageResizer` / `ResizeConstraints` 中：

| 参数 | 默认值 | 说明 |
| --- | --- | --- |
| `maxPixels` | 10,240,000 | 输出总像素量上限（约 1024 万像素） |
| `maxShortSide` | 1920 | 短边上限 |
| `jpegQuality` | 100 | JPEG 质量，滑条可选 75/85/95/100 |
| `interpolation` | `average` | 默认采样算法（区域平均） |
| `sharpen` | `none` | 锐化档位，默认关闭 |

目标尺寸按两个缩放比例取小值计算，并**向下取整**，保证输出像素量一定不超过
`maxPixels`。GPU 模式下四种采样算法分别对应引擎的滤波档位：最近邻 → none、
双线性 → low、区域平均 → medium、双三次 → high。

## 渲染后端

| 平台 | GPU 路径 | 回退 |
| --- | --- | --- |
| Windows / macOS / Linux | Impeller / Skia GPU 光栅化 | 自动回退多核 CPU |
| Android / iOS / iPadOS | Impeller / Skia GPU 光栅化 | 自动回退多核 CPU |
| Web | CanvasKit（WebGL） | 自动回退纯 Dart CPU 实现 |

- GPU 路径失败（例如平台强制软件渲染、`Picture.toImage` 不可用）时只提示一次，
  并在后续渲染中直接使用 CPU，避免反复尝试；
- 用户可在二级菜单「渲染设置」里关闭 GPU 加速，立即改用多核 CPU 重渲染；
- CPU 路径始终使用多 isolate 并行，并按照源图像素量限制并发数，避免大图解码
  同时占满内存。

## 图片读取与保存（各平台规范）

应用层只暴露两个封装的入口：
`PhotoPicker.pickImage()`（[lib/photo_picker.dart](lib/photo_picker.dart)）返回
`Uint8List` 字节，`PhotoSaver.saveJpeg()`（[lib/photo_saver.dart](lib/photo_saver.dart)）
移动端写入系统相册、桌面 / Web 通过系统保存流程写出字节。**两端都不依赖 `dart:io`**，
所以 Web 也能编译。

### 读取（选图）

| 平台 | 系统选择器 / 实现 | 返回内容 |
| --- | --- | --- |
| Android | `image_picker_android` → 系统文档选择器 `ACTION_GET_CONTENT`（SAF）；选图不需要存储权限 | 插件把选中内容复制到应用缓存目录后返回路径，代码立即 `readAsBytes` |
| iOS / iPadOS | iOS 14+ `PHPickerViewController`（仅图片过滤）；旧系统回退 `UIImagePickerController` | 资源导出到临时目录后返回路径，代码立即 `readAsBytes` |
| macOS | `image_picker_macos` → `file_selector_macos`（`NSOpenPanel`） | 返回文件路径 / 字节 |
| Windows | `image_picker_windows` → `file_selector_windows`（`IFileOpenDialog`） | 返回文件路径 / 字节 |
| Linux | `image_picker_linux` → `file_selector_linux`（GTK 文件选择器 / XDG Desktop Portal） | 返回文件路径 / 字节 |
| Web | `image_picker_for_web` → 隐藏的 `<input type="file" accept="image/*">` | `XFile.readAsBytes()` 读入内存（`path` 是 blob URL，不使用） |

要点：**不传 `imageQuality` / `maxWidth` / `maxHeight`**，避免插件做二次压缩或缩放；
编码、尺寸约束统一由应用自己的处理管线负责。用户取消返回 `null`，界面保持不变；
空文件或读取异常会抛出 `ImagePickException`。

### 保存（导出）

| 平台 | 保存流程 | 返回 / 说明 |
| --- | --- | --- |
| Android | `gal` → `MediaStore` 写入 `Pictures`；API ≤ 28 首次保存请求 `WRITE_EXTERNAL_STORAGE` | 不返回路径；Android 10+ 无需存储权限，直接写入系统相册 |
| iOS / iPadOS | `gal` → `PHPhotoLibrary`，仅申请「添加」权限（`NSPhotoLibraryAddUsageDescription`） | 写入「最近项目」；不弹保存 UI、不返回路径 |
| macOS | `NSSavePanel`（file_picker）选择路径，随后由 Dart 侧写入字节 | 需要沙盒 entitlement：`com.apple.security.files.user-selected.read-write`（已配置） |
| Windows | `IFileSaveDialog`（file_picker FFI）选择路径，随后由 Dart 侧写入字节 | 无特殊配置 |
| Linux | XDG Desktop Portal `SaveFile`（或 GTK 保存对话框）选择路径，随后由 Dart 侧写入字节 | 依赖桌面环境提供 XDG portal / GTK |
| Web | 生成 `Blob` + 隐藏 `<a download>` 触发浏览器下载 | 返回下载文件名；必须在用户点击手势内触发 |

要点：移动端（Android / iOS / iPadOS）保存**不弹保存 UI，也没有「取消」**，成功后
界面提示「已保存到系统相册」（Android 写入 `Pictures`，iOS / iPadOS 写入「最近项目」）；
桌面端仍走原生「另存为」对话框，Web 仍由浏览器下载，用户取消返回 `null`、不提示；
文件名统一补 `.jpg`。

### 平台配置要求

- **Android**：`AndroidManifest.xml` 已声明 `WRITE_EXTERNAL_STORAGE`
  （`android:maxSdkVersion="29"`），仅 Android 9 及以下首次保存时运行时请求；
  Android 10 及以上无需存储权限；选图走 SAF，不需要 `READ_MEDIA_IMAGES`。
- **iOS / iPadOS**：`ios/Runner/Info.plist` 已声明 `NSPhotoLibraryUsageDescription`
  （选图用）与 `NSPhotoLibraryAddUsageDescription`（把照片添加到相册用，仅「添加」
  权限）；iPadOS 与 iOS 共用同一套实现，系统自动以模态呈现。
- **macOS**：`Release.entitlements` / `DebugProfile.entitlements` 已开启
  `com.apple.security.files.user-selected.read-write`。
- **Windows / Linux / Web**：无权限声明要求。

## 已知限制

- 输出统一为 JPEG，不保留透明通道或原始格式；
- 一次只处理一张图片；
- 移动端保存位置固定为系统相册、不提供选择目录（Android 为 `Pictures`，
  iOS / iPadOS 为「最近项目」）；
- GPU 路径与 CPU 路径的像素级结果会有极小差异（引擎滤波与色彩空间不同），
  体积可能相差几个百分点。
