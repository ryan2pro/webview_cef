import 'package:flutter/material.dart';
// The only import a host application needs. Note that nothing in this project's
// windows/runner directory mentions CEF: the plugin bootstraps it.
import 'package:webview_cef_floating/webview_cef_floating.dart';

const String kDefaultUrl = 'https://example.com';

void main() {
  runApp(const CefDemoApp());
}

class CefDemoApp extends StatelessWidget {
  const CefDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'webview_cef_floating example',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        useMaterial3: true,
        colorSchemeSeed: const Color(0xFF1A73E8),
      ),
      home: const CefDemoPage(),
    );
  }
}

/// Demonstrates the windowed CEF integration: a real child HWND is overlaid on
/// top of the Flutter view and follows the layout box of [CefWindowedView].
class CefDemoPage extends StatefulWidget {
  const CefDemoPage({super.key});

  @override
  State<CefDemoPage> createState() => _CefDemoPageState();
}

class _CefDemoPageState extends State<CefDemoPage> {
  final TextEditingController _urlController = TextEditingController(
    text: kDefaultUrl,
  );

  String _loadedUrl = kDefaultUrl;
  bool _browserVisible = true;
  CefViewGeometry? _geometry;
  CefOcclusionState? _occlusion;

  /// Position of the draggable panel inside the browser area.
  Offset _panelOffset = const Offset(24, 24);

  /// Draws a semi transparent scrim over the browser.
  bool _scrimVisible = false;

  @override
  void dispose() {
    _urlController.dispose();
    super.dispose();
  }

  void _load() {
    final String url = _urlController.text.trim();
    if (url.isEmpty) {
      return;
    }
    setState(() {
      _loadedUrl = url;
      _browserVisible = true;
    });
  }

  void _reload() {
    final int? slot = _geometry?.slot;
    if (slot == null || slot <= 0) {
      return;
    }
    CefNativeController.instance()?.loadUrl(slot: slot, url: _loadedUrl);
  }

