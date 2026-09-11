#include "cef_bridge.h"

#include <windows.h>

#include <algorithm>
#include <atomic>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>
#include <utility>
#include <vector>

#include "include/base/cef_bind.h"
#include "include/base/cef_callback.h"
#include "include/cef_app.h"
#include "include/cef_browser.h"
#include "include/cef_frame.h"
#include "include/cef_version.h"
#include "include/internal/cef_win.h"
#include "include/wrapper/cef_closure_task.h"
#include "include/wrapper/cef_helpers.h"

#include "cef_app.h"

// ---------------------------------------------------------------------------
// Threading model
//
// CEF is initialized with multi_threaded_message_loop = true, so CEF owns its
// own UI thread and message pump. Dart's FFI calls arrive on Flutter's engine UI
// thread, which is *not* the process main thread, let alone CEF's UI thread.
//
// Every entry point therefore only touches the slot table under a mutex and
// posts the actual CEF work to TID_UI. CefPostTask preserves FIFO order on the
// target thread, so a set_bounds posted after create_browser can never be
// applied first.
// ---------------------------------------------------------------------------

namespace {

/// How long CefShutdown() waits for outstanding browsers to close.
constexpr DWORD kShutdownTimeoutMs = 5000;

/// Name of the executable that hosts CEF's sub-processes. It is deployed next to
/// the host executable by the plugin's build.
constexpr wchar_t kSubprocessExecutable[] =
    L"webview_cef_floating_subprocess.exe";

/// Per-browser state, keyed by the slot id handed out to Dart.
struct BrowserSlot {
  /// Set on the CEF UI thread by OnAfterCreated, cleared by OnBeforeClose.
  CefRefPtr<CefBrowser> browser;

  /// Latest geometry requested from Dart, in physical pixels relative to the
  /// host window client area.
  CefRect bounds = CefRect(0, 0, 0, 0);
  bool has_bounds = false;

  bool visible = true;

  /// Visible rectangles requested from Dart, in physical pixels relative to the
  /// host window client area, or empty for "the browser is fully covered".
  /// Only meaningful while [has_clip] is set: before Dart ever reports an
  /// occlusion the browser carries no window region at all.
  std::vector<CefRect> clip_rects;
  bool has_clip = false;

  /// Whether the browser window currently carries a window region. Written on
  /// the CEF UI thread, read there too, so that the common "nothing is clipped"
  /// geometry update does not cost an extra SetWindowRgn.
  bool region_applied = false;

  /// Initial URL, consumed when the browser is created.
  std::string url;

