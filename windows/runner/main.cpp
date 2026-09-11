#include <flutter/dart_project.h>
#include <flutter/flutter_view_controller.h>
#include <windows.h>

#include <string>
#include <vector>

#include "cef_bridge.h"
#include "flutter_window.h"
#include "utils.h"

namespace {

/// Converts \p value to UTF-8, which is the encoding the CEF API expects.
std::string ToUtf8(const std::wstring& value) {
  if (value.empty()) {
    return std::string();
  }
  const int wide_length = static_cast<int>(value.size());
  const int size = ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(), wide_length,
                                         nullptr, 0, nullptr, nullptr);
  if (size <= 0) {
    return std::string();
  }
  std::string result(static_cast<size_t>(size), '\0');
  ::WideCharToMultiByte(CP_UTF8, 0, value.c_str(), wide_length, &result[0], size,
                        nullptr, nullptr);
  return result;
}

/// Returns the per-user cache directory handed to CEF.
///
/// CEF 120+ derives a process singleton lock from CefSettings.root_cache_path,
/// so the path has to be stable across runs and unique per application.
std::string GetCefCacheRootPath() {
  std::wstring base_path;

  wchar_t buffer[MAX_PATH] = {};
  const DWORD length =
      ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    base_path.assign(buffer, length);
  } else {
    // Fall back to the directory holding the executable.
    wchar_t module_path[MAX_PATH] = {};
    const DWORD module_length =
        ::GetModuleFileNameW(nullptr, module_path, MAX_PATH);
    if (module_length == 0 || module_length >= MAX_PATH) {
      return std::string();
    }
    const std::wstring module(module_path, module_length);
    const size_t separator = module.find_last_of(L"\\/");
    if (separator == std::wstring::npos) {
      return std::string();
    }
    base_path = module.substr(0, separator);
  }

  base_path += L"\\webview_cef\\cef_cache";
  return ToUtf8(base_path);
}

}  // namespace

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE prev,
                      _In_ wchar_t *command_line, _In_ int show_command) {
  // CEF has to see the command line before anything else happens. Renderer, GPU
  // and utility processes re-enter this very entry point and are expected to run
  // CEF's sub-process logic and exit without touching Flutter at all.
  const int cef_subprocess_exit_code = cef_bridge_execute_process(instance);
  if (cef_subprocess_exit_code >= 0) {
    return cef_subprocess_exit_code;
  }

  // Attach to console when present (e.g., 'flutter run') or create a
  // new console when running with a debugger.
  if (!::AttachConsole(ATTACH_PARENT_PROCESS) && ::IsDebuggerPresent()) {
    CreateAndAttachConsole();
  }

  // Initialize COM, so that it is available for use in the library and/or
  // plugins.
  ::CoInitializeEx(nullptr, COINIT_APARTMENTTHREADED);

  // Bring CEF up before the Flutter engine starts so the browser process is
  // ready by the time Dart begins issuing commands. A failure is not fatal: the
  // bridge reports itself as unavailable and the UI falls back to a placeholder.
  const std::string cef_cache_root_path = GetCefCacheRootPath();
  const bool cef_available =
      cef_bridge_initialize(instance, cef_cache_root_path.c_str()) != 0;

  flutter::DartProject project(L"data");

  std::vector<std::string> command_line_arguments =
      GetCommandLineArguments();

  project.set_dart_entrypoint_arguments(std::move(command_line_arguments));

  FlutterWindow window(project);
  window.SetCefEnabled(cef_available);
  Win32Window::Point origin(10, 10);
  Win32Window::Size size(1280, 720);
  if (!window.Create(L"webview_cef", origin, size)) {
    if (cef_available) {
      cef_bridge_shutdown();
    }
    return EXIT_FAILURE;
  }
  window.SetQuitOnClose(true);

  ::MSG msg;
  while (::GetMessage(&msg, nullptr, 0, 0)) {
    ::TranslateMessage(&msg);
    ::DispatchMessage(&msg);
  }

  // Tear CEF down on the process main thread, after the message loop has exited
  // and before COM is released.
  if (cef_available) {
    cef_bridge_shutdown();
  }

  ::CoUninitialize();
  return EXIT_SUCCESS;
}
