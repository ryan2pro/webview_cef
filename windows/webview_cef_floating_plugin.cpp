#include "webview_cef_floating_plugin.h"

#include <windows.h>

#include <memory>
#include <optional>

#include "cef/cef_bridge.h"

namespace webview_cef_floating {

namespace {

/// Registration happens exactly once per process. A second call would try to
/// initialize CEF twice, which CEF does not allow.
bool g_registered = false;

/// The instance handed to the registrar. Nulled on destruction so the window
/// procedure observation below can never reach a freed object.
WebviewCefFloatingPlugin* g_plugin = nullptr;

}  // namespace

// static
std::optional<LRESULT> WebviewCefFloatingPlugin::ObserveWindowProc(
    HWND hwnd,
    UINT message,
    WPARAM wparam,
    LPARAM lparam) {
  // Flutter only dispatches window procedure delegates through the engine, and
  // the host runner stops doing that as soon as its view controller is gone -
  // the same moment this plugin is destroyed. The null check keeps that from
  // being a lifetime assumption.
  WebviewCefFloatingPlugin* plugin = g_plugin;
  if (plugin == nullptr) {
    return std::nullopt;
  }
  return plugin->OnWindowProc(hwnd, message, wparam, lparam);
}

// static
void WebviewCefFloatingPlugin::RegisterWithRegistrar(
    flutter::PluginRegistrarWindows* registrar) {
  if (g_registered) {
    return;
  }
  g_registered = true;

  // Flutter registers plugins from the host runner's window creation path, which
  // runs on the process main thread - exactly where CEF has to be initialized.
  // Doing it here, rather than in the host's entry point, is what lets a host
  // application embed a browser without touching any of its runner files.
  if (cef_bridge_initialize(::GetModuleHandleW(nullptr)) == 0) {
    // libcef.dll is missing or unloadable. Dart reaches the same conclusion and
    // falls back to rendering the placeholder widget instead of crashing.
    return;
  }

  auto plugin = std::make_unique<WebviewCefFloatingPlugin>(registrar);
  plugin->EnsureHostWindow();

  g_plugin = plugin.get();

  // Browsers must be closed while the view window still exists, and the C API
  // offers no "the host's message loop has exited" hook, so the top level window
  // is the earliest point the plugin can observe. The plugin's destructor and the
  // bridge's own CRT exit hook cover the paths this never sees.
  registrar->RegisterTopLevelWindowProcDelegate(
      &WebviewCefFloatingPlugin::ObserveWindowProc);

  registrar->AddPlugin(std::move(plugin));
}

WebviewCefFloatingPlugin::WebviewCefFloatingPlugin(
    flutter::PluginRegistrarWindows* registrar)
    : registrar_(registrar) {}

WebviewCefFloatingPlugin::~WebviewCefFloatingPlugin() {
  if (g_plugin == this) {
    g_plugin = nullptr;
  }

  // Runs when the engine tears down. Browsers are released before the library
  // leaves the process, and the call is idempotent, so it is fine for the window
  // procedure observation or the CRT exit hook to have shut CEF down already.
  cef_bridge_set_host_window(nullptr);
  cef_bridge_shutdown();
}

void WebviewCefFloatingPlugin::EnsureHostWindow() {
  if (host_window_ != nullptr && ::IsWindow(host_window_)) {
    return;
  }

  flutter::FlutterView* view = registrar_->GetView();
  if (view == nullptr) {
    return;
  }

  const HWND view_window = view->GetNativeWindow();
  if (view_window == nullptr) {
    // The registrar can exist slightly before the view window is created; the
    // next top level window message retries.
    return;
  }

  host_window_ = view_window;

  // Browsers are parented to the Flutter view window rather than to the top
  // level window. That makes browser coordinates share the Flutter coordinate
  // origin, so no non-client-area offset has to be compensated for when Dart
  // pushes geometry.
  cef_bridge_set_host_window(view_window);
}

std::optional<LRESULT> WebviewCefFloatingPlugin::OnWindowProc(HWND hwnd,
                                                             UINT message,
                                                             WPARAM wparam,
                                                             LPARAM lparam) {
  switch (message) {
    case WM_DESTROY:
      // The view window is about to go away, so every browser has to be closed
      // before it does. The message is still not claimed: the host runner has to
      // run its own teardown afterwards.
      host_window_ = nullptr;
      cef_bridge_set_host_window(nullptr);
      cef_bridge_shutdown();
      break;

    default:
      // Only runs while the view window is still unknown, so the cost is a single
      // null check once the plugin has settled.
      if (host_window_ == nullptr) {
        EnsureHostWindow();
      }
      break;
  }

  return std::nullopt;
}

}  // namespace webview_cef_floating