  /// Set by cef_bridge_destroy_browser so OnBeforeClose can drop the slot.
  bool destroy_requested = false;
};

std::mutex g_mutex;
std::unordered_map<int64_t, BrowserSlot> g_slots;
std::atomic<int64_t> g_next_slot(1);

HWND g_host_window = nullptr;
bool g_initialized = false;
bool g_shutting_down = false;

/// Loads libcef.dll eagerly. The distribution delay-loads libcef.dll, which
/// would turn a missing deployment into a structured exception on the very first
/// CEF call; probing here instead lets startup degrade gracefully.
bool EnsureLibCefLoaded() {
  static const bool loaded = ::LoadLibraryW(L"libcef.dll") != nullptr;
  return loaded;
}

/// Full path of the running executable, or an empty string on failure.
std::wstring GetExecutablePath() {
  std::wstring buffer(MAX_PATH, L'\0');
  for (;;) {
    const DWORD length = ::GetModuleFileNameW(
        nullptr, buffer.data(), static_cast<DWORD>(buffer.size()));
    if (length == 0) {
      return std::wstring();
    }
    if (length < buffer.size()) {
      buffer.resize(length);
      return buffer;
    }
    // The result was truncated, so retry with more room. The cap keeps a
    // pathological path from growing the buffer without bound.
    if (buffer.size() >= 32768) {
      return std::wstring();
    }
    buffer.resize(buffer.size() * 2);
  }
}

/// Directory holding the running executable, without a trailing separator.
std::wstring GetExecutableDirectory() {
  const std::wstring path = GetExecutablePath();
  const size_t separator = path.find_last_of(L"\\/");
  return separator == std::wstring::npos ? std::wstring()
                                        : path.substr(0, separator);
}

/// File name of the running executable without its extension.
std::wstring GetExecutableStem() {
  const std::wstring path = GetExecutablePath();
  const size_t separator = path.find_last_of(L"\\/");
  const size_t start = separator == std::wstring::npos ? 0 : separator + 1;
  const size_t dot = path.find_last_of(L'.');
  const size_t end = (dot == std::wstring::npos || dot < start) ? path.size()
                                                               : dot;
  return path.substr(start, end - start);
}

/// Returns the per-user cache directory handed to CEF.
///
/// CEF 120+ derives a process singleton lock from CefSettings.root_cache_path,
/// so the path has to be stable across runs and unique per application. Deriving
/// it from the host executable's name is what allows two different applications
/// to embed this plugin without fighting over the lock.
std::wstring GetCacheRootPath() {
  wchar_t buffer[MAX_PATH] = {};
  const DWORD length =
      ::GetEnvironmentVariableW(L"LOCALAPPDATA", buffer, MAX_PATH);
  if (length > 0 && length < MAX_PATH) {
    std::wstring stem = GetExecutableStem();
    if (stem.empty()) {
      stem = L"webview_cef_floating";
    }
    return std::wstring(buffer, length) + L"\\" + stem + L"\\cef_cache";
  }

  // Fall back to the directory holding the executable.
  const std::wstring directory = GetExecutableDirectory();
  return directory.empty() ? std::wstring() : directory + L"\\cef_cache";
}

/// Absolute path of the executable that hosts CEF's sub-processes.
std::wstring GetSubprocessPath() {
  const std::wstring directory = GetExecutableDirectory();
  return directory.empty()
             ? std::wstring()
             : directory + L"\\" + kSubprocessExecutable;
}

/// Creates \p path and every missing parent directory. Failure is not fatal
/// here: CEF reports an unusable cache directory with a clearer error.
void EnsureDirectoryExists(const std::wstring& path) {
  if (path.empty()) {
    return;
  }

  std::wstring partial;
  partial.reserve(path.size());
  for (size_t i = 0; i < path.size(); ++i) {
    partial.push_back(path[i]);
    const bool is_separator = path[i] == L'\\' || path[i] == L'/';
    // Skipping 3 characters leaves the "C:\" volume prefix alone.
    if (is_separator && partial.size() > 3) {
      if (::CreateDirectoryW(partial.c_str(), nullptr) == FALSE &&
          ::GetLastError() != ERROR_ALREADY_EXISTS) {
        OutputDebugStringW(L"cef_bridge: could not create a cache directory\n");
      }
    }
  }

  if (::CreateDirectoryW(path.c_str(), nullptr) == FALSE &&
      ::GetLastError() != ERROR_ALREADY_EXISTS) {
    OutputDebugStringW(L"cef_bridge: could not create the cache directory\n");
  }
}

/// Returns the slot state, or nullptr when the slot is unknown.
/// Callers must hold g_mutex.
BrowserSlot* FindSlotLocked(int64_t slot) {
  auto it = g_slots.find(slot);
  return it == g_slots.end() ? nullptr : &it->second;
}

/// Copies the browser reference for \p slot out of the slot table.
/// Returns an empty reference while the browser is still being created.
CefRefPtr<CefBrowser> BrowserForSlot(int64_t slot) {
  std::lock_guard<std::mutex> lock(g_mutex);
  const BrowserSlot* state = FindSlotLocked(slot);
  return state == nullptr ? CefRefPtr<CefBrowser>() : state->browser;
}

/// Translates a rectangle from host client space into the browser window's own
/// coordinate system, which is what SetWindowRgn expects.
RECT ToWindowRect(const CefRect& rect, const CefRect& slot, int dx, int dy) {
  RECT result = {};
  result.left = rect.x - slot.x + dx;
  result.top = rect.y - slot.y + dy;
  result.right = result.left + rect.width;
  result.bottom = result.top + rect.height;
  return result;
}

/// Offset between the browser window's client origin and its window origin.
///
/// CEF's windowed child is borderless, so this is normally (0, 0), which makes
/// window and client coordinates interchangeable. Measuring it anyway keeps the
/// region correct should that ever stop being true.
void GetClientOriginOffset(HWND hwnd, int* dx, int* dy) {
  *dx = 0;
  *dy = 0;

  RECT window_rect = {};
  POINT client_origin = {0, 0};
  if (::GetWindowRect(hwnd, &window_rect) == FALSE ||
      ::ClientToScreen(hwnd, &client_origin) == FALSE) {
    return;
  }
  *dx = client_origin.x - window_rect.left;
  *dy = client_origin.y - window_rect.top;
}

/// Applies \p rects as the window region of \p hwnd.
///
/// A region that covers the whole client area, or no region at all, is
/// expressed by clearing the region: while nothing is clipped the window stays
/// free of region bookkeeping, so the common case costs nothing.
///
/// \return True when the window now carries a region.
bool ApplyWindowRegion(HWND hwnd,
                       const CefRect& slot,
                       const std::vector<CefRect>& rects) {
  if (rects.empty()) {
    ::SetWindowRgn(hwnd, nullptr, TRUE);
    return false;
  }

  RECT client = {};
  ::GetClientRect(hwnd, &client);

  int dx = 0;
  int dy = 0;
  GetClientOriginOffset(hwnd, &dx, &dy);

  std::vector<RECT> window_rects;
  window_rects.reserve(rects.size());
  for (const CefRect& rect : rects) {
    window_rects.push_back(ToWindowRect(rect, slot, dx, dy));
  }

  if (window_rects.size() == 1 && window_rects[0].left <= client.left &&
      window_rects[0].top <= client.top &&
      window_rects[0].right >= client.right &&
      window_rects[0].bottom >= client.bottom) {
    // The whole window is visible, so a region would be pure overhead.
    ::SetWindowRgn(hwnd, nullptr, TRUE);
    return false;
  }

  // One ExtCreateRegion call instead of a CombineRgn chain: the region is built
  // off-screen and only handed to the window once it is complete, so the window
  // never presents an intermediate shape.
  const size_t bytes =
      sizeof(RGNDATAHEADER) + window_rects.size() * sizeof(RECT);
  std::vector<unsigned char> buffer(bytes);
  RGNDATA* data = reinterpret_cast<RGNDATA*>(buffer.data());
  data->rdh.dwSize = sizeof(RGNDATAHEADER);
  data->rdh.iType = RDH_RECTANGLES;
  data->rdh.nCount = static_cast<DWORD>(window_rects.size());
  data->rdh.nRgnSize = static_cast<DWORD>(window_rects.size() * sizeof(RECT));

  RECT* output = reinterpret_cast<RECT*>(data->Buffer);
  RECT bound = window_rects[0];
  for (size_t i = 0; i < window_rects.size(); ++i) {
    output[i] = window_rects[i];
    bound.left = std::min(bound.left, output[i].left);
    bound.top = std::min(bound.top, output[i].top);
    bound.right = std::max(bound.right, output[i].right);
    bound.bottom = std::max(bound.bottom, output[i].bottom);
  }
  data->rdh.rcBound = bound;

  HRGN region = ::ExtCreateRegion(nullptr, static_cast<DWORD>(bytes), data);
  if (region == nullptr) {
    OutputDebugStringW(L"cef_bridge: could not build a window region\n");
    return false;
  }

  // On success the system owns the region; deleting it would be a bug.
  if (::SetWindowRgn(hwnd, region, TRUE) == 0) {
    ::DeleteObject(region);
    OutputDebugStringW(L"cef_bridge: SetWindowRgn failed\n");
    return false;
  }
  return true;
}

/// Moves/resizes, shows/hides and clips the browser window.
/// Runs on the CEF UI thread.
void ApplyStateOnUiThread(int64_t slot) {
  CEF_REQUIRE_UI_THREAD();

  CefRefPtr<CefBrowser> browser;
  CefRect bounds(0, 0, 0, 0);
  bool has_bounds = false;
  bool visible = true;
  bool has_clip = false;
  bool region_applied = false;
  std::vector<CefRect> clip_rects;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    const BrowserSlot* state = FindSlotLocked(slot);
    if (state == nullptr) {
      return;
    }
    browser = state->browser;
    bounds = state->bounds;
    has_bounds = state->has_bounds;
    visible = state->visible;
    has_clip = state->has_clip;
    region_applied = state->region_applied;
    clip_rects = state->clip_rects;
  }

