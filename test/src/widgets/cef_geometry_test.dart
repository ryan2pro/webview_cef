import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:webview_cef_floating/src/widgets/cef_geometry.dart';

void main() {
  group('toPhysicalBounds', () {
    test('scales every edge by the device pixel ratio', () {
      const Rect logical = Rect.fromLTWH(10, 20, 300, 400);

      expect(
        toPhysicalBounds(logical, 2.0),
        const Rect.fromLTWH(20, 40, 600, 800),
      );
    });

    test('keeps the origin exact for fractional ratios', () {
      const Rect logical = Rect.fromLTWH(12.5, 7.25, 100, 50);

      final Rect physical = toPhysicalBounds(logical, 1.25);

      expect(physical.left, closeTo(15.625, 1e-9));
      expect(physical.top, closeTo(9.0625, 1e-9));
      expect(physical.width, closeTo(125, 1e-9));
      expect(physical.height, closeTo(62.5, 1e-9));
    });

    test('scales by 1.5 without accumulating drift', () {
      const Rect logical = Rect.fromLTWH(10, 10, 100, 100);

      expect(
        toPhysicalBounds(logical, 1.5),
        const Rect.fromLTWH(15, 15, 150, 150),
      );
    });

    test('falls back to 1.0 for non positive ratios', () {
      const Rect logical = Rect.fromLTWH(1, 2, 3, 4);

      expect(toPhysicalBounds(logical, 0), logical);
      expect(toPhysicalBounds(logical, -2), logical);
    });
  });

  group('normalizeBounds', () {
    test('rounds to whole physical pixels', () {
      final Rect? bounds = normalizeBounds(
        const Rect.fromLTWH(10.4, 20.6, 300.5, 400.49),
      );

      expect(bounds, isNotNull);
      expect(bounds!.left, 10);
      expect(bounds.top, 21);
      expect(bounds.width, 301);
      expect(bounds.height, 400);
    });

    test('clamps a sub pixel region up to the minimum extent', () {
      final Rect? bounds = normalizeBounds(const Rect.fromLTWH(0, 0, 0.2, 0.4));

      expect(bounds, isNotNull);
      expect(bounds!.width, kMinNativeExtent.toDouble());
      expect(bounds.height, kMinNativeExtent.toDouble());
    });

    test('returns null for a collapsed region', () {
      expect(normalizeBounds(Rect.zero), isNull);
      expect(normalizeBounds(const Rect.fromLTWH(5, 5, 0, 30)), isNull);
      expect(normalizeBounds(const Rect.fromLTWH(5, 5, 30, -3)), isNull);
    });

    test('composes with the logical to physical conversion', () {
      const Rect logical = Rect.fromLTWH(10.5, 10.5, 100.2, 200.7);

      final Rect? bounds = normalizeBounds(toPhysicalBounds(logical, 1.5));

      expect(bounds, isNotNull);
      expect(bounds!.left, 16);
      expect(bounds.top, 16);
      expect(bounds.width, 150);
      expect(bounds.height, 301);
    });
  });

  group('boundsDiffer', () {
    const Rect reference = Rect.fromLTWH(0, 0, 100, 100);

    test('treats sub pixel drift as unchanged', () {
      expect(
        boundsDiffer(reference, const Rect.fromLTWH(0.4, 0, 100, 100)),
        isFalse,
      );
    });

    test('detects movement at the epsilon threshold', () {
      expect(
        boundsDiffer(reference, const Rect.fromLTWH(1, 0, 100, 100)),
        isTrue,
      );
      expect(
        boundsDiffer(reference, const Rect.fromLTWH(0, 0, 100, 101)),
        isTrue,
      );
    });
  });

  group('isFullyInside', () {
    const Rect view = Rect.fromLTWH(0, 0, 800, 600);

    test('accepts a region contained by the view', () {
      expect(
        isFullyInside(view, const Rect.fromLTWH(10, 10, 100, 100)),
        isTrue,
      );
      expect(isFullyInside(view, view), isTrue);
    });

    test('rejects a region spilling past any edge', () {
      expect(
        isFullyInside(view, const Rect.fromLTWH(-1, 10, 100, 100)),
        isFalse,
      );
      expect(
        isFullyInside(view, const Rect.fromLTWH(10, 10, 100, 600)),
        isFalse,
      );
    });
  });

  group('intersects', () {
    const Rect view = Rect.fromLTWH(0, 0, 800, 600);

    test('is false once a region is fully scrolled out', () {
      expect(intersects(view, const Rect.fromLTWH(0, 700, 100, 100)), isFalse);
    });

    test('is true while any part of a region is on screen', () {
      expect(intersects(view, const Rect.fromLTWH(0, 550, 100, 100)), isTrue);
    });
  });
}
