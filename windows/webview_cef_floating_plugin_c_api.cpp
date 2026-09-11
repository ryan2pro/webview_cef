#include "include/webview_cef_floating/webview_cef_floating_plugin_c_api.h"

#include <flutter/plugin_registrar_windows.h>

#include "webview_cef_floating_plugin.h"

void WebviewCefFloatingPluginCApiRegisterWithRegistrar(
    FlutterDesktopPluginRegistrarRef registrar) {
  webview_cef_floating::WebviewCefFloatingPlugin::RegisterWithRegistrar(
      flutter::PluginRegistrarManager::GetInstance()
          ->GetRegistrar<flutter::PluginRegistrarWindows>(registrar));
}