  /// Pushes an opaque full screen route over the browser.
  ///
  /// Nothing has to be done for the browser to get out of the way: the view
  /// notices that Flutter covers it entirely and collapses it until the route is
  /// popped, which is the manual `visible = false` dance this demo used to need.
  Future<void> _openFullScreenOverlay() async {
    final NavigatorState navigator = Navigator.of(context);
    await navigator.push<void>(
      MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (BuildContext context) => Scaffold(
          appBar: AppBar(title: const Text('全屏覆盖层')),
          body: const Padding(
            padding: EdgeInsets.all(24),
            child: Center(
              child: Text(
                '这一层完全遮住了 CEF 区域。\n\n'
                '进入本页面前没有调用 visible = false：'
                '遮挡被自动检测到，网页被整块收起，返回后原样恢复。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// An opaque panel the user can drag over the page.
  ///
  /// What it covers is clipped away rather than hidden: the page keeps its
  /// layout, its scroll position and its input, and only the covered part stops
  /// being presented.
  Widget _buildDragPanel() {
    return GestureDetector(
      onPanUpdate: (DragUpdateDetails details) {
        setState(() => _panelOffset += details.delta);
      },
      child: Container(
        width: 190,
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 14),
        color: const Color(0xFF1A73E8),
        child: const Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Icon(Icons.open_with, size: 16, color: Colors.white),
                SizedBox(width: 6),
                Text(
                  '拖到网页上',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
            SizedBox(height: 6),
            Text(
              '被这块面板盖住的部分会被真正裁掉，'
              '而不是让整个网页消失。',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CEF 窗口化渲染'),
        actions: <Widget>[
          IconButton(
            tooltip: _scrimVisible ? '隐藏半透明遮罩' : '显示半透明遮罩',
            onPressed: () => setState(() => _scrimVisible = !_scrimVisible),
            icon: Icon(
              _scrimVisible ? Icons.gradient : Icons.gradient_outlined,
            ),
          ),
          const Center(child: Text('显示浏览器')),
          Switch(
            value: _browserVisible,
            onChanged: (bool value) => setState(() => _browserVisible = value),
          ),
          const SizedBox(width: 12),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _openFullScreenOverlay,
        icon: const Icon(Icons.fullscreen),
        label: const Text('全屏覆盖层'),
      ),
      body: Column(
        children: <Widget>[
          _buildUrlBar(),
          const Divider(height: 1),
          Expanded(child: _buildScrollableBody()),
        ],
      ),
    );
  }

  Widget _buildUrlBar() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
      child: Row(
        children: <Widget>[
          Expanded(
            child: TextField(
              controller: _urlController,
              decoration: const InputDecoration(
                isDense: true,
                border: OutlineInputBorder(),
                labelText: '网址',
                hintText: 'https://example.com',
              ),
              onSubmitted: (_) => _load(),
            ),
          ),
          const SizedBox(width: 12),
          FilledButton(onPressed: _load, child: const Text('加载')),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _reload,
            tooltip: '重新加载',
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
    );
  }

  Widget _buildScrollableBody() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 96),
      children: <Widget>[
        const _Banner(),
        const SizedBox(height: 16),
        const Text(
          '向下滚动可以看到：原生浏览器窗口会跟随下面这个占位区域移动，'
          '因为它是由 Dart 侧每一帧同步几何信息驱动的。',
        ),
        const SizedBox(height: 16),
        SizedBox(
          height: 420,
          child: Stack(
            children: <Widget>[
              Positioned.fill(
                child: CefWindowedView(
                  url: _loadedUrl,
                  visible: _browserVisible,
                  onGeometryChanged: (CefViewGeometry geometry) {
                    setState(() => _geometry = geometry);
                  },
                  onOcclusionChanged: (CefOcclusionState state) {
                    setState(() => _occlusion = state);
                  },
                ),
              ),
              if (_scrimVisible)
                const Positioned.fill(
                  child: ColoredBox(color: Color(0x66FF5722)),
                ),
              Positioned(
                left: _panelOffset.dx,
                top: _panelOffset.dy,
                child: _buildDragPanel(),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _buildStatusCard(),
        const SizedBox(height: 24),
        for (int index = 0; index < 14; index++)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text('第 ${index + 1} 段占位内容：继续滚动，观察原生窗口是否始终贴合上方边框区域。'),
          ),
      ],
    );
  }

  Widget _buildStatusCard() {
    final CefNativeController? controller = CefNativeController.instance();
    final CefViewGeometry? geometry = _geometry;
    final CefOcclusionState? occlusion = _occlusion;

    return Card(
      margin: EdgeInsets.zero,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              controller == null ? '原生桥接：不可用' : '原生桥接：已就绪',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            if (controller != null)
              _StatusRow(label: '版本', value: controller.version),
            _StatusRow(
              label: '浏览器 slot',
              value: geometry?.slot?.toString() ?? '—',
            ),
            _StatusRow(
              label: '当前可见',
              value: geometry?.visible.toString() ?? '—',
            ),
            _StatusRow(
              label: '逻辑矩形',
              value: _formatRect(geometry?.logicalBounds),
            ),
            _StatusRow(
              label: '物理矩形',
              value: _formatRect(geometry?.physicalBounds),
            ),
            _StatusRow(
              label: '设备像素比',
              value: MediaQuery.of(context).devicePixelRatio.toStringAsFixed(2),
            ),
            _StatusRow(
              label: '区域裁切',
              value: controller == null
                  ? '—'
                  : (controller.supportsClipping ? '可用（SetWindowRgn）' : '不可用'),
            ),
            _StatusRow(label: '遮挡状态', value: _describeOcclusion(occlusion)),
            _StatusRow(
              label: '可见矩形',
              value: occlusion == null
                  ? '—'
                  : '${occlusion.visibleRects.length} 块 '
                        '${occlusion.visibleRects.map(_formatRect).join(' | ')}',
            ),
          ],
        ),
      ),
    );
  }

  String _describeOcclusion(CefOcclusionState? state) {
    if (state == null) {
      return '—';
    }
    if (state.fullyOccluded) {
      return '完全遮挡（已收起）';
    }
    if (state.partial) {
      return '部分遮挡（已裁切）';
    }
    return '完整可见';
  }

  String _formatRect(Rect? rect) {
    if (rect == null) {
      return '—';
    }
    return 'x=${rect.left.toStringAsFixed(0)} '
        'y=${rect.top.toStringAsFixed(0)} '
        'w=${rect.width.toStringAsFixed(0)} '
        'h=${rect.height.toStringAsFixed(0)}';
  }
}

class _StatusRow extends StatelessWidget {
  const _StatusRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 96,
            child: Text(label, style: Theme.of(context).textTheme.bodySmall),
          ),
          Expanded(
            child: Text(value, style: Theme.of(context).textTheme.bodySmall),
          ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner();

  @override
  Widget build(BuildContext context) {
    final ColorScheme colors = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: colors.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(8),
      ),
      child: const Text(
        '窗口化渲染说明：CEF 创建的是真实子 HWND，而不是把画面渲染进纹理，'
        '因此网页区域由系统合成、叠在 Flutter 内容之上。'
        '当 Flutter 内容盖住它时，框架会自动算出仍然可见的矩形，'
        '并通过 SetWindowRgn 把被盖住的部分从窗口上裁掉，网页本身照常运行。',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
    );
  }
}
