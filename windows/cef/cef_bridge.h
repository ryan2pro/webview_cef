#ifndef WEBVIEW_CEF_FLOATING_CEF_BRIDGE_H_
#define WEBVIEW_CEF_FLOATING_CEF_BRIDGE_H_

// Public contract of the plugin's CEF implementation library
// (webview_cef_floating_cef.dll).
//
// This header is shared by two very different callers:
//   * the plugin shell, which runs inside the host application's process, uses
//     it for the one-time CEF process bootstrap from its plugin registration
//     callback (which Flutter invokes on the process main thread) and to publish
//     the Flutter view window as the parent of every embedded browser, and
//   * Dart, which loads the same library through FFI and drives browsers at
//     runtime.
//
// The plugin shell is compiled with Flutter's apply_standard_settings()
// (/W4 /WX), so this header must stay free of any CEF include. All types
// crossing the boundary are plain C / Win32 handles.
//
// Threading contract:
//   * cef_bridge_initialize / cef_bridge_shutdown must be called on the process
//     main thread.
//   * cef_bridge_create_browser and the setters may be called from any thread
//     (Dart's root isolate runs on the engine UI thread, not the main thread).
//     They only mutate bridge state and post the CEF work to CEF's own UI
//     thread, preserving call order, and never block.
//   * cef_bridge_execute_process is called by the dedicated sub-process host,
//     which is a plain CEF application that never touches Flutter.

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

#if defined(CEF_BRIDGE_EXPORTS)
#define CEF_BRIDGE_API __declspec(dllexport)
#else
#define CEF_BRIDGE_API __declspec(dllimport)
#endif

/// Bootstraps CEF for the current process when it has been launched as one of
/// CEF's sub-processes.
///
/// Only the dedicated sub-process host
/// (webview_cef_floating_subprocess.exe) calls this. CEF is pointed at that
/// executable through CefSettings::browser_subprocess_path, which is what keeps
/// the host application's own entry point free of CEF code.
///
/// Returns >= 0 when this process has been recognized as a CEF sub-process
/// (renderer, GPU, ...), in which case the caller must return that value
/// immediately and run no further application code. Returns -1 for the browser
/// process, meaning normal startup should continue.
///
/// Must be the very first CEF call in the process.
CEF_BRIDGE_API int cef_bridge_execute_process(void* instance);

/// Initializes CEF as the browser process. Must be called once on the process
/// main thread, and it is a no-op on later calls.
///
/// The per-application cache directory and the sub-process executable path are
/// both derived inside the library from the host executable, so the caller does
/// not have to know anything about the deployment layout.
///
/// \param instance HINSTANCE of the host executable.
/// \return 1 on success, 0 on failure (for example when libcef.dll is missing).
CEF_BRIDGE_API int cef_bridge_initialize(void* instance);

/// Records the HWND that browser windows are created as children of, normally
/// the Flutter view window. WS_CLIPCHILDREN is added when absent so the parent
/// cannot paint over the embedded browser. Pass NULL to forget the host.
CEF_BRIDGE_API void cef_bridge_set_host_window(void* hwnd);

/// Creates a windowed (never off-screen) browser as a child of the host window.
///
/// Coordinates are physical pixels relative to the host window's client area.
/// Returns a slot id > 0 on success, 0 when CEF is unavailable. The returned id
/// is valid immediately even though the browser is created asynchronously; the
/// latest geometry/visibility is replayed once the browser exists.
CEF_BRIDGE_API int64_t cef_bridge_create_browser(int32_t x,
                                                 int32_t y,
                                                 int32_t width,
                                                 int32_t height,
                                                 const char* url);

/// Moves and resizes the browser window. Ignored when the slot is unknown.
CEF_BRIDGE_API void cef_bridge_set_bounds(int64_t slot,
                                          int32_t x,
                                          int32_t y,
                                          int32_t width,
                                          int32_t height);

/// Shows (non-zero) or hides (zero) the browser window.
CEF_BRIDGE_API void cef_bridge_set_visible(int64_t slot, int32_t visible);

/// Navigates the browser to \p url (UTF-8).
CEF_BRIDGE_API void cef_bridge_load_url(int64_t slot, const char* url);

/// Closes the browser and releases its slot. Safe to call more than once.
CEF_BRIDGE_API void cef_bridge_destroy_browser(int64_t slot);

/// Closes every remaining browser and shuts CEF down. Must be called on the
/// process main thread. Waits up to a few seconds for browsers to finish
/// closing, then returns.
///
/// Idempotent, and safe to call after a previous call already shut CEF down:
/// the plugin reaches it from the top level window procedure, from its own
/// destructor and from a CRT exit hook, whichever happens first.
CEF_BRIDGE_API void cef_bridge_shutdown(void);

/// Human readable version banner. Statically allocated, must not be freed.
CEF_BRIDGE_API const char* cef_bridge_version(void);

#ifdef __cplusplus
}
#endif

#endif  // WEBVIEW_CEF_FLOATING_CEF_BRIDGE_H_
