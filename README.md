# webview_cef_floating

在 Flutter Windows 桌面应用中嵌入 CEF（Chromium Embedded Framework）网页视图的 **Flutter 插件**。

网页由一个真正的 **原生子窗口（HWND）** 承载，由系统合成后叠在 Flutter 内容之上（窗口化渲染 / windowed rendering），
Dart 侧逐帧同步它的位置、大小与显隐。

```
┌─ Flutter 窗口 ─────────────────────────────────┐
│  Flutter 内容（由 Skia/Impeller 绘制）          │
│  ┌─ CEF 原生子窗口（由系统合成，永远在最上层）─┐ │
│  │  Chromium 真实渲染的网页                   │ │
│  └────────────────────────────────────────────┘ │
│  Flutter 内容                                   │
└────────────────────────────────────────────────┘
```

## 宿主零改动

宿主应用只需要三件事：

1. 在 `pubspec.yaml` 中依赖本插件；
2. 执行一次插件自带的 `windows/scripts/fetch_cef.ps1` 获取 CEF 二进制；
3. 在页面里放一个 `CefWindowedView`。

`windows/runner/` 下的 `main.cpp`、`flutter_window.cpp`、`win32_window.cpp` 与
`windows/runner/CMakeLists.txt` **保持 `flutter create` 原样，不需要出现任何 CEF 代码**，
也不需要手工把 CEF 接入 CMake。CEF 的引导、宿主窗口接管、关闭，以及 CEF 运行时的部署，全部由插件自己完成。

```yaml
dependencies:
  webview_cef_floating:
    path: ../webview_cef_floating   # 或 git / pub 依赖
```

```dart
import 'package:webview_cef_floating/webview_cef_floating.dart';

CefWindowedView(url: 'https://example.com');
```

## 为什么选窗口化渲染

网页由一个真正的子 HWND 承载，因此：

- 视频、Canvas、WebGL 走浏览器原生合成路径，性能与稳定性更好；
- 输入法、右键菜单、拖拽、无障碍等原生行为完整；
- 不需要把像素从 GPU 回传到 Flutter 纹理，省掉一次拷贝与合成。

