import 'dart:ui' show Rect;

import 'cef_ffi_bindings.dart';

/// The browser backend a `CefWindowedView` drives.
///
/// Extracted from [CefNativeController] so that the view can be tested, or
/// pointed at a different backend, without the native library ever being
/// loaded. Every rectangle is in physical pixels relative to the Flutter view
/// the browser window is parented to.
abstract interface class CefBrowserSurface {
  /// Whether this surface can restrict a browser to a region.
  bool get supportsClipping;

  /// Creates a windowed browser covering [bounds] and loading [url].
  ///
  /// Returns the slot id, or 0 when the browser could not be created.
  int createBrowser({required Rect bounds, required String url});

  /// Moves and resizes the browser created for [slot].
  void setBounds({required int slot, required Rect bounds});

  /// Shows or hides the browser created for [slot].
  void setVisible({required int slot, required bool visible});

  /// Restricts the browser created for [slot] to [rects].
  ///
  /// An empty list means the browser is fully covered. Returns false when this
  /// surface cannot clip, so the caller can hide instead.
  bool setClip({required int slot, required List<Rect> rects});

  /// Navigates the browser created for [slot] to [url].
  void loadUrl({required int slot, required String url});

  /// Closes the browser created for [slot] and releases its slot.
  void destroyBrowser({required int slot});
}

/// Process-wide access point to the native CEF bridge.
///
/// CEF itself is initialized by the plugin while Flutter registers it, so this
/// controller only binds the runtime entry points and forwards geometry.
/// Resolution happens once and is then cached; a missing bridge is a normal,
/// non-fatal condition so the widget tree can fall back to a placeholder.
class CefNativeController implements CefBrowserSurface {
  CefNativeController._(this._bindings);

  static CefNativeController? _instance;
  static bool _resolved = false;

  final CefNativeBindings _bindings;

  /// Returns the controller, or null when the native bridge is unavailable
  /// (non-Windows host, or a missing/stale native library).
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

  /// Whether the loaded bridge can restrict a browser to a region.
  ///
  /// False for a bridge built before region clipping existed; callers should
  /// then hide the browser instead of clipping it.
  @override
  bool get supportsClipping => _bindings.supportsClipping;

  /// Creates a windowed browser covering [bounds] (physical pixels, relative to
  /// the Flutter view) and loading [url].
  ///
  /// Returns the slot id, or 0 when the native side refused to create the
  /// browser (CEF unavailable, shutting down, or a degenerate rect).
  @override
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
  @override
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
  @override
  void setVisible({required int slot, required bool visible}) {
    _bindings.setVisible(slot: slot, visible: visible);
  }

  /// Restricts the browser created for [slot] to [rects] (physical pixels
  /// relative to the Flutter view).
  ///
  /// An empty list means the browser is fully covered. Returns false when the
  /// bridge cannot clip, so the caller can hide instead.
  @override
  bool setClip({required int slot, required List<Rect> rects}) {
    return _bindings.setClip(slot: slot, rects: rects);
  }

  /// Navigates the browser created for [slot] to [url].
  @override
  void loadUrl({required int slot, required String url}) {
    _bindings.loadUrl(slot: slot, url: url);
  }

  /// Closes the browser created for [slot] and releases its slot.
  @override
  void destroyBrowser({required int slot}) {
    _bindings.destroyBrowser(slot: slot);
  }
}
