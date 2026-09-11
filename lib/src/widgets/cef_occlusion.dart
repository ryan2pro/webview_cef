import 'dart:math' as math;

import 'package:flutter/rendering.dart';

import 'cef_geometry.dart' show kBoundsEpsilon;

// Occlusion geometry for a windowed CEF view.
//
// A browser hosted in a real child HWND always paints on top of Flutter
// content, so "being occluded" means Flutter painted something over the slot.
// This file turns the render tree into the set of rectangles that are still
// visible, using two independent signals:
//
//   * ancestor clips ([ancestorClipBounds]) - a scrolling viewport or a clipped
//     container physically limits how much of the slot can be painted;
//   * hit test probes ([probeOccluders]) - sampling the slot and asking which
//     render object is on top at each sample uncovers dialogs, drawers, routes,
//     tooltips and plain sibling widgets painted afterwards.
//
// Everything here is a pure function of the render tree and cheap enough to run
// once per rendered frame, which is what keeps the native window glued to the
// layout without any cross-language traffic while the UI is idle.

/// Samples taken per axis by [probeOccluders] when the caller does not ask for
/// a different resolution.
///
/// The grid only has to *discover* what is covering the slot; the exact bounds
/// come from the render object that was hit, so a coarse grid is enough and
/// keeps the per-frame cost of the probe negligible.
const int kProbeStride = 5;

/// Smallest share of the slot that still counts as visible.
///
/// A sliver thinner than this is treated as fully covered, so a clipping edge
/// sliding across the slot cannot leave a one pixel strip of web content
/// flickering on top of the Flutter UI.
const double kOcclusionAreaThreshold = 0.01;

/// Whether [node] is [ancestor] itself or one of its descendants.
///
/// Hit test paths are walked to tell the slot's own subtree apart from the
/// widgets painted above it; the ancestor direction matters too, because an
/// ancestor that is the topmost hit target means nothing covered the point.
bool isDescendantOf(RenderObject node, RenderObject ancestor) {
  for (
    RenderObject? current = node;
    current != null;
    current = current.parent
  ) {
    if (identical(current, ancestor)) {
      return true;
    }
  }
  return false;
}

/// The region of the Flutter view where [anchor] may actually be painted.
///
/// Every ancestor is asked for the clip it applies through
/// [RenderObject.describeApproximatePaintClip], which is expressed in the
/// ancestor's own coordinate system and is therefore transformed to the global
/// (Flutter view) space before being intersected with the previous result. A
/// [RenderViewport] answers with its visible extent, a [ClipRect] with its
/// rectangle, and an ancestor that does not clip answers null.
///
/// Returns null when no ancestor clips, meaning the anchor is free to paint
/// anywhere it is laid out.
Rect? ancestorClipBounds(RenderObject anchor) {
  if (!anchor.attached) {
    return null;
  }

  Rect? clip;
  RenderObject child = anchor;
  for (RenderObject? node = anchor.parent; node != null; node = node.parent) {
    if (!node.attached) {
      break;
    }
    final Rect? local = node.describeApproximatePaintClip(child);
    if (local != null && local.isFinite && !local.isEmpty) {
      final Rect global = MatrixUtils.transformRect(
        node.getTransformTo(null),
        local,
      );
      clip = clip == null ? global : clip.intersect(global);
    }
    child = node;
  }
  return clip;
}