  if (!browser.get() || !has_bounds) {
    return;
  }

  // An empty region is an empty visible area, so it hides the window on its own
  // and no ordering rule between cef_bridge_set_clip and cef_bridge_set_visible
  // is required of the caller.
  const bool region_empty = has_clip && clip_rects.empty();
  const bool show = visible && !region_empty;

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (!host.get()) {
    return;
  }

  const HWND hwnd = host->GetWindowHandle();
  if (hwnd == nullptr) {
    return;
  }

  // Tells CEF the hosted window is about to move so it can suspend and resume
  // painting cleanly instead of tearing. This is the windowed-rendering
  // counterpart of WasResized(), which only applies to off-screen browsers.
  host->NotifyMoveOrResizeStarted();

  UINT flags = SWP_NOZORDER | SWP_NOACTIVATE;
  flags |= show ? SWP_SHOWWINDOW : SWP_HIDEWINDOW;
  ::SetWindowPos(hwnd, nullptr, bounds.x, bounds.y, bounds.width, bounds.height,
                 flags);

  // Only touch the window region when the state actually changes: scrolling and
  // resizing post this function on every frame, and re-clearing an absent region
  // would repaint the window for nothing.
  if (has_clip && !region_empty) {
    region_applied = ApplyWindowRegion(hwnd, bounds, clip_rects);
  } else if (region_applied) {
    ::SetWindowRgn(hwnd, nullptr, TRUE);
    region_applied = false;
  }

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    BrowserSlot* state = FindSlotLocked(slot);
    if (state != nullptr) {
      state->region_applied = region_applied;
    }
  }
}

