#include "cef_app.h"

CefBridgeClient::CefBridgeClient(int64_t slot) : slot_(slot) {}

CefBridgeClient::~CefBridgeClient() = default;

CefRefPtr<CefLifeSpanHandler> CefBridgeClient::GetLifeSpanHandler() {
  return this;
}

void CefBridgeClient::OnAfterCreated(CefRefPtr<CefBrowser> browser) {
  // The browser window now exists, so publish it to the owning slot and replay
  // any geometry Dart asked for while creation was still in flight.
  CefBridgeAttachBrowser(slot_, browser);
  CefBridgeApplyPendingState(slot_);
}

void CefBridgeClient::OnBeforeClose(CefRefPtr<CefBrowser> browser) {
  // Runs on the UI thread immediately before the browser object is destroyed,
  // which releases the slot so shutdown can tell when everything is gone.
  CefBridgeDetachBrowser(slot_);
}
