import 'package:flutter/material.dart';

import '../native/cef_native_controller.dart';
import 'cef_geometry.dart';

/// Snapshot of the geometry last pushed to the native browser window.
@immutable
class CefViewGeometry {
  const CefViewGeometry({
    required this.logicalBounds,
    required this.physicalBounds,
    required this.visible,
    required this.slot,
  });

  /// Region of the Flutter view the browser should cover, in logical pixels.
  final Rect logicalBounds;

  /// The same region converted to physical pixels, which is what Win32 gets.
  final Rect physicalBounds;

  /// Whether the native window is currently shown.
  final bool visible;

  /// Native browser slot, or null while no browser has been created.
  final int? slot;

  @override
  String toString() =>
      'CefViewGeometry(slot: $slot, visible: $visible, '
      'logical: $logicalBounds, physical: $physicalBounds)';
}

/// Reserves a region of the Flutter UI that a real CEF browser window covers.
///
/// CEF creates a genuine child HWND parented to the Flutter view instead of
/// rendering into a texture. That is the point of the windowed approach - video,
/// input methods and native context menus all behave normally - but it also means
/// the browser always paints on top of Flutter content and cannot be clipped,
/// rounded or transformed by Flutter.
///
/// This widget therefore keeps the native window's position, size and
/// visibility in sync with the layout box it occupies. Any Flutter UI that
/// covers this region must hide it explicitly through [visible].
class CefWindowedView extends StatefulWidget {
  const CefWindowedView({
    super.key,
    required this.url,
    this.visible = true,
    this.placeholderColor,
    this.onGeometryChanged,
    this.hideWhenClipped = true,
  });

  /// Page loaded when the browser is created, and again whenever it changes.
  final String url;

  /// Whether the browser may be shown at all.
  ///
  /// Set this to false when Flutter content (a dialog, a full screen route)
  /// covers the region: the native window cannot be occluded by Flutter.
  final bool visible;

  /// Background of the Flutter placeholder that sits underneath the browser.
  final Color? placeholderColor;

  /// Reports every geometry change that crosses the FFI boundary.
  final ValueChanged<CefViewGeometry>? onGeometryChanged;

  /// Hides the browser whenever the region is not entirely on screen.
  ///
  /// Without this the browser would spill over unrelated Flutter content while
  /// the page scrolls, because a native child window ignores Flutter's clipping.
  final bool hideWhenClipped;

  @override
  State<CefWindowedView> createState() => _CefWindowedViewState();
}

