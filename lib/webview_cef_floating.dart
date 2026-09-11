/// Embeds a CEF (Chromium Embedded Framework) browser in a Flutter Windows
/// desktop application as a real native child window.
///
/// The browser is not rendered into a Flutter texture: CEF creates a genuine
/// child HWND that the operating system composites on top of the Flutter view,
/// and Dart keeps its position, size and visibility in sync with the layout box
/// reserved by [CefWindowedView].
///
/// ```dart
/// import 'package:webview_cef_floating/webview_cef_floating.dart';
///
/// CefWindowedView(
///   url: 'https://example.com',
///   visible: true,
/// );
/// ```
library;

export 'src/native/cef_native_controller.dart' show CefNativeController;
export 'src/widgets/cef_windowed_view.dart' show CefViewGeometry, CefWindowedView;