/// Creates the browser window for \p slot as a child of the host window.
/// Runs on the CEF UI thread.
void CreateBrowserOnUiThread(int64_t slot) {
  CEF_REQUIRE_UI_THREAD();

  HWND host = nullptr;
  CefRect bounds(0, 0, 0, 0);
  std::string url;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (g_shutting_down) {
      return;
    }
    const BrowserSlot* state = FindSlotLocked(slot);
    if (state == nullptr || state->browser.get() != nullptr) {
      return;
    }
    host = g_host_window;
    bounds = state->bounds;
    url = state->url;
  }

  // Without a host window CEF would create a top level window, which is not what
  // this integration is for. Dart retries by recreating the view.
  if (host == nullptr) {
    return;
  }

  CefWindowInfo window_info;
  // Windowed rendering: a real child HWND parented to the Flutter view. The
  // off-screen path is deliberately not used, so CefRenderHandler never gets
  // involved and the browser is composited by the OS on top of Flutter content.
  window_info.SetAsChild(host, bounds);
  window_info.windowless_rendering_enabled = false;
  // Alloy is the style that supports being parented to a client-provided window.
  window_info.runtime_style = CEF_RUNTIME_STYLE_ALLOY;

  CefBrowserSettings browser_settings;

  CefRefPtr<CefBridgeClient> client(new CefBridgeClient(slot));
  CefBrowserHost::CreateBrowser(window_info, client, CefString(url),
                                browser_settings, nullptr, nullptr);
}

/// Runs on the CEF UI thread.
void LoadUrlOnUiThread(int64_t slot, std::string url) {
  CEF_REQUIRE_UI_THREAD();

  CefRefPtr<CefBrowser> browser = BrowserForSlot(slot);
  if (!browser.get()) {
    return;
  }

  CefRefPtr<CefFrame> frame = browser->GetMainFrame();
  if (frame.get()) {
    frame->LoadURL(CefString(url));
  }
}

