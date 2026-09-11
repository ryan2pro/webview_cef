import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';
import 'package:path/path.dart' as p;

// Native signatures of the plain C ABI exposed by the plugin's native library.
// Keep in sync with windows/cef/cef_bridge.h.

typedef _VersionNative = Pointer<Utf8> Function();
typedef _VersionDart = Pointer<Utf8> Function();

typedef _CreateBrowserNative = Int64 Function(
  Int32 x,
  Int32 y,
  Int32 width,
  Int32 height,
  Pointer<Utf8> url,
);
typedef _CreateBrowserDart = int Function(
  int x,
  int y,
  int width,
  int height,
  Pointer<Utf8> url,
);

typedef _SetBoundsNative = Void Function(
  Int64 slot,
  Int32 x,
  Int32 y,
  Int32 width,
  Int32 height,
);
typedef _SetBoundsDart = void Function(
  int slot,
  int x,
  int y,
  int width,
  int height,
);

typedef _SetVisibleNative = Void Function(Int64 slot, Int32 visible);
typedef _SetVisibleDart = void Function(int slot, int visible);

typedef _LoadUrlNative = Void Function(Int64 slot, Pointer<Utf8> url);
typedef _LoadUrlDart = void Function(int slot, Pointer<Utf8> url);

typedef _DestroyBrowserNative = Void Function(Int64 slot);
typedef _DestroyBrowserDart = void Function(int slot);

/// Thin, null-safe wrapper around the plugin's native library exports.
///
/// CEF is brought up by the plugin itself while Flutter registers it, which the
/// host runner does on the process main thread and before Dart can issue any
/// command. Dart therefore only ever drives browsers that already exist at the
/// native level, and loading this library never changes global state; it just
/// binds the functions used to create, move, show and destroy browsers.
class CefNativeBindings {
  CefNativeBindings._(
    this._version,
    this._createBrowser,
    this._setBounds,
    this._setVisible,
    this._loadUrl,
    this._destroyBrowser,
  );

  /// File name of the native library, always deployed next to the executable.
  static const String libraryName = 'webview_cef_floating_cef.dll';

  final _VersionDart _version;
  final _CreateBrowserDart _createBrowser;
  final _SetBoundsDart _setBounds;
  final _SetVisibleDart _setVisible;
  final _LoadUrlDart _loadUrl;
  final _DestroyBrowserDart _destroyBrowser;

  /// Attempts to bind to the native bridge.
  ///
  /// Returns null when running on another platform or when the library cannot
  /// be resolved. Callers are expected to degrade gracefully rather than crash,
  /// so that a plain `flutter test` run or a mis-deployed build stays usable.
  static CefNativeBindings? tryLoad() {
    if (!Platform.isWindows) {
      return null;
    }

    try {
      final DynamicLibrary library = _openLibrary();
      return CefNativeBindings._(
        library.lookupFunction<_VersionNative, _VersionDart>(
          'cef_bridge_version',
        ),
        library.lookupFunction<_CreateBrowserNative, _CreateBrowserDart>(
          'cef_bridge_create_browser',
        ),
        library.lookupFunction<_SetBoundsNative, _SetBoundsDart>(
          'cef_bridge_set_bounds',
        ),
        library.lookupFunction<_SetVisibleNative, _SetVisibleDart>(
          'cef_bridge_set_visible',
        ),
        library.lookupFunction<_LoadUrlNative, _LoadUrlDart>(
          'cef_bridge_load_url',
        ),
        library.lookupFunction<_DestroyBrowserNative, _DestroyBrowserDart>(
          'cef_bridge_destroy_browser',
        ),
      );
    } on ArgumentError {
      // Either the library is not deployed, or it was built from a different
      // bridge revision and no longer exports the expected symbols.
      return null;
    }
  }

  /// Opens the bridge library, preferring the copy next to the running
  /// executable over the bare name (which relies on the process search path).
  static DynamicLibrary _openLibrary() {
    final List<String> candidates = <String>[
      p.join(p.dirname(Platform.resolvedExecutable), libraryName),
      libraryName,
    ];

    for (final String candidate in candidates) {
      try {
        // Probes a known export so that a stale file is rejected here rather
        // than at the first browser call.
        final DynamicLibrary library = DynamicLibrary.open(candidate);
        library.lookupFunction<_VersionNative, _VersionDart>(
          'cef_bridge_version',
        );
        return library;
      } on ArgumentError {
        continue;
      }
    }

    throw ArgumentError('Unable to load $libraryName from $candidates');
  }

  /// Version banner of the loaded bridge, including the CEF and Chromium
  /// versions it was compiled against.
  String version() => _version().toDartString();

  /// Creates a windowed browser and returns its slot id (> 0), or 0 on failure.
  int createBrowser({
    required int x,
    required int y,
    required int width,
    required int height,
    required String url,
  }) {
    final Pointer<Utf8> urlPointer = url.toNativeUtf8();
    try {
      return _createBrowser(x, y, width, height, urlPointer);
    } finally {
      calloc.free(urlPointer);
    }
  }

  /// Moves and resizes the browser window. Coordinates are physical pixels
  /// relative to the host window's client area.
  void setBounds({
    required int slot,
    required int x,
    required int y,
    required int width,
    required int height,
  }) {
    _setBounds(slot, x, y, width, height);
  }

  /// Shows or hides the browser window.
  void setVisible({required int slot, required bool visible}) {
    _setVisible(slot, visible ? 1 : 0);
  }

  /// Navigates to [url].
  void loadUrl({required int slot, required String url}) {
    final Pointer<Utf8> urlPointer = url.toNativeUtf8();
    try {
      _loadUrl(slot, urlPointer);
    } finally {
      calloc.free(urlPointer);
    }
  }

  /// Closes the browser and releases its slot. Safe to call more than once.
  void destroyBrowser({required int slot}) => _destroyBrowser(slot);
}
