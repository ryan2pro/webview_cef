# webview_cef

在 Flutter Windows 桌面应用中嵌入 CEF（Chromium Embedded Framework）网页视图。

本工程使用 **窗口化渲染（windowed rendering）**，而不是离屏渲染（OSR）：CEF 创建一个真实
的原生 Win32 子窗口（HWND），贴靠嵌入到 Flutter 视图之上，由 Dart 侧逐帧同步几何信息来驱动
它的位置、大小与显隐。

```
┌─ Flutter 窗口 ─────────────────────────────────┐
│  Flutter 内容（由 Skia/Impeller 绘制）          │
│  ┌─ CEF 原生子窗口（由系统合成，永远在最上层）─┐ │
│  │  Chromium 真实渲染的网页                   │ │
│  └────────────────────────────────────────────┘ │
│  Flutter 内容                                   │
└────────────────────────────────────────────────┘
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
| Flutter | 3.47.0 stable 及以上 | 需要启用 Windows 桌面支持 |
| Visual Studio | 2022（含「使用 C++ 的桌面开发」工作负载） | CEF 150 要求 C++20 |
| Windows SDK | 10.0.22621 及以上 | 实测 10.0.26100 可用 |
| CEF | 150.0.20+ga832838+chromium-150.0.7871.253 | 由脚本自动下载 |

## 快速开始

### 1. 获取 CEF 二进制分发包

CEF 分发包约 350 MB，未纳入版本库（见 `.gitignore`），需先下载：

```powershell
powershell -ExecutionPolicy Bypass -File windows/scripts/fetch_cef.ps1
```

脚本行为：

- 从 `cef-builds.spotifycdn.com` 下载 **standard** 分发包（`minimal` 包缺少
  `libcef_dll_wrapper` 源码，无法编译）；
- 校验 SHA1（期望值优先从官方构建索引实时解析，离线时回退到内置校验值）；
- 用系统自带的 `bsdtar` 解压 `.tar.bz2` 到 `third_party/cef`，无需额外安装 7-Zip；
- 下载支持断点续传（写入 `.part` 后校验再改名）；
- **幂等**：已安装且版本一致时直接跳过；`-Force` 可强制重下；
  `-Version <版本号>` 可切换到其他 CEF 分支。

### 2. 运行

```powershell
flutter run -d windows
```

首次构建需要从源码编译 `libcef_dll_wrapper`（数百个翻译单元），耗时较长；后续为增量构建。

## 架构

```
Dart (lib/src)                        原生 (windows/runner)
─────────────                         ─────────────────────
CefWindowedView                       webview_cef.exe
  占位区域 + 每帧采样矩形                 wWinMain
        │                                 ├─ cef_bridge_execute_process  子进程判定
        ▼                                 ├─ cef_bridge_initialize       CefInitialize
  CefNativeController                     └─ cef_bridge_shutdown         CefShutdown
        │ 物理像素矩形                            ▲
        ▼                                        │ 引导
  cef_ffi_bindings ──dart:ffi──▶ cef_bridge.dll ──┘
                                       │ CefPostTask(TID_UI)
                                       ▼
                                  CEF UI 线程
                                  槽位表 + pending 几何回放
                                       │ SetAsChild / SetWindowPos
                                       ▼
                                  CEF 原生子窗口 HWND（父窗口 = Flutter 视图）
```

### 为什么另建一个 `cef_bridge.dll`

Dart FFI 必须加载一个动态库，而应用主体是 `.exe`。因此把全部 CEF 逻辑编译成独立的
`cef_bridge.dll`：

- **exe 侧**在 `wWinMain` 早期同步调用它完成 CEF 引导（子进程判定、初始化、退出时关闭）；
- **Dart 侧**通过 FFI 加载同一个 DLL，在运行期创建/移动/显隐/销毁浏览器。

`cef_bridge.h` 是双方共用的**纯 C ABI 契约，且不包含任何 CEF 头文件**，因此 runner exe 仍可
安全地启用 Flutter 默认的 `/W4 /WX`。

### 线程模型

Flutter 的 root isolate 运行在引擎 UI 线程上，而 `wWinMain` 的消息循环在进程主线程——Dart
的 FFI 调用天然发生在非主线程。因此 CEF 以 `multi_threaded_message_loop = true` 初始化，
由 CEF 自建 UI 线程与消息泵，与 Flutter 的消息循环彻底解耦。

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
缺少 `cef_bridge.dll`、或 DLL 与头文件版本不匹配）。缺失时应用正常降级为占位渲染，不会崩溃。

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

## 目录结构

```
webview_cef/
├── lib/
│   ├── main.dart                          演示页：地址栏、显隐开关、几何信息面板、全屏覆盖层
│   └── src/
│       ├── native/
│       │   ├── cef_ffi_bindings.dart      dart:ffi 绑定与 DLL 解析
│       │   └── cef_native_controller.dart 高层控制器与降级逻辑
│       └── widgets/
│           ├── cef_geometry.dart          几何换算纯函数（可单测）
│           └── cef_windowed_view.dart     几何同步组件
├── test/src/widgets/cef_geometry_test.dart
├── windows/
│   ├── scripts/fetch_cef.ps1              CEF 下载脚本
│   ├── CMakeLists.txt                     接入 CEF 的 CMake 配置
│   └── runner/
│       ├── cef_bridge.h / .cpp            纯 C ABI 桥接层（编译为 cef_bridge.dll）
│       ├── cef_app.h / .cpp               CefClient 与生命周期回调
│       ├── main.cpp                       CEF 引导 + 消息循环
│       ├── flutter_window.cpp / .h        把 Flutter 视图 HWND 交给桥接层
│       └── win32_window.cpp / .h          未改动：CEF 子窗口挂在 Flutter 视图下，不受其管理
└── third_party/cef/                       下载的 CEF 分发包（未纳入版本库）
```

## 排查

| 现象 | 原因与处理 |
| --- | --- |
| 只显示灰色占位块，提示桥接不可用 | `cef_bridge.dll` 或 `libcef.dll` 不在 exe 同目录。确认构建产物目录下有这些文件 |
| CMake 报错 `CEF binary distribution not found` | 未下载 CEF，先运行 `windows/scripts/fetch_cef.ps1` |
| 网页加载失败（`ERR_*`） | 检查网络与代理；`%LOCALAPPDATA%\webview_cef\cef_cache` 需可写 |
| 弹窗/路由被网页遮挡 | 预期行为，需将该区域的 `CefWindowedView.visible` 置为 `false` |
| 构建报 MSVC 工具集不兼容 | 升级 VS 2022 / Windows SDK，或用 `-Version` 切换到更旧的 CEF stable 分支 |