class _CefWindowedViewState extends State<CefWindowedView>
    with WidgetsBindingObserver {
  /// Marks the layout box whose geometry drives the native window.
  final GlobalKey _anchorKey = GlobalKey();

  CefNativeController? _controller;
  int? _slot;

  // Mirrors of MediaQuery values, so the frame callback never has to look up an
  // inherited widget outside of build.
  double _devicePixelRatio = 1.0;
  Size _viewSize = Size.zero;

  Rect? _lastPushedBounds;
  bool? _lastPushedVisible;
  CefViewGeometry? _lastReportedGeometry;

  /// False while the OS window is minimized or otherwise not shown.
  bool _windowActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = CefNativeController.instance();
    WidgetsBinding.instance.addPostFrameCallback(_onFrame);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final MediaQueryData media = MediaQuery.of(context);
    _devicePixelRatio = media.devicePixelRatio;
    _viewSize = media.size;
  }

  @override
  void didUpdateWidget(CefWindowedView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.url != oldWidget.url) {
      final int? slot = _slot;
      if (slot != null && slot > 0) {
        _controller?.loadUrl(slot: slot, url: widget.url);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Losing focus reports 'inactive' and must keep the browser visible; only a
    // hidden or paused window is worth hiding the native window for.
    final bool active =
        state == AppLifecycleState.resumed ||
        state == AppLifecycleState.inactive;
    if (active == _windowActive) {
      return;
    }
    _windowActive = active;
    _requestSync();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    final int? slot = _slot;
    _slot = null;
    if (slot != null && slot > 0) {
      _controller?.destroyBrowser(slot: slot);
    }
    super.dispose();
  }

  /// Samples the layout box once per rendered frame.
  ///
  /// A post-frame callback does not schedule frames by itself, so an idle UI
  /// costs nothing. Whenever Flutter renders - layout change, scroll, window
  /// resize, DPI change - the geometry is read exactly once and forwarded only
  /// when it actually moved.
  void _onFrame(Duration _) {
    if (!mounted) {
      return;
    }
    _sync();
    WidgetsBinding.instance.addPostFrameCallback(_onFrame);
  }

  /// Makes sure a frame happens so the always-armed [_onFrame] runs.
  void _requestSync() {
    if (!mounted) {
      return;
    }
    WidgetsBinding.instance.scheduleFrame();
  }

  void _sync() {
    final CefNativeController? controller = _controller;
    if (controller == null) {
      return;
    }

    final RenderObject? renderObject = _anchorKey.currentContext
        ?.findRenderObject();
    if (renderObject is! RenderBox ||
        !renderObject.attached ||
        !renderObject.hasSize) {
      // The layout box is gone (for example the list scrolled it out of the
      // cache extent). Never leave a native window floating without an owner.
      _hide();
      return;
    }

    final Rect logicalBounds =
        renderObject.localToGlobal(Offset.zero) & renderObject.size;
    final Rect? normalized = normalizeBounds(
      toPhysicalBounds(logicalBounds, _devicePixelRatio),
    );

    final Rect viewLogicalBounds = Offset.zero & _viewSize;
    final bool onScreen =
        intersects(viewLogicalBounds, logicalBounds) && normalized != null;

    // Only create a browser for a region that is actually reachable, so a widget
    // parked below the fold does not spin up a renderer process.
    if (onScreen && _slot == null) {
      final int slot = controller.createBrowser(
        bounds: normalized,
        url: widget.url,
      );
      if (slot > 0) {
        _slot = slot;
        _lastPushedBounds = normalized;
        _lastPushedVisible = true;
      }
    }

    final bool visible =
        onScreen &&
        widget.visible &&
        _windowActive &&
        (!widget.hideWhenClipped ||
            isFullyInside(viewLogicalBounds, logicalBounds));

    final int? slot = _slot;
    if (slot != null && slot > 0) {
      if (normalized != null &&
          (_lastPushedBounds == null ||
              boundsDiffer(normalized, _lastPushedBounds!))) {
        controller.setBounds(slot: slot, bounds: normalized);
        _lastPushedBounds = normalized;
      }
      if (_lastPushedVisible != visible) {
        controller.setVisible(slot: slot, visible: visible);
        _lastPushedVisible = visible;
      }
    }

    _reportGeometry(logicalBounds, normalized, visible, _slot);
  }

  /// Hides the browser without touching its geometry.
  void _hide() {
    final int? slot = _slot;
    if (slot == null || slot <= 0 || _lastPushedVisible == false) {
      return;
    }
    _controller?.setVisible(slot: slot, visible: false);
    _lastPushedVisible = false;
  }

  void _reportGeometry(Rect logical, Rect? physical, bool visible, int? slot) {
    final ValueChanged<CefViewGeometry>? callback = widget.onGeometryChanged;
    if (callback == null) {
      return;
    }

    final CefViewGeometry geometry = CefViewGeometry(
      logicalBounds: logical,
      physicalBounds: physical ?? Rect.zero,
      visible: visible,
      slot: slot,
    );

    // Reporting only on change keeps an observer that calls setState from
    // feeding itself a new frame every time.
    final CefViewGeometry? previous = _lastReportedGeometry;
    if (previous != null &&
        previous.visible == geometry.visible &&
        previous.slot == geometry.slot &&
        previous.logicalBounds == geometry.logicalBounds &&
        previous.physicalBounds == geometry.physicalBounds) {
      return;
    }

    _lastReportedGeometry = geometry;
    callback(geometry);
  }

  @override
  Widget build(BuildContext context) {
    final bool available = _controller != null;
    return SizedBox.expand(
      key: _anchorKey,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: widget.placeholderColor ?? const Color(0xFFF5F6F7),
          border: Border.all(color: const Color(0xFF9AA0A6)),
        ),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              available
                  ? 'CEF 窗口化渲染区域\n原生子窗口会精确覆盖此边框范围'
                  : 'CEF 原生桥接不可用\n请以 Windows 桌面目标运行（需要 webview_cef_floating_cef.dll）',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 13,
                height: 1.6,
                color: Color(0xFF5F6368),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
