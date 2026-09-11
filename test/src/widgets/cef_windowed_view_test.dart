import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:webview_cef_floating/webview_cef_floating.dart';

/// Records everything the view asks of its browser backend.
///
/// The real controller needs the native library, so the occlusion logic is
/// exercised against this instead: what matters is which rectangles and
/// visibility changes reach the native side.
class _FakeSurface implements CefBrowserSurface {
  _FakeSurface({this.supportsClipping = true});

  @override
  final bool supportsClipping;

  int _nextSlot = 1;
  final List<Rect> created = <Rect>[];
  final List<Rect> bounds = <Rect>[];
  final List<bool> visible = <bool>[];
  final List<List<Rect>> clips = <List<Rect>>[];

  @override
  int createBrowser({required Rect bounds, required String url}) {
    created.add(bounds);
    return _nextSlot++;
  }

  @override
  void setBounds({required int slot, required Rect bounds}) {
    this.bounds.add(bounds);
  }

  @override
  void setVisible({required int slot, required bool visible}) {
    this.visible.add(visible);
  }

  @override
  bool setClip({required int slot, required List<Rect> rects}) {
    clips.add(List<Rect>.of(rects));
    return true;
  }

  @override
  void loadUrl({required int slot, required String url}) {}

  @override
  void destroyBrowser({required int slot}) {}
}

/// A 400x300 surface at a device pixel ratio of one, so that logical and
/// physical rectangles are directly comparable.
Future<void> _pump(
  WidgetTester tester,
  Widget child, {
  GlobalKey<NavigatorState>? navigatorKey,
}) async {
  tester.view.physicalSize = const Size(400, 300);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigatorKey,
      home: Scaffold(body: child),
    ),
  );
}

void main() {
  testWidgets('reports the whole slot when nothing covers it', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      CefWindowedView(url: 'https://example.com', controller: surface),
    );

    expect(tester.takeException(), isNull);
    expect(surface.created, <Rect>[const Rect.fromLTWH(0, 0, 400, 300)]);
    // A region that covers the slot is how "nothing is clipped" is expressed.
    expect(surface.clips.last, <Rect>[const Rect.fromLTWH(0, 0, 400, 300)]);
    expect(surface.visible, isNot(contains(false)));
  });

  testWidgets('clips the browser to the part Flutter leaves visible', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CefWindowedView(url: 'https://example.com', controller: surface),
          const Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: 150,
            child: ColoredBox(color: Color(0xFFFF0000)),
          ),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(surface.clips, isNotEmpty);
    expect(surface.clips.last, <Rect>[const Rect.fromLTWH(0, 150, 400, 150)]);
    expect(surface.visible, isNot(contains(false)));
  });

  testWidgets('keeps the window rectangle while a part of it is clipped', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CefWindowedView(url: 'https://example.com', controller: surface),
          const Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: 150,
            child: ColoredBox(color: Color(0xFFFF0000)),
          ),
        ],
      ),
    );

    // Clipping is a rendering concern: the page keeps its layout and its scroll
    // position, so the window itself never moves or resizes.
    expect(surface.bounds, isEmpty);
  });

  testWidgets('hides the browser when Flutter covers the whole slot', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CefWindowedView(url: 'https://example.com', controller: surface),
          const Positioned.fill(child: ColoredBox(color: Color(0xFFFF0000))),
        ],
      ),
    );

    expect(tester.takeException(), isNull);
    expect(surface.clips.last, isEmpty);
    expect(surface.visible, contains(false));
  });

  testWidgets('clips to what a clipping ancestor lets through', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: 400,
          height: 200,
          child: Stack(
            children: <Widget>[
              Positioned(
                left: 0,
                top: 150,
                width: 400,
                height: 300,
                child: CefWindowedView(
                  url: 'https://example.com',
                  controller: surface,
                ),
              ),
            ],
          ),
        ),
      ),
    );

    expect(tester.takeException(), isNull);
    expect(surface.clips.last, <Rect>[const Rect.fromLTWH(0, 150, 400, 50)]);
  });

  testWidgets('hides instead of clipping on a bridge without regions', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface(supportsClipping: false);

    await _pump(
      tester,
      Stack(
        fit: StackFit.expand,
        children: <Widget>[
          CefWindowedView(url: 'https://example.com', controller: surface),
          const Positioned(
            left: 0,
            top: 0,
            right: 0,
            height: 150,
            child: ColoredBox(color: Color(0xFFFF0000)),
          ),
        ],
      ),
    );

    expect(surface.clips, isEmpty);
    expect(surface.visible, contains(false));
  });

  testWidgets('honours the manual visible override without probing', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      CefWindowedView(
        url: 'https://example.com',
        controller: surface,
        visible: false,
      ),
    );

    expect(surface.visible, contains(false));
  });

  testWidgets('does not re-clip a shape that travels with the slot', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();
    final ScrollController scroll = ScrollController();
    addTearDown(scroll.dispose);

    tester.view.physicalSize = const Size(400, 600);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(
            controller: scroll,
            children: <Widget>[
              const SizedBox(height: 200),
              SizedBox(
                height: 200,
                child: Stack(
                  children: <Widget>[
                    Positioned.fill(
                      child: CefWindowedView(
                        url: 'https://example.com',
                        controller: surface,
                      ),
                    ),
                    const Positioned(
                      left: 0,
                      top: 0,
                      width: 100,
                      height: 200,
                      child: ColoredBox(color: Color(0xFFFF0000)),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 200),
              const SizedBox(height: 200),
            ],
          ),
        ),
      ),
    );

    expect(surface.clips.length, 1);
    final int moved = surface.bounds.length;

    scroll.jumpTo(30);
    await tester.pump();

    // The window follows the scroll...
    expect(surface.bounds.length, greaterThan(moved));
    // ...but the panel travelled with it, so the clipped shape relative to the
    // window did not change and the region must be left alone. Re-sending it
    // every frame is what makes a scrolling browser flicker.
    expect(surface.clips.length, 1);
    expect(surface.visible, isNot(contains(false)));
  });

  testWidgets('gives up the slot to a route pushed over it', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();
    final GlobalKey<NavigatorState> navigator = GlobalKey<NavigatorState>();

    await _pump(
      tester,
      CefWindowedView(url: 'https://example.com', controller: surface),
      navigatorKey: navigator,
    );

    navigator.currentState!.push<void>(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            const Scaffold(body: Center(child: Text('covered'))),
      ),
    );
    await tester.pumpAndSettle();

    // The route is opaque and covers the slot, so nothing of the browser is
    // left to show. This is the case the plugin used to require a manual
    // `visible = false` for.
    expect(surface.clips.last, isEmpty);
    expect(surface.visible.last, isFalse);
  });

  testWidgets('clips around a dialog barrier and its panel', (
    WidgetTester tester,
  ) async {
    final _FakeSurface surface = _FakeSurface();

    await _pump(
      tester,
      CefWindowedView(url: 'https://example.com', controller: surface),
    );

    final BuildContext context = tester.element(find.byType(Scaffold));
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => const Center(
        child: SizedBox(
          width: 100,
          height: 100,
          child: ColoredBox(color: Color(0xFFFFFFFF)),
        ),
      ),
    );
    await tester.pumpAndSettle();

    // The modal barrier is semi transparent and covers everything, which the
    // plugin treats as a full occlusion: a native child window cannot be
    // blended with the scrim.
    expect(surface.clips.last, isEmpty);
    expect(surface.visible.last, isFalse);
  });
}