/// Runs on the CEF UI thread.
void CloseBrowserOnUiThread(int64_t slot) {
  CEF_REQUIRE_UI_THREAD();

  CefRefPtr<CefBrowser> browser = BrowserForSlot(slot);
  if (!browser.get()) {
    return;
  }

  CefRefPtr<CefBrowserHost> host = browser->GetHost();
  if (host.get()) {
    // force_close skips unload handlers, so page code cannot stall application
    // shutdown.
    host->CloseBrowser(true);
  }
}

/// CRT exit hook. The host runner cannot call into the bridge after its message
/// loop has exited, so this is what guarantees CefShutdown() runs even when the
/// window procedure observation never fires. cef_bridge_shutdown() is
/// idempotent, so ordering against the other shutdown paths does not matter.
void ShutdownAtProcessExit() {
  cef_bridge_shutdown();
}

}  // namespace

// --- Hooks used by CefBridgeClient (CEF UI thread) --------------------------

void CefBridgeAttachBrowser(int64_t slot, CefRefPtr<CefBrowser> browser) {
  std::lock_guard<std::mutex> lock(g_mutex);
  BrowserSlot* state = FindSlotLocked(slot);
  if (state == nullptr) {
    // The slot was destroyed before creation finished; OnBeforeClose releases
    // the browser.
    return;
  }
  state->browser = browser;
  state->url.clear();
}

void CefBridgeDetachBrowser(int64_t slot) {
  std::lock_guard<std::mutex> lock(g_mutex);
  auto it = g_slots.find(slot);
  if (it == g_slots.end()) {
    return;
  }
  it->second.browser = nullptr;
  if (it->second.destroy_requested) {
    g_slots.erase(it);
  }
}

void CefBridgeApplyPendingState(int64_t slot) {
  ApplyStateOnUiThread(slot);
}

// --- Public C ABI -----------------------------------------------------------

extern "C" {

int cef_bridge_execute_process(void* instance) {
  if (!EnsureLibCefLoaded()) {
    // Report "browser process" so the application still starts, just without web
    // content, instead of crashing on a delay-load failure.
    return -1;
  }
  CefMainArgs main_args(reinterpret_cast<HINSTANCE>(instance));
  // An empty CefApp is fine: this integration never creates a browser from
  // OnContextInitialized, browsers are driven from Dart.
  return CefExecuteProcess(main_args, CefRefPtr<CefApp>(), nullptr);
}

int cef_bridge_initialize(void* instance) {
  if (g_initialized) {
    return 1;
  }
  if (!EnsureLibCefLoaded()) {
    return 0;
  }

  const std::wstring cache_path = GetCacheRootPath();
  if (!cache_path.empty()) {
    EnsureDirectoryExists(cache_path);
  }

  CefMainArgs main_args(reinterpret_cast<HINSTANCE>(instance));

  CefSettings settings;
  // The sandbox build would turn this executable into a DLL launched by
  // bootstrap.exe, which the Flutter runner layout does not support.
  settings.no_sandbox = true;
  // CEF owns its UI thread and message pump, so nothing has to be pumped from
  // Flutter's message loop and no thread affinity leaks across the FFI boundary.
  settings.multi_threaded_message_loop = true;
  settings.external_message_pump = false;
  // Explicitly disables off-screen rendering: browsers get a real child HWND.
  settings.windowless_rendering_enabled = false;
  if (!cache_path.empty()) {
    // CEF 120+ only allows a single instance per root_cache_path, so it must be
    // application specific.
    CefString(&settings.root_cache_path) = cache_path;
    CefString(&settings.cache_path) = cache_path;
  }

  // Renderer, GPU and utility processes are hosted by a dedicated helper
  // executable rather than by re-launching the host. That is what keeps the host
  // runner's entry point free of CEF code, and it is why nothing has to happen
  // in the host's wWinMain.
  const std::wstring subprocess_path = GetSubprocessPath();
  if (!subprocess_path.empty()) {
    if (::GetFileAttributesW(subprocess_path.c_str()) == INVALID_FILE_ATTRIBUTES) {
      // Pointing at a missing file is still better than leaving the setting
      // empty: an empty value makes CEF relaunch the host executable as a
      // renderer, which for a GUI application means spawning a second window.
      OutputDebugStringW(
          L"cef_bridge: sub-process helper not found next to the executable\n");
    }
    CefString(&settings.browser_subprocess_path) = subprocess_path;
  }

  if (!CefInitialize(main_args, settings, CefRefPtr<CefApp>(), nullptr)) {
    return 0;
  }

  g_initialized = true;

  // Nothing in the host runner may run after its message loop exits, so the CRT
  // exit hook is the fallback that guarantees CefShutdown() still happens even
  // if the window procedure observation never fires. Shutting down is
  // idempotent, so running after (or before) the other paths is harmless.
  std::atexit(&ShutdownAtProcessExit);
  return 1;
}

void cef_bridge_set_host_window(void* hwnd) {
  const HWND host = static_cast<HWND>(hwnd);
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_host_window = host;
  }
  if (host == nullptr) {
    return;
  }

  // CEF requires the parent window to clip children out of its own painting,
  // otherwise the browser window can be painted over by the parent.
  const LONG_PTR style = ::GetWindowLongPtrW(host, GWL_STYLE);
  if ((style & WS_CLIPCHILDREN) == 0) {
    ::SetWindowLongPtrW(host, GWL_STYLE, style | WS_CLIPCHILDREN);
  }
}

