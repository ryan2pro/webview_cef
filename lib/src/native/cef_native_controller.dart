import 'dart:ui' show Rect;

import 'cef_ffi_bindings.dart';

/// Process-wide access point to the native CEF bridge.
///
/// CEF itself is initialized by the runner executable during process startup, so
/// this controller only binds the runtime entry points and forwards geometry.
/// Resolution happens once and is then cached; a missing bridge is a normal,
/// non-fatal condition so the widget tree can fall back to a placeholder.
class CefNativeController {
  CefNativeController._(this._bindings);

  static CefNativeController? _instance;
  static bool _resolved = false;

  final CefNativeBindings _bindings;

  /// Returns the controller, or null when the native bridge is unavailable
  /// (non-Windows host, missing or stale `cef_bridge.dll`).
  static CefNativeController? instance() {
    if (!_resolved) {
      _resolved = true;
      final CefNativeBindings? bindings = CefNativeBindings.tryLoad();
      if (bindings != null) {
        _instance = CefNativeController._(bindings);
      }
    }
    return _instance;
  }

  /// Version banner reported by the loaded bridge.
  String get version => _bindings.version();

  /// Creates a windowed browser covering [bounds] (physical pixels, relative to
  /// the Flutter view) and loading [url].
  ///
  /// Returns the slot id, or 0 when the native side refused to create the
  /// browser (CEF unavailable, shutting down, or a degenerate rect).
  int createBrowser({required Rect bounds, required String url}) {
    return _bindings.createBrowser(
      x: bounds.left.round(),
      y: bounds.top.round(),
      width: bounds.width.round(),
      height: bounds.height.round(),
      url: url,
    );
  }

  /// Moves and resizes the browser created for [slot].
  void setBounds({required int slot, required Rect bounds}) {
    _bindings.setBounds(
      slot: slot,
      x: bounds.left.round(),
      y: bounds.top.round(),
      width: bounds.width.round(),
      height: bounds.height.round(),
    );
  }

  /// Shows or hides the browser created for [slot].
  void setVisible({required int slot, required bool visible}) {
    _bindings.setVisible(slot: slot, visible: visible);
  }

  /// Navigates the browser created for [slot] to [url].
  void loadUrl({required int slot, required String url}) {
    _bindings.loadUrl(slot: slot, url: url);
  }

  /// Closes the browser created for [slot] and releases its slot.
  void destroyBrowser({required int slot}) {
    _bindings.destroyBrowser(slot: slot);
  }
}