/// Grid samples [area] and returns the rectangles of whatever is painted on top
/// of [anchor] there.
///
/// [area] is the part of the slot that survived the ancestor clips, expressed
/// in the same global logical space as [anchor]'s bounds. Each sample point is
/// hit tested from the root of [anchor]'s render tree: the first path entry
/// that is neither the anchor nor one of its ancestors or descendants is the
/// object covering that point at that moment, which is exactly the Z-order
/// question that a native child window cannot answer for itself.
///
/// Widgets that do not participate in hit testing - `IgnorePointer`,
/// `Offstage`, fully transparent overlays - are never reported, so an invisible
/// overlay is correctly treated as not occluding anything.
List<Rect> probeOccluders(
  RenderObject anchor,
  Rect area, {
  int stride = kProbeStride,
}) {
  if (stride <= 0 || area.isEmpty || !anchor.attached) {
    return const <Rect>[];
  }

  final RenderView? view = _renderViewOf(anchor);
  if (view == null) {
    return const <Rect>[];
  }

  final List<Rect> occluders = <Rect>[];
  for (int row = 0; row < stride; row++) {
    for (int column = 0; column < stride; column++) {
      final Offset sample = Offset(
        area.left + area.width * (column + 0.5) / stride,
        area.top + area.height * (row + 0.5) / stride,
      );
      final HitTestResult result = HitTestResult();
      view.hitTest(result, position: sample);

      final RenderObject? blocker = _topmostBlocker(result, anchor);
      if (blocker != null) {
        occluders.add(_occluderBounds(anchor, blocker, area));
      }
    }
  }

  return mergeRects(occluders);
}

/// Removes every [cutouts] rectangle from [base] and returns what is left, as a
/// list of non-overlapping rectangles (at most four pieces per cutout).
List<Rect> subtractRects(Rect base, Iterable<Rect> cutouts) {
  if (base.isEmpty) {
    return const <Rect>[];
  }

  List<Rect> pieces = <Rect>[base];
  for (final Rect cutout in cutouts) {
    final Rect cut = cutout.intersect(base);
    if (cut.isEmpty) {
      continue;
    }
    final List<Rect> next = <Rect>[];
    for (final Rect piece in pieces) {
      next.addAll(_subtractPiece(piece, cut));
    }
    pieces = next;
    if (pieces.isEmpty) {
      break;
    }
  }
  return pieces;
}

/// Joins rectangles that describe one contiguous area into as few rectangles as
/// possible.
///
/// Used both to collapse the probe results and to clean up after
/// [subtractRects], so that the region handed to the native layer stays small.
List<Rect> mergeRects(Iterable<Rect> rects, {double epsilon = kBoundsEpsilon}) {
  final List<Rect> working = <Rect>[];
  for (final Rect rect in rects) {
    if (!rect.isEmpty) {
      working.add(rect);
    }
  }
  if (working.length < 2) {
    return working;
  }

  bool merged = true;
  while (merged) {
    merged = false;
    outer:
    for (int i = 0; i < working.length; i++) {
      for (int j = i + 1; j < working.length; j++) {
        final Rect? union = _mergePair(working[i], working[j], epsilon);
        if (union != null) {
          working[i] = union;
          working.removeAt(j);
          merged = true;
          break outer;
        }
      }
    }
  }
  return working;
}

/// Snaps [rects] to whole pixels, growing each rectangle outward.
///
/// Growing rather than shrinking matters: the result is used as a window region
/// in physical pixels, and a region that is a fraction of a pixel too small
/// would let a hairline of web content show through along the seam. Empty
/// rectangles are dropped and the survivors merged.
List<Rect> quantizeRects(Iterable<Rect> rects) {
  final List<Rect> snapped = <Rect>[];
  for (final Rect rect in rects) {
    if (rect.isEmpty) {
      continue;
    }
    final double left = rect.left.floorToDouble();
    final double top = rect.top.floorToDouble();
    snapped.add(
      Rect.fromLTRB(
        left,
        top,
        math.max(left + 1, rect.right.ceilToDouble()),
        math.max(top + 1, rect.bottom.ceilToDouble()),
      ),
    );
  }
  return mergeRects(snapped);
}

/// Bounding box of [rects], or null when there is nothing to bound.
///
/// Used to approximate a clipped region with a single rectangle when the native
/// window region is not available.
Rect? unionBounds(Iterable<Rect> rects) {
  Rect? result;
  for (final Rect rect in rects) {
    if (rect.isEmpty) {
      continue;
    }
    result = result == null ? rect : result.expandToInclude(rect);
  }
  return result;
}