int64_t cef_bridge_create_browser(int32_t x,
                                  int32_t y,
                                  int32_t width,
                                  int32_t height,
                                  const char* url) {
  if (width <= 0 || height <= 0) {
    return 0;
  }

  const int64_t slot = g_next_slot.fetch_add(1);
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    if (!g_initialized || g_shutting_down) {
      return 0;
    }
    BrowserSlot& state = g_slots[slot];
    state.bounds = CefRect(x, y, width, height);
    state.has_bounds = true;
    state.visible = true;
    state.url = (url != nullptr) ? url : "";
  }

  if (!CefPostTask(TID_UI, base::BindOnce(&CreateBrowserOnUiThread, slot))) {
    // CEF is no longer accepting work; drop the slot rather than leaking it.
    std::lock_guard<std::mutex> lock(g_mutex);
    g_slots.erase(slot);
    return 0;
  }
  return slot;
}

void cef_bridge_set_bounds(int64_t slot,
                           int32_t x,
                           int32_t y,
                           int32_t width,
                           int32_t height) {
  if (width <= 0 || height <= 0) {
    // Zero sized regions are expressed with cef_bridge_set_visible(slot, 0)
    // instead, because a window cannot have a zero client area.
    return;
  }

  bool has_browser = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    BrowserSlot* state = FindSlotLocked(slot);
    if (state == nullptr) {
      return;
    }
    state->bounds = CefRect(x, y, width, height);
    state->has_bounds = true;
    has_browser = state->browser.get() != nullptr;
  }

  if (!has_browser) {
    // Creation is still in flight; CefBridgeApplyPendingState() replays this
    // geometry from OnAfterCreated.
    return;
  }
  CefPostTask(TID_UI, base::BindOnce(&ApplyStateOnUiThread, slot));
}

void cef_bridge_set_visible(int64_t slot, int32_t visible) {
  bool has_browser = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    BrowserSlot* state = FindSlotLocked(slot);
    if (state == nullptr) {
      return;
    }
    state->visible = visible != 0;
    has_browser = state->browser.get() != nullptr;
  }

  if (!has_browser) {
    return;
  }
  CefPostTask(TID_UI, base::BindOnce(&ApplyStateOnUiThread, slot));
}

void cef_bridge_set_clip(int64_t slot,
                         const CefBridgeRect* rects,
                         int32_t count) {
  if (count < 0 || (count > 0 && rects == nullptr)) {
    return;
  }

  std::vector<CefRect> clip_rects;
  clip_rects.reserve(static_cast<size_t>(count));
  for (int32_t i = 0; i < count; ++i) {
    const CefBridgeRect& rect = rects[i];
    if (rect.width <= 0 || rect.height <= 0) {
      // Degenerate rectangles would make an empty region out of a partial clip.
      continue;
    }
    clip_rects.push_back(CefRect(rect.x, rect.y, rect.width, rect.height));
  }

  bool has_browser = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    BrowserSlot* state = FindSlotLocked(slot);
    if (state == nullptr) {
      return;
    }
    state->clip_rects = std::move(clip_rects);
    state->has_clip = true;
    has_browser = state->browser.get() != nullptr;
  }

  if (!has_browser) {
    // Creation is still in flight; CefBridgeApplyPendingState() replays this
    // geometry for the caller.
    return;
  }
  CefPostTask(TID_UI, base::BindOnce(&ApplyStateOnUiThread, slot));
}

