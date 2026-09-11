#ifndef RUNNER_CEF_APP_H_
#define RUNNER_CEF_APP_H_

// CEF client implementation for a single windowed browser.
//
// One CefBridgeClient instance is created per browser so that lifecycle
// callbacks can be routed back to the owning bridge slot without any global
// lookup by browser id.
//
// Everything in this header is internal to cef_bridge.dll; the runner exe and
// Dart only ever see the plain C ABI from cef_bridge.h.

#include <stdint.h>

#include "include/cef_browser.h"
#include "include/cef_client.h"
#include "include/cef_life_span_handler.h"

/// Records the browser created for \p slot. Implemented in cef_bridge.cpp and
/// called from CefBridgeClient::OnAfterCreated on the CEF UI thread.
void CefBridgeAttachBrowser(int64_t slot, CefRefPtr<CefBrowser> browser);

/// Drops the browser that belonged to \p slot, erasing the slot when its
/// destruction was requested. Implemented in cef_bridge.cpp and called from
/// CefBridgeClient::OnBeforeClose on the CEF UI thread.
void CefBridgeDetachBrowser(int64_t slot);

/// Applies the geometry and visibility currently held for \p slot. Called on
/// the CEF UI thread once a browser exists, so that bounds requested from Dart
/// before the browser was ready are replayed rather than lost.
void CefBridgeApplyPendingState(int64_t slot);

/// Clients a single windowed browser owned by bridge slot \p slot.
class CefBridgeClient : public CefClient, public CefLifeSpanHandler {
 public:
  explicit CefBridgeClient(int64_t slot);
  ~CefBridgeClient() override;

  CefBridgeClient(const CefBridgeClient&) = delete;
  CefBridgeClient& operator=(const CefBridgeClient&) = delete;

  // CefClient:
  CefRefPtr<CefLifeSpanHandler> GetLifeSpanHandler() override;

  // CefLifeSpanHandler:
  void OnAfterCreated(CefRefPtr<CefBrowser> browser) override;
  void OnBeforeClose(CefRefPtr<CefBrowser> browser) override;

 private:
  const int64_t slot_;

  IMPLEMENT_REFCOUNTING(CefBridgeClient);
};

#endif  // RUNNER_CEF_APP_H_