/// Share of [base] covered by [rects], in the range 0..1.
double visibleAreaRatio(Iterable<Rect> rects, Rect base) {
  final double total = base.width * base.height;
  if (total <= 0) {
    return 0;
  }

  double covered = 0;
  for (final Rect rect in rects) {
    final Rect overlap = rect.intersect(base);
    if (!overlap.isEmpty) {
      covered += overlap.width * overlap.height;
    }
  }
  return (covered / total).clamp(0.0, 1.0);
}

/// Whether [rects] still cover all of [target].
///
/// Callers use this to detect the common case of "nothing is clipped", which
/// lets the native side drop its window region entirely instead of carrying one
/// that happens to equal the slot.
bool coversRect(
  Iterable<Rect> rects,
  Rect target, {
  double epsilon = kBoundsEpsilon,
}) {
  if (target.isEmpty) {
    return true;
  }

  double covered = 0;
  for (final Rect rect in rects) {
    final Rect overlap = rect.intersect(target);
    if (!overlap.isEmpty) {
      covered += overlap.width * overlap.height;
    }
  }
  return covered >= target.width * target.height - epsilon;
}

/// Solves the region of [anchor] that is still visible.
///
/// [anchorBounds] is the slot in global logical pixels, [viewBounds] the
/// Flutter view, and the result is the slot clipped by the view, by every
/// clipping ancestor and by everything painted on top of it. An empty list
/// means the view is entirely covered and should be hidden.
///
/// [occluders] short-circuits the probe with a previously obtained set. The
/// rectangles are global, so a caller that throttles the probe can keep reusing
/// them while the slot moves and still subtract them correctly.
List<Rect> computeVisibleRects(
  RenderObject anchor,
  Rect anchorBounds, {
  required Rect viewBounds,
  int stride = kProbeStride,
  List<Rect>? occluders,
}) {
  Rect region = anchorBounds.intersect(viewBounds);
  final Rect? clip = ancestorClipBounds(anchor);
  if (clip != null) {
    region = region.intersect(clip);
  }
  if (region.isEmpty) {
    return const <Rect>[];
  }

  final List<Rect> cutouts =
      occluders ?? probeOccluders(anchor, region, stride: stride);
  if (cutouts.isEmpty) {
    return quantizeRects(<Rect>[region]);
  }
  return quantizeRects(subtractRects(region, cutouts));
}

// --- Internals --------------------------------------------------------------

/// The [RenderView] the anchor belongs to, which is the root a hit test has to
/// start from so that the coordinates of a sample point mean the same thing as
/// the global bounds of the anchor.
RenderView? _renderViewOf(RenderObject node) {
  for (
    RenderObject? current = node;
    current != null;
    current = current.parent
  ) {
    if (current is RenderView) {
      return current;
    }
  }
  return null;
}

/// First entry of [result] that is painted above [anchor].
///
/// The hit test path is ordered from the most specific entry (the topmost thing
/// under the pointer) outward to the root, so everything that belongs to the
/// anchor's own subtree or to one of its ancestors can simply be skipped: if
/// the walk reaches the end, nothing was painted over the sample point.
RenderObject? _topmostBlocker(HitTestResult result, RenderObject anchor) {
  for (final HitTestEntry entry in result.path) {
    final Object target = entry.target;
    if (target is! RenderObject) {
      continue;
    }
    if (isDescendantOf(target, anchor) || isDescendantOf(anchor, target)) {
      continue;
    }
    return target;
  }
  return null;
}