void cef_bridge_load_url(int64_t slot, const char* url) {
  if (url == nullptr) {
    return;
  }
  const std::string target(url);
  CefPostTask(TID_UI, base::BindOnce(&LoadUrlOnUiThread, slot, target));
}

void cef_bridge_destroy_browser(int64_t slot) {
  bool has_browser = false;
  {
    std::lock_guard<std::mutex> lock(g_mutex);
    auto it = g_slots.find(slot);
    if (it == g_slots.end()) {
      return;
    }
    it->second.destroy_requested = true;
    has_browser = it->second.browser.get() != nullptr;
    if (!has_browser) {
      // Creation never completed, so there is nothing to close.
      g_slots.erase(it);
      return;
    }
  }
  CefPostTask(TID_UI, base::BindOnce(&CloseBrowserOnUiThread, slot));
}

void cef_bridge_shutdown(void) {
  if (!g_initialized) {
    return;
  }

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_shutting_down = true;
    g_host_window = nullptr;
  }

  // CefShutdown() must not run while browsers are still alive, and with a
  // multi-threaded message loop the UI thread keeps running independently, so
  // poll (with a bound) until OnBeforeClose has released every slot.
  const DWORD deadline = ::GetTickCount() + kShutdownTimeoutMs;
  for (;;) {
    std::vector<int64_t> alive;
    {
      std::lock_guard<std::mutex> lock(g_mutex);
      for (auto& entry : g_slots) {
        if (entry.second.browser.get() != nullptr) {
          entry.second.destroy_requested = true;
          alive.push_back(entry.first);
        }
      }
    }

    if (alive.empty()) {
      break;
    }
    for (const int64_t slot : alive) {
      CefPostTask(TID_UI, base::BindOnce(&CloseBrowserOnUiThread, slot));
    }

    if (static_cast<int64_t>(::GetTickCount()) >=
        static_cast<int64_t>(deadline)) {
      OutputDebugStringW(L"cef_bridge: timed out waiting for browsers to close\n");
      break;
    }
    ::Sleep(50);
  }

  {
    std::lock_guard<std::mutex> lock(g_mutex);
    g_slots.clear();
  }

  CefShutdown();

  g_initialized = false;
  g_shutting_down = false;
}

const char* cef_bridge_version(void) {
  // Function-local static: initialized exactly once, thread-safe, and never
  // freed so Dart can keep the pointer.
  static const std::string kVersion = []() {
    char buffer[160];
    std::snprintf(buffer, sizeof(buffer),
                  "webview_cef_floating | CEF %d.%d.%d | Chromium %d.%d.%d.%d",
                  CEF_VERSION_MAJOR, CEF_VERSION_MINOR, CEF_VERSION_PATCH,
                  CHROME_VERSION_MAJOR, CHROME_VERSION_MINOR,
                  CHROME_VERSION_BUILD, CHROME_VERSION_PATCH);
    return std::string(buffer);
  }();
  return kVersion.c_str();
}

}  // extern "C"

// --- Last resort ------------------------------------------------------------

/// Reports a process that went away without tearing CEF down.
///
/// CefShutdown() must deliberately not be called from here: DLL_PROCESS_DETACH
/// runs while the loader lock is held, and CEF's teardown loads and unloads
/// modules, which deadlocks under that lock. The plugin's window procedure
/// observation and its destructor, plus the CRT exit hook registered in
/// cef_bridge_initialize(), cover every orderly shutdown.
BOOL WINAPI DllMain(HINSTANCE, DWORD reason, LPVOID reserved) {
  if (reason == DLL_PROCESS_DETACH && reserved != nullptr && g_initialized) {
    OutputDebugStringW(
        L"cef_bridge: process exited before CEF was shut down\n");
  }
  return TRUE;
}
