import 'package:flutter/material.dart';

import '../native/cef_native_controller.dart';
import 'cef_geometry.dart';
import 'cef_occlusion.dart';

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

/// How a browser that is only partly visible is kept inside its slot.
enum CefClipMode {
  /// Clip through a native window region when the bridge supports it, and hide
  /// the browser when it does not. This is the default: the page keeps its
  /// layout, its scroll position and its input, and only the covered part
  /// disappears.
  auto,

  /// Always clip through a native window region, falling back to hiding on a
  /// bridge that cannot clip.
  region,

  /// Move and resize the window onto the bounding box of the visible region.
  ///
  /// Works with any bridge, at the cost of relaying out the page whenever that
  /// box changes, because the window really does change size.
  geometry,

  /// Hide the browser as soon as any part of it is covered, which is what the
  /// plugin did before region clipping existed. Honours [CefWindowedView
  /// .hideWhenClipped].
  hide,
}

/// Snapshot of how much of the slot Flutter is leaving visible.
@immutable
class CefOcclusionState {
  const CefOcclusionState({
    required this.visibleRects,
    required this.slotBounds,
    required this.fullyOccluded,
    required this.slot,
  });

  /// Parts of the slot the browser may still paint, in logical pixels.
  final List<Rect> visibleRects;

  /// Region the slot occupies in Flutter's logical coordinates.
  final Rect slotBounds;

  /// Whether nothing of the slot is left visible.
  final bool fullyOccluded;

  /// Native browser slot, or null while no browser has been created.
  final int? slot;

  /// Whether some, but not all, of the slot is covered.
  bool get partial => !fullyOccluded && !coversRect(visibleRects, slotBounds);

  @override
  String toString() =>
      'CefOcclusionState(slot: $slot, fullyOccluded: $fullyOccluded, '
      'visibleRects: $visibleRects)';
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
    this.onOcclusionChanged,
    this.hideWhenClipped = true,
    this.clipOccluded = true,
    this.clipMode = CefClipMode.auto,
    this.occlusionProbeStride = kProbeStride,
    this.occlusionProbeInterval = Duration.zero,
    this.occlusionAreaThreshold = kOcclusionAreaThreshold,
    this.controller,
  });

  /// Browser backend, overriding [CefNativeController.instance].
  ///
  /// Left null by applications, which then get the process-wide native
  /// controller. Tests pass a fake [CefBrowserSurface] so the occlusion logic
  /// can be exercised without the native library.
  final CefBrowserSurface? controller;

  /// Page loaded when the browser is created, and again whenever it changes.
  final String url;

  /// Whether the browser may be shown at all.
  ///
  /// Occlusion is handled automatically; this remains the manual override for
  /// cases the detector cannot see, such as a full screen route that covers the
  /// region with something that never participates in hit testing.
  final bool visible;

  /// Background of the Flutter placeholder that sits underneath the browser.
  final Color? placeholderColor;

  /// Reports every geometry change that crosses the FFI boundary.
  final ValueChanged<CefViewGeometry>? onGeometryChanged;

  /// Reports what Flutter is covering, in logical pixels.
  final ValueChanged<CefOcclusionState>? onOcclusionChanged;

  /// Hides the browser whenever the region is not entirely on screen.
  ///
  /// Only consulted by [CefClipMode.hide] now that a partially covered browser
  /// is clipped instead of given up on.
  final bool hideWhenClipped;

  /// Whether Flutter content painted over the slot clips the browser.
  ///
  /// When false the plugin goes back to the pre-clipping behaviour: the browser
  /// keeps its full rectangle and [hideWhenClipped] decides whether it is
  /// hidden.
  final bool clipOccluded;

  /// How the covered part of the slot is removed.
  final CefClipMode clipMode;

  /// Samples taken per axis on each side of the occlusion probe.
  ///
  /// Higher values find thin occluders more reliably at a linear cost in hit
  /// tests per probe. See [probeOccluders].
  final int occlusionProbeStride;

  /// Minimum time between two occlusion probes.
  ///
  /// [Duration.zero] probes on every frame, which is cheap enough for normal
  /// UIs. A longer interval reuses the previous occluder set - the rectangles
  /// are global, so they stay valid while only the slot moves - at the cost of
  /// reacting later to a newly opened overlay.
  final Duration occlusionProbeInterval;

  /// Share of the slot below which the browser counts as fully covered.
  final double occlusionAreaThreshold;

  @override
  State<CefWindowedView> createState() => _CefWindowedViewState();
}

