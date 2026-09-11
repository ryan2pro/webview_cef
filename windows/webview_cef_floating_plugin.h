#ifndef FLUTTER_PLUGIN_WEBVIEW_CEF_FLOATING_PLUGIN_H_
#define FLUTTER_PLUGIN_WEBVIEW_CEF_FLOATING_PLUGIN_H_

#include <flutter/plugin_registrar_windows.h>

#include <optional>

namespace webview_cef_floating {

/// Brings CEF up inside the host process and keeps the embedded browser windows
/// parented to the Flutter view.
///
/// This class is the whole host integration. The host application's runner keeps
/// its stock entry point and window procedure, because everything CEF needs at
/// process level happens here or in the dedicated sub-process host executable.
class WebviewCefFloatingPlugin : public flutter::Plugin {
 public:
  static void RegisterWithRegistrar(flutter::PluginRegistrarWindows* registrar);

  explicit WebviewCefFloatingPlugin(flutter::PluginRegistrarWindows* registrar);

  ~WebviewCefFloatingPlugin() override;

  // Disallow copy and assign.
  WebviewCefFloatingPlugin(const WebviewCefFloatingPlugin&) = delete;
  WebviewCefFloatingPlugin& operator=(const WebviewCefFloatingPlugin&) = delete;

 private:
  /// Window procedure delegate handed to the registrar. Static because the
  /// delegate outlives nothing: it only forwards to the live instance, which is
  /// looked up through a pointer that the destructor clears.
  static std::optional<LRESULT> ObserveWindowProc(HWND hwnd,
                                                 UINT message,
                                                 WPARAM wparam,
                                                 LPARAM lparam);

  /// Publishes the Flutter view window to the bridge, resolving it first when it
  /// is not known yet.
  void EnsureHostWindow();

  /// Never claims a message. It only observes the top level window so that
  /// browsers can be closed before the view window they are parented to is gone,
  /// which the host runner offers no other hook for.
  std::optional<LRESULT> OnWindowProc(HWND hwnd,
                                     UINT message,
                                     WPARAM wparam,
                                     LPARAM lparam);

  flutter::PluginRegistrarWindows* registrar_;

  /// Flutter view window browsers are parented to, once it has been resolved.
  HWND host_window_ = nullptr;
};

}  // namespace webview_cef_floating

#endif  // FLUTTER_PLUGIN_WEBVIEW_CEF_FLOATING_PLUGIN_H_