代价是**原生窗口永远绘制在 Flutter 内容之上**，无法被 Flutter 裁剪、设置圆角或透明度，也
不受 Flutter 的层级（z-order）控制。这是方案的固有特性，不是缺陷，详见下文
[窗口化渲染的固有限制](#窗口化渲染的固有限制)。

## 环境要求

| 依赖 | 版本 | 说明 |
| --- | --- | --- |
| Flutter | 3.47.0 stable 及以上 | 仅支持 Windows 桌面目标 |
| Visual Studio | 2022（含「使用 C++ 的桌面开发」工作负载） | CEF 150 要求 C++20 |
| Windows SDK | 10.0.22621 及以上 | 实测 10.0.26100 可用 |
| CEF | 150.0.20+ga832838+chromium-150.0.7871.253 | 由脚本自动下载，仅 x64 |

## 快速开始

### 1. 获取 CEF 二进制分发包

CEF 分发包约 350 MB，未纳入版本库（见 `.gitignore`），需先下载：

```powershell
powershell -ExecutionPolicy Bypass -File <插件目录>/windows/scripts/fetch_cef.ps1
```

脚本行为：

- 从 `cef-builds.spotifycdn.com` 下载 **standard** 分发包（`minimal` 包缺少
  `libcef_dll_wrapper` 源码，无法编译）；
- 校验 SHA1（期望值优先从官方构建索引实时解析，离线时回退到内置校验值）；
- 用系统自带的 `bsdtar` 解压 `.tar.bz2` 到插件内的 `third_party/cef`，无需额外安装 7-Zip；
- 下载支持断点续传（写入 `.part` 后校验再改名）；
- **幂等**：已安装且版本一致时直接跳过；`-Force` 可强制重下；
  `-Version <版本号>` 可切换到其他 CEF 分支。

### 2. 运行

```powershell
cd example
flutter run -d windows
```

首次构建需要从源码编译 `libcef_dll_wrapper`（数百个翻译单元），耗时较长；后续为增量构建。

## 架构

```
宿主 app（example，runner 保持原样）        插件原生侧                          外部
──────────────────────────────────         ──────────                          ────
flutter create 原样 runner
  RegisterPlugins(engine)
  （进程主线程）           ───────────────▶ webview_cef_floating_plugin.dll
                                            ├─ cef_bridge_initialize ─────────▶ CefInitialize
                                            ├─ Registrar::GetView()->HWND ────▶ browser 的父窗口
                                            └─ 观察顶层窗口过程（WM_DESTROY）
                                                     │
                                                     ▼
                                               cef_bridge_shutdown
Dart                                        webview_cef_floating_cef.dll
────                                        ─────────────────────────────
CefWindowedView                             CefPostTask(TID_UI)
  占位区域 + 每帧采样矩形                        │
        │ 每帧几何                              ▼
        ▼                                   CEF 浏览器子窗口 HWND
  CefNativeController ──dart:ffi──────────▶      ▲
                                                 │
                          webview_cef_floating_subprocess.exe
                          （renderer / GPU / utility / zygote）
```

### 三个原生目标，以及为什么必须拆开

| 目标 | 内容 | 编译设置 |
| --- | --- | --- |
| `webview_cef_floating_plugin.dll` | Flutter 插件薄壳：注册回调、自举、宿主窗口、生命周期 | Flutter 的 `apply_standard_settings()`（`/W4 /WX /EHsc`），**不包含任何 CEF 头文件** |
| `webview_cef_floating_cef.dll` | CEF 实现：槽位表、浏览器生命周期、窗口化渲染 | CEF 的 `SET_LIBRARY_TARGET_PROPERTIES()`（`/std:c++20 /GR- _HAS_EXCEPTIONS=0`，并 delay-load `libcef.dll`） |
| `webview_cef_floating_subprocess.exe` | CEF 子进程宿主 | 同 CEF |

不能合并成一个目标：CEF 头文件要求 `/std:c++20 /GR- _HAS_EXCEPTIONS=0`，与 Flutter 插件薄壳需要的
`/W4 /WX /EHsc` 互斥；而 CEF 的 delay-load 链接参数写在 target 级的 legacy `LINK_FLAGS` 上，**不会传播**给链接它的使用者。
把 CEF 全部关进独立 DLL 之后，插件薄壳永远看不到 CEF 头文件，宿主才能继续使用默认的编译设置。

### 为什么用独立的 helper.exe 取代 `wWinMain` 里的子进程判定

CEF 常规用法要求应用自己的入口点**最早**调用 `CefExecuteProcess`（renderer / GPU / utility 进程是同一个 exe 被重新拉起）。
插件无法插入宿主的 `wWinMain`，因此改为把 `CefSettings::browser_subprocess_path` 指向
`webview_cef_floating_subprocess.exe`：该设置一旦非空，宿主 exe 就再也不会被当作子进程重启。

于是宿主的入口点可以完全保持原样，同时子进程仍然由独立的、极简的 CEF 程序承载：

```cpp
int APIENTRY wWinMain(HINSTANCE instance, ...) {
  CefMainArgs main_args(instance);
  return CefExecuteProcess(main_args, CefRefPtr<CefApp>(), nullptr);
}
```

实测：运行 example 时 5 个子进程全部由该 helper 承载，宿主 exe 的进程实例数始终为 1。

### 引导与关闭的时机

| 阶段 | 位置 | 说明 |
| --- | --- | --- |
| 初始化 | 插件注册回调 `RegisterWithRegistrar` | Flutter 在 `FlutterWindow::OnCreate()` 中调用它，而后者由 `wWinMain` 同步调用，因此**正处于进程主线程**，满足 `CefInitialize` 的线程要求 |
| 宿主窗口 | 同上 + 每次顶层窗口消息 | `PluginRegistrarWindows::GetView()->GetNativeWindow()`，等价于原来手写在 `flutter_window.cpp` 里的那两行 |
| 关闭 | ① 顶层窗口 `WM_DESTROY` ② 插件析构（引擎拆除） ③ CRT `atexit` 兜底 | 三条路径都可能触发，`cef_bridge_shutdown()` **幂等** |

`cef_bridge.dll` 的 `DllMain(DLL_PROCESS_DETACH)` **刻意不调用** `CefShutdown`：该回调在 loader lock 下执行，
而 CEF 的拆卸会加载/卸载模块，在此锁内会死锁。它只在检测到进程未正常关闭 CEF 时输出一条调试信息。

### 缓存目录按宿主隔离

CEF 120+ 会依据 `CefSettings.root_cache_path` 生成进程单例锁，因此同一路径只能被一个进程使用。
插件按宿主 exe 名推导缓存目录：

```
%LOCALAPPDATA%\<宿主 exe 文件名>\cef_cache
```

这样多个应用同时嵌入本插件时不会因为锁冲突导致第二个进程初始化失败
（取不到 `LOCALAPPDATA` 时回退到 exe 同目录下的 `cef_cache`）。

### 线程模型

Flutter 的 root isolate 运行在引擎 UI 线程上，而宿主入口与窗口过程在进程主线程——Dart 的 FFI 调用天然发生在非主线程。
因此 CEF 以 `multi_threaded_message_loop = true` 初始化，由 CEF 自建 UI 线程与消息泵，与 Flutter 的消息循环彻底解耦。

所有来自 Dart 的调用只会在互斥锁保护下修改槽位表，然后把真正的 CEF 操作通过
`CefPostTask(TID_UI, ...)` 投递到 CEF 的 UI 线程。`CefPostTask` 保证同目标线程的 FIFO 顺序，
所以「先 create 后 setBounds」的顺序不会被打破；而在浏览器创建完成前到达的几何/显隐请求会
被缓存，并在 `OnAfterCreated` 中回放，不会丢失。

### 几何同步语义

- Dart 侧用 `GlobalKey` + `RenderBox.localToGlobal` 得到占位区域相对 Flutter 视图的**逻辑**
  矩形，再乘以 `devicePixelRatio` 转为**物理像素**；
- 逻辑→物理的换算**只在 Dart 侧发生一次**，原生层不做任何二次换算；
- 浏览器的父窗口取 **Flutter 视图 HWND**，其客户区原点即 Flutter 逻辑坐标原点，因此无需补偿
  非客户区偏移；
- `CefWindowedView` 在每帧渲染后采样一次几何，只有变化超过 1px 阈值时才跨 FFI，布局静止时
  零开销。

覆盖的场景：滚动、窗口拖动、窗口缩放、DPI 变化（跨显示器）、窗口最小化、列表回收导致组件
卸载。

## 公开接口

`package:webview_cef_floating/webview_cef_floating.dart` 导出：

### `CefWindowedView`

| 参数 | 类型 | 说明 |
| --- | --- | --- |
| `url` | `String` | 创建时加载的地址，变化时会触发导航 |
| `visible` | `bool` | 是否允许显示。被 Flutter 内容遮挡时必须置为 `false` |
| `hideWhenClipped` | `bool` | 默认 `true`，区域未完整可见时自动隐藏，避免溢出到无关内容上 |
| `placeholderColor` | `Color?` | 底层占位块颜色 |
| `onGeometryChanged` | `ValueChanged<CefViewGeometry>?` | 几何变化回调（含 slot、逻辑/物理矩形、可见性） |

### `CefNativeController`

`CefNativeController.instance()` 返回控制器，或在原生桥接不可用时返回 `null`（非 Windows 平台、
缺少原生库、或 CEF 初始化失败）。缺失时应用正常降级为占位渲染，不会崩溃。

```dart
final controller = CefNativeController.instance();
final slot = controller.createBrowser(bounds: physicalRect, url: 'https://example.com');
controller.setBounds(slot: slot, bounds: newRect);
controller.setVisible(slot: slot, visible: false);
controller.loadUrl(slot: slot, url: 'https://flutter.dev');
controller.destroyBrowser(slot: slot);
```

## 窗口化渲染的固有限制

1. **永远位于最上层**：原生子窗口不受 Flutter 层级控制。路由跳转、`Dialog`、`Drawer` 等覆盖
   该区域时，必须通过 `CefWindowedView.visible = false` 主动隐藏，否则网页会浮在弹窗之上。
2. **无法裁剪**：部分滚出视口的原生窗口会溢出到其他 Flutter 内容上，不会像普通 Widget 那样
   被 `ClipRect` 裁掉。`hideWhenClipped: true` 用「未完整可见即隐藏」来规避。
3. **不支持圆角/透明度/变换**：`borderRadius`、`Opacity`、`Transform` 都不会作用到网页上。
4. **列表回收会重建浏览器**：占位组件被滚出 `cacheExtent` 后会被销毁，浏览器随之关闭，滚回时
   重新创建（表现为页面重新加载）。

## 已知的后续加固项

- **沙箱未启用**：当前使用 `CefSettings.no_sandbox = true`。CEF 的沙箱构建会把宿主变成由
  `bootstrap.exe` 启动的 DLL，与 Flutter runner 的布局不兼容。生产环境应重新评估沙箱方案，
  或对加载的地址做白名单限制。
- **交互类 API 未实现**：前进/后退/刷新、加载状态与标题回调、JS 执行等尚未暴露，目前仅有
  `loadUrl`。
- **未做窗口区域裁剪**：可通过 `SetWindowRgn` 让部分滚出视口的区域被裁剪，替代当前的隐藏策略。
- **恶意退出路径**：宿主若以 `TerminateProcess` 之类的非正常方式结束进程，CEF 不会被拆卸，
  只能靠 `DllMain` 输出一条调试信息提示。

## 目录结构

```
webview_cef/                                 # 插件根（pubspec: webview_cef_floating）
├── lib/
│   ├── webview_cef_floating.dart           公共 API barrel
│   └── src/
│       ├── native/
│       │   ├── cef_ffi_bindings.dart       dart:ffi 绑定与原生库解析
│       │   └── cef_native_controller.dart  高层控制器与降级逻辑
│       └── widgets/
│           ├── cef_geometry.dart           几何换算纯函数（可单测）
│           └── cef_windowed_view.dart      几何同步组件
├── test/src/widgets/cef_geometry_test.dart
├── example/                                最小接入示例（演示页 + runner 原样的 app）
├── third_party/cef/                        下载的 CEF 分发包（未纳入版本库）
└── windows/
    ├── CMakeLists.txt                      三个原生目标的构建与 CEF 运行时部署
    ├── webview_cef_floating_plugin.h/.cpp  插件入口：自举 CEF、接管宿主窗口与生命周期
    ├── webview_cef_floating_plugin_c_api.cpp
    ├── include/webview_cef_floating/
    │   └── webview_cef_floating_plugin_c_api.h
    ├── cef/
    │   ├── cef_bridge.h / .cpp             纯 C ABI 桥接层（编译为 webview_cef_floating_cef.dll）
    │   └── cef_app.h / .cpp                CefClient 与生命周期回调
    ├── subprocess/main.cpp                  CEF 子进程宿主（webview_cef_floating_subprocess.exe）
    └── scripts/fetch_cef.ps1               CEF 下载脚本
```

## 开发本插件

```powershell
# 插件本体
flutter analyze
flutter test

# 示例应用（example 存在时 pub 会要求它自己也有 package_config）
cd example
flutter pub get
flutter run -d windows
```

## 排查

| 现象 | 原因与处理 |
| --- | --- |
| 只显示灰色占位块，提示桥接不可用 | 原生库或 `libcef.dll` 不在 exe 同目录，或 CEF 初始化失败。确认产物目录下有 `webview_cef_floating_plugin.dll`、`webview_cef_floating_cef.dll`、`libcef.dll` 与 `locales/` |
| 网页始终不出现，只有占位块 | CEF 已加载但浏览器未能创建。检查 `CefNativeController.instance()` 是否为 null，以及占位区域是否真的进入了可视范围 |
| CMake 报错 `CEF binary distribution not found` | 未下载 CEF，先运行 `windows/scripts/fetch_cef.ps1` |
| 网页加载失败（`ERR_*`） | 检查网络与代理；`%LOCALAPPDATA%\<宿主 exe 名>\cef_cache` 需可写 |
| 反复提示 `webview_cef_floating_subprocess.exe` 找不到 | 子进程宿主没有部署到 exe 同目录；用调试器查看 `cef_bridge: sub-process helper not found` 输出 |
| 弹窗/路由被网页遮挡 | 预期行为，需将该区域的 `CefWindowedView.visible` 置为 `false` |
| 退出后调试输出 `process exited before CEF was shut down` | 宿主以非正常方式结束了进程（例如 `TerminateProcess`），CEF 未被拆卸 |
| `pub did not create example/.dart_tools/package_config.json` | 在插件根执行 `pub get` 时 example 也必须能解析；先 `cd example; flutter pub get` |
| 构建报 MSVC 工具集不兼容 | 升级 VS 2022 / Windows SDK，或用 `-Version` 切换到更旧的 CEF stable 分支 |