/// Bounds of [blocker], grown upward as long as doing so stays inside [area].
///
/// A probe usually hits the leaf under the pointer - the label inside a panel
/// rather than the panel itself - so the hit is expanded through ancestors while
/// those ancestors stay within the slot. The first ancestor that reaches beyond
/// the slot stops the walk: that is either a full screen wrapper, which paints
/// nothing of its own and must not be reported, or a genuinely large occluder,
/// which some other sample point will have hit directly.
Rect _occluderBounds(RenderObject anchor, RenderObject blocker, Rect area) {
  Rect bounds = _globalPaintBounds(blocker) ?? area;
  RenderObject node = blocker;

  while (true) {
    final RenderObject? parent = node.parent;
    if (parent == null || isDescendantOf(anchor, parent)) {
      break;
    }
    final Rect? parentBounds = _globalPaintBounds(parent);
    if (parentBounds == null || !_covers(area, parentBounds)) {
      break;
    }
    bounds = parentBounds;
    node = parent;
  }

  return bounds.intersect(area);
}

/// Global logical bounds of how [object] paints, or null when it can not be
/// measured (detached, unsized, or an infinite extent such as a sliver).
Rect? _globalPaintBounds(RenderObject object) {
  if (!object.attached) {
    return null;
  }

  Rect local = object.paintBounds;
  if (!local.isFinite || local.isEmpty) {
    if (object is! RenderBox || !object.hasSize) {
      return null;
    }
    local = Offset.zero & object.size;
  }
  if (local.isEmpty) {
    return null;
  }
  return MatrixUtils.transformRect(object.getTransformTo(null), local);
}

/// Splits [piece] around [cut], producing at most four rectangles.
List<Rect> _subtractPiece(Rect piece, Rect cut) {
  final Rect overlap = piece.intersect(cut);
  if (overlap.isEmpty) {
    return <Rect>[piece];
  }

  final List<Rect> pieces = <Rect>[];
  if (overlap.top > piece.top) {
    pieces.add(Rect.fromLTRB(piece.left, piece.top, piece.right, overlap.top));
  }
  if (overlap.bottom < piece.bottom) {
    pieces.add(
      Rect.fromLTRB(piece.left, overlap.bottom, piece.right, piece.bottom),
    );
  }

  final double middleTop = math.max(piece.top, overlap.top);
  final double middleBottom = math.min(piece.bottom, overlap.bottom);
  if (middleBottom > middleTop) {
    if (overlap.left > piece.left) {
      pieces.add(
        Rect.fromLTRB(piece.left, middleTop, overlap.left, middleBottom),
      );
    }
    if (overlap.right < piece.right) {
      pieces.add(
        Rect.fromLTRB(overlap.right, middleTop, piece.right, middleBottom),
      );
    }
  }
  return pieces;
}

/// Union of [a] and [b] when that union is itself a rectangle, otherwise null.
Rect? _mergePair(Rect a, Rect b, double epsilon) {
  if (_covers(a, b)) {
    return a;
  }
  if (_covers(b, a)) {
    return b;
  }

  if (_close(a.left, b.left, epsilon) &&
      _close(a.right, b.right, epsilon) &&
      a.bottom >= b.top - epsilon &&
      b.bottom >= a.top - epsilon) {
    return Rect.fromLTRB(
      a.left,
      math.min(a.top, b.top),
      a.right,
      math.max(a.bottom, b.bottom),
    );
  }
  if (_close(a.top, b.top, epsilon) &&
      _close(a.bottom, b.bottom, epsilon) &&
      a.right >= b.left - epsilon &&
      b.right >= a.left - epsilon) {
    return Rect.fromLTRB(
      math.min(a.left, b.left),
      a.top,
      math.max(a.right, b.right),
      a.bottom,
    );
  }
  return null;
}

/// Whether [outer] contains [inner], ignoring differences below [epsilon].
bool _covers(Rect outer, Rect inner) {
  return outer.left <= inner.left &&
      outer.top <= inner.top &&
      outer.right >= inner.right &&
      outer.bottom >= inner.bottom;
}

bool _close(double a, double b, double epsilon) => (a - b).abs() <= epsilon;