class _CefWindowedViewState extends State<CefWindowedView>
    with WidgetsBindingObserver {
  /// Marks the layout box whose geometry drives the native window.
  final GlobalKey _anchorKey = GlobalKey();

  CefBrowserSurface? _controller;
  int? _slot;

  // Mirrors of MediaQuery values, so the frame callback never has to look up an
  // inherited widget outside of build.
  double _devicePixelRatio = 1.0;
  Size _viewSize = Size.zero;

  Rect? _lastPushedBounds;
  bool? _lastPushedVisible;
  List<Rect>? _lastPushedClip;
  CefViewGeometry? _lastReportedGeometry;
  CefOcclusionState? _lastReportedOcclusion;

  /// Occluder rectangles from the last probe, reused while
  /// [CefWindowedView.occlusionProbeInterval] has not elapsed.
  List<Rect>? _cachedOccluders;
  Duration _lastProbeStamp = Duration.zero;

  /// False while the OS window is minimized or otherwise not shown.
  bool _windowActive = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = widget.controller ?? CefNativeController.instance();
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
    final CefBrowserSurface? controller = _controller;
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
    final Rect viewLogicalBounds = Offset.zero & _viewSize;

    if (!intersects(viewLogicalBounds, logicalBounds)) {
      // Only reach for a region that is actually on screen, so a widget parked
      // below the fold does not spin up a renderer process.
      _hide();
      _reportGeometry(logicalBounds, null, false, _slot);
      return;
    }

    final List<Rect> visibleRects = _visibleRects(
      renderObject,
      logicalBounds,
      viewLogicalBounds,
    );
    final bool fullyOccluded =
        visibleRects.isEmpty ||
        visibleAreaRatio(visibleRects, logicalBounds) <
            widget.occlusionAreaThreshold;

    final CefClipMode mode = _effectiveClipMode(controller);
    // Hiding on any overlap is what the plugin did before region clipping, and
    // it stays available both for bridges that cannot clip and for callers that
    // ask for it explicitly. Without occlusion handling the test falls back to
    // the original one, which only cared about the slot leaving the view.
    final bool clipped = widget.clipOccluded
        ? !coversRect(visibleRects, logicalBounds)
        : !isFullyInside(viewLogicalBounds, logicalBounds);
    final bool hideForClip =
        mode == CefClipMode.hide && widget.hideWhenClipped && clipped;
    final bool visible = !fullyOccluded && !hideForClip;

    // The window normally keeps the rectangle the layout gave it, so the page
    // never relayouts. Geometry mode instead shrinks it onto the bounding box of
    // what is left, which is the only option on a bridge without regions.
    final Rect windowLogical = mode == CefClipMode.geometry
        ? (unionBounds(visibleRects) ?? logicalBounds)
        : logicalBounds;
    final Rect? windowBounds = normalizeBounds(
      toPhysicalBounds(windowLogical, _devicePixelRatio),
    );
    final bool shown = visible && widget.visible && _windowActive;

    if (_slot == null && windowBounds != null) {
      final int slot = controller.createBrowser(
        bounds: windowBounds,
        url: widget.url,
      );
      if (slot > 0) {
        _slot = slot;
        _lastPushedBounds = windowBounds;
        _lastPushedVisible = true;
      }
    }

    final int? slot = _slot;
    if (slot != null && slot > 0) {
      if (windowBounds != null &&
          (_lastPushedBounds == null ||
              boundsDiffer(windowBounds, _lastPushedBounds!))) {
        controller.setBounds(slot: slot, bounds: windowBounds);
        _lastPushedBounds = windowBounds;
      }

      if (_lastPushedVisible != shown) {
        controller.setVisible(slot: slot, visible: shown);
        _lastPushedVisible = shown;
      }

      if (mode == CefClipMode.region) {
        _pushClip(controller, slot, visibleRects, logicalBounds);
      } else if (_lastPushedClip != null) {
        // Switching away from region mode must not leave the browser carrying
        // the region it had before.
        controller.setClip(
          slot: slot,
          rects: <Rect>[toPhysicalBounds(logicalBounds, _devicePixelRatio)],
        );
        _lastPushedClip = null;
      }
    }

    _reportGeometry(logicalBounds, windowBounds, shown, _slot);
    _reportOcclusion(logicalBounds, visibleRects, fullyOccluded, _slot);
  }

  /// Region of the slot that Flutter is not painting over, in logical pixels.
  ///
  /// Returns the whole slot when [CefWindowedView.clipOccluded] is off, which
  /// keeps the pre-clipping behaviour of the widget intact.
  List<Rect> _visibleRects(
    RenderObject anchor,
    Rect logicalBounds,
    Rect viewLogicalBounds,
  ) {
    if (!widget.clipOccluded) {
      return <Rect>[logicalBounds];
    }

    if (widget.occlusionProbeInterval <= Duration.zero) {
      return computeVisibleRects(
        anchor,
        logicalBounds,
        viewBounds: viewLogicalBounds,
        stride: widget.occlusionProbeStride,
      );
    }

    // Throttled: the probe result is in global coordinates, so it stays valid
    // while only the slot moves and can simply be re-subtracted.
    final Duration now = WidgetsBinding.instance.currentFrameTimeStamp;
    List<Rect>? occluders = _cachedOccluders;
    if (occluders == null ||
        now < _lastProbeStamp ||
        now - _lastProbeStamp >= widget.occlusionProbeInterval) {
      occluders = probeOccluders(
        anchor,
        logicalBounds.intersect(viewLogicalBounds),
        stride: widget.occlusionProbeStride,
      );
      _cachedOccluders = occluders;
      _lastProbeStamp = now;
    }

    return computeVisibleRects(
      anchor,
      logicalBounds,
      viewBounds: viewLogicalBounds,
      stride: widget.occlusionProbeStride,
      occluders: occluders,
    );
  }

  /// Resolves [CefWindowedView.clipMode] against what the bridge can actually
  /// do, so a build without region support still degrades predictably.
  CefClipMode _effectiveClipMode(CefBrowserSurface controller) {
    switch (widget.clipMode) {
      case CefClipMode.geometry:
      case CefClipMode.hide:
        return widget.clipMode;
      case CefClipMode.auto:
      case CefClipMode.region:
        return controller.supportsClipping
            ? CefClipMode.region
            : CefClipMode.hide;
    }
  }

  /// Hands the visible region to the native layer as a window region.
  void _pushClip(
    CefBrowserSurface controller,
    int slot,
    List<Rect> visibleRects,
    Rect logicalBounds,
  ) {
    // A region that covers the slot means nothing is clipped; sending the slot
    // itself is how the native side is told to drop its region.
    final List<Rect> target = coversRect(visibleRects, logicalBounds)
        ? <Rect>[logicalBounds]
        : visibleRects;
    final Rect window = toPhysicalBounds(logicalBounds, _devicePixelRatio);
    final List<Rect> physical = quantizeRects(<Rect>[
      for (final Rect rect in target) toPhysicalBounds(rect, _devicePixelRatio),
    ]);

    // Compared relative to the window, because that is the space the native side
    // keeps its region in. Scrolling a slot whose clipped shape does not change
    // - an overlay travelling with the page, for instance - therefore costs
    // nothing here at all, and never reaches the window.
    final List<Rect> relative = <Rect>[
      for (final Rect rect in physical) rect.shift(-window.topLeft),
    ];
    if (!_clipDiffers(relative, _lastPushedClip)) {
      return;
    }
    controller.setClip(slot: slot, rects: physical);
    _lastPushedClip = relative;
  }

  bool _clipDiffers(List<Rect> next, List<Rect>? previous) {
    if (previous == null || next.length != previous.length) {
      return true;
    }
    for (int i = 0; i < next.length; i++) {
      if (boundsDiffer(next[i], previous[i])) {
        return true;
      }
    }
    return false;
  }

  bool _sameRects(List<Rect> a, List<Rect> b) {
    if (a.length != b.length) {
      return false;
    }
    for (int i = 0; i < a.length; i++) {
      if (a[i] != b[i]) {
        return false;
      }
    }
    return true;
  }

  void _reportOcclusion(
    Rect slotBounds,
    List<Rect> visibleRects,
    bool fullyOccluded,
    int? slot,
  ) {
    final ValueChanged<CefOcclusionState>? callback = widget.onOcclusionChanged;
    if (callback == null) {
      return;
    }

    final CefOcclusionState state = CefOcclusionState(
      visibleRects: visibleRects,
      slotBounds: slotBounds,
      fullyOccluded: fullyOccluded,
      slot: slot,
    );

    // Reporting only on change keeps an observer that calls setState from
    // feeding itself a new frame every time.
    final CefOcclusionState? previous = _lastReportedOcclusion;
    if (previous != null &&
        previous.fullyOccluded == state.fullyOccluded &&
        previous.slot == state.slot &&
        previous.slotBounds == state.slotBounds &&
        _sameRects(previous.visibleRects, state.visibleRects)) {
      return;
    }

    _lastReportedOcclusion = state;
    callback(state);
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
              available ? 'CEF 窗口化渲染区域\n原生子窗口会精确覆盖此边框范围' : 'CEF 原生桥接不可用\n请以 Windows 桌面目标运行（需要 webview_cef_floating_cef.dll）',
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
