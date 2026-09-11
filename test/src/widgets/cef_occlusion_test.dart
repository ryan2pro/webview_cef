import 'dart:ui' show Rect;

import 'package:flutter_test/flutter_test.dart';
import 'package:webview_cef_floating/src/widgets/cef_occlusion.dart';

/// Area of [rects], which the solvers keep disjoint so a plain sum is correct.
double _area(Iterable<Rect> rects) {
  double total = 0;
  for (final Rect rect in rects) {
    total += rect.width * rect.height;
  }
  return total;
}

void main() {
  group('subtractRects', () {
    const Rect base = Rect.fromLTWH(0, 0, 100, 100);

    test('returns the base untouched when nothing is cut out', () {
      expect(subtractRects(base, const <Rect>[]), <Rect>[base]);
    });

    test('splits a hole in the middle into four non overlapping pieces', () {
      final List<Rect> pieces = subtractRects(base, const <Rect>[
        Rect.fromLTWH(40, 40, 20, 20),
      ]);

      expect(pieces.length, 4);
      expect(_area(pieces), closeTo(base.width * base.height - 400, 1e-9));
      for (final Rect piece in pieces) {
        expect(
          piece.intersect(const Rect.fromLTWH(40, 40, 20, 20)).isEmpty,
          isTrue,
        );
        expect(base.contains(piece.topLeft), isTrue);
      }
    });

    test('keeps a single strip when the cut is flush with an edge', () {
      final List<Rect> pieces = subtractRects(base, const <Rect>[
        Rect.fromLTWH(0, 0, 100, 40),
      ]);

      expect(pieces, <Rect>[const Rect.fromLTWH(0, 40, 100, 60)]);
    });

    test('collapses to nothing when the base is fully covered', () {
      expect(subtractRects(base, <Rect>[base]), isEmpty);
      expect(
        subtractRects(base, const <Rect>[Rect.fromLTWH(-10, -10, 200, 200)]),
        isEmpty,
      );
    });

    test('ignores cutouts that miss the base', () {
      expect(
        subtractRects(base, const <Rect>[Rect.fromLTWH(200, 200, 10, 10)]),
        <Rect>[base],
      );
    });

    test(
      'subtracts several cutouts without losing or double counting area',
      () {
        final List<Rect> pieces = subtractRects(base, const <Rect>[
          Rect.fromLTWH(0, 0, 30, 30),
          Rect.fromLTWH(50, 20, 30, 60),
          Rect.fromLTWH(10, 70, 40, 30),
        ]);

        // 900 + 1800 + 1200, with no pair of cutouts overlapping.
        expect(_area(pieces), closeTo(10000 - 3900, 1e-9));
        for (final Rect piece in pieces) {
          expect(piece.isEmpty, isFalse);
        }
      },
    );

    test('returns nothing for a collapsed base', () {
      expect(subtractRects(Rect.zero, const <Rect>[]), isEmpty);
    });
  });

  group('mergeRects', () {
    test('joins two rectangles stacked on the same columns', () {
      final List<Rect> merged = mergeRects(const <Rect>[
        Rect.fromLTWH(0, 0, 10, 10),
        Rect.fromLTWH(0, 10, 10, 10),
      ]);

      expect(merged, <Rect>[const Rect.fromLTWH(0, 0, 10, 20)]);
    });

    test('joins two rectangles sitting on the same rows', () {
      final List<Rect> merged = mergeRects(const <Rect>[
        Rect.fromLTWH(0, 0, 10, 10),
        Rect.fromLTWH(10, 0, 10, 10),
      ]);

      expect(merged, <Rect>[const Rect.fromLTWH(0, 0, 20, 10)]);
    });

    test('drops a rectangle that is contained by another', () {
      final List<Rect> merged = mergeRects(const <Rect>[
        Rect.fromLTWH(0, 0, 100, 100),
        Rect.fromLTWH(10, 10, 20, 20),
      ]);

      expect(merged, <Rect>[const Rect.fromLTWH(0, 0, 100, 100)]);
    });

    test('leaves rectangles that only partially overlap alone', () {
      final List<Rect> merged = mergeRects(const <Rect>[
        Rect.fromLTWH(0, 0, 10, 10),
        Rect.fromLTWH(5, 5, 10, 10),
      ]);

      expect(merged.length, 2);
    });

    test('leaves far apart rectangles alone and drops empty ones', () {
      final List<Rect> merged = mergeRects(const <Rect>[
        Rect.fromLTWH(0, 0, 10, 10),
        Rect.fromLTWH(50, 50, 10, 10),
        Rect.fromLTWH(90, 90, 0, 10),
      ]);

      expect(merged.length, 2);
    });
  });

  group('quantizeRects', () {
    test('grows every edge out to whole pixels', () {
      final List<Rect> snapped = quantizeRects(const <Rect>[
        Rect.fromLTWH(10.4, 20.6, 300.5, 400.49),
      ]);

      expect(snapped, <Rect>[const Rect.fromLTRB(10, 20, 311, 422)]);
    });

    test('keeps sub pixel rectangles at the minimum extent', () {
      final List<Rect> snapped = quantizeRects(const <Rect>[
        Rect.fromLTWH(5, 5, 0.2, 0.4),
      ]);

      expect(snapped, <Rect>[const Rect.fromLTRB(5, 5, 6, 6)]);
    });

    test('merges neighbours that touch only after snapping', () {
      final List<Rect> snapped = quantizeRects(const <Rect>[
        Rect.fromLTWH(0.2, 0.1, 10, 10),
        Rect.fromLTWH(10.1, 0.1, 10, 10),
      ]);

      expect(snapped, <Rect>[const Rect.fromLTRB(0, 0, 21, 11)]);
    });

    test('drops collapsed rectangles', () {
      expect(quantizeRects(<Rect>[Rect.zero]), isEmpty);
    });
  });

  group('visibleAreaRatio', () {
    const Rect base = Rect.fromLTWH(0, 0, 100, 100);

    test('is one while the whole slot is covered by the region', () {
      expect(visibleAreaRatio(<Rect>[base], base), 1.0);
    });

    test('is proportional for a partial region', () {
      expect(
        visibleAreaRatio(<Rect>[const Rect.fromLTWH(0, 0, 100, 25)], base),
        closeTo(0.25, 1e-9),
      );
    });

    test('is zero with nothing visible or a collapsed base', () {
      expect(visibleAreaRatio(const <Rect>[], base), 0);
      expect(visibleAreaRatio(<Rect>[base], Rect.zero), 0);
    });

    test('never exceeds one when pieces overlap', () {
      expect(
        visibleAreaRatio(const <Rect>[
          Rect.fromLTWH(0, 0, 80, 100),
          Rect.fromLTWH(0, 0, 80, 100),
        ], base),
        1.0,
      );
    });
  });

  group('coversRect', () {
    const Rect target = Rect.fromLTWH(0, 0, 100, 100);

    test('is true for the target itself and for anything larger', () {
      expect(coversRect(<Rect>[target], target), isTrue);
      expect(
        coversRect(<Rect>[const Rect.fromLTWH(-5, -5, 200, 200)], target),
        isTrue,
      );
    });

    test('is true when several pieces tile the target', () {
      const List<Rect> pieces = <Rect>[
        Rect.fromLTWH(0, 0, 50, 100),
        Rect.fromLTWH(50, 0, 50, 100),
      ];

      expect(coversRect(pieces, target), isTrue);
    });

    test('is false as soon as a sliver is missing', () {
      expect(
        coversRect(<Rect>[const Rect.fromLTWH(0, 0, 100, 99)], target),
        isFalse,
      );
      expect(coversRect(const <Rect>[], target), isFalse);
    });

    test('treats an empty target as covered', () {
      expect(coversRect(const <Rect>[], Rect.zero), isTrue);
    });
  });

  group('unionBounds', () {
    test('is null with nothing to bound', () {
      expect(unionBounds(const <Rect>[]), isNull);
      expect(unionBounds(<Rect>[Rect.zero]), isNull);
    });

    test('returns a single rectangle unchanged', () {
      const Rect only = Rect.fromLTWH(1, 2, 3, 4);

      expect(unionBounds(<Rect>[only]), only);
    });

    test('spans every rectangle', () {
      final Rect? bounds = unionBounds(const <Rect>[
        Rect.fromLTWH(10, 10, 10, 10),
        Rect.fromLTWH(50, 30, 10, 10),
      ]);

      expect(bounds, const Rect.fromLTRB(10, 10, 60, 40));
    });
  });

  group('constants', () {
    test('keep the probe grid and the occlusion threshold usable', () {
      expect(kProbeStride, greaterThan(1));
      expect(kOcclusionAreaThreshold, greaterThan(0));
      expect(kOcclusionAreaThreshold, lessThan(1));
    });
  });
}
