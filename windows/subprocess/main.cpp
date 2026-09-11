// Host for CEF's renderer, GPU, utility and zygote processes.
//
// CEF normally expects the application's own entry point to run
// CefExecuteProcess() before anything else happens. A Flutter plugin cannot
// arrange that - the runner's wWinMain belongs to the host application - so
// CefSettings::browser_subprocess_path points at this executable instead. The
// host application therefore keeps a completely stock runner and never launches
// itself as a renderer.

#include <windows.h>

#include "include/cef_app.h"

int APIENTRY wWinMain(_In_ HINSTANCE instance, _In_opt_ HINSTANCE previous,
                      _In_ wchar_t* command_line, _In_ int show_command) {
  CefMainArgs main_args(instance);

  // An empty CefApp is correct here: sub-processes only need CEF's built-in
  // implementations, they never create browsers.
  return CefExecuteProcess(main_args, CefRefPtr<CefApp>(), nullptr);
}
