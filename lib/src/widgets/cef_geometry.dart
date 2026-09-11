import 'dart:math' as math;
import 'dart:ui' show Rect;

/// Smallest dimension Win32 accepts for a window.
const int kMinNativeExtent = 1;

/// Change threshold, in physical pixels, below which a bounds update is treated
/// as a no-op so that a static layout performs no cross-language calls at all.
const double kBoundsEpsilon = 1.0;

/// Converts a rect expressed in Flutter's logical pixels into the physical pixel
/// rect that the Win32 layer expects.
///
/// This is the only place the conversion happens: the native side deliberately
/// performs no scaling of its own.
Rect toPhysicalBounds(Rect logicalBounds, double devicePixelRatio) {
  final double ratio = devicePixelRatio > 0 ? devicePixelRatio : 1.0;
  return Rect.fromLTWH(
    logicalBounds.left * ratio,
    logicalBounds.top * ratio,
    logicalBounds.width * ratio,
    logicalBounds.height * ratio,
  );
}

/// Rounds [bounds] to whole physical pixels and clamps both dimensions to at
/// least [kMinNativeExtent].
///
/// Returns null when the rect has collapsed, which callers should translate into
/// hiding the browser: a window cannot have a zero-sized client area.
Rect? normalizeBounds(Rect bounds) {
  if (bounds.width <= 0 || bounds.height <= 0) {
    return null;
  }
  return Rect.fromLTWH(
    bounds.left.roundToDouble(),
    bounds.top.roundToDouble(),
    math.max(kMinNativeExtent, bounds.width.round()).toDouble(),
    math.max(kMinNativeExtent, bounds.height.round()).toDouble(),
  );
}

/// Whether [a] and [b] differ by at least [epsilon] on any edge.
bool boundsDiffer(Rect a, Rect b, {double epsilon = kBoundsEpsilon}) {
  return (a.left - b.left).abs() >= epsilon ||
      (a.top - b.top).abs() >= epsilon ||
      (a.width - b.width).abs() >= epsilon ||
      (a.height - b.height).abs() >= epsilon;
}

/// Whether [child] lies entirely within [parent].
///
/// A native child window cannot be clipped by Flutter, so a partially scrolled
/// out widget would spill over unrelated Flutter content. Callers use this to
/// hide the browser instead of letting it overflow.
bool isFullyInside(Rect parent, Rect child) => child.intersect(parent) == child;

/// Whether [a] and [b] share any area.
bool intersects(Rect a, Rect b) => a.overlaps(b);
