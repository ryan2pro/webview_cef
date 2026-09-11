import 'package:flutter/material.dart';

import 'src/native/cef_native_controller.dart';
import 'src/widgets/cef_windowed_view.dart';

const String kDefaultUrl = 'https://example.com';

void main() {
  runApp(const CefDemoApp());
}

class CefDemoApp extends StatelessWidget {
  const CefDemoApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'webview_cef',
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

  /// A Chromium renderer window cannot be occluded by Flutter, so a route that
  /// covers the region has to ask the browser to hide first.
  Future<void> _openFullScreenOverlay() async {
    setState(() => _browserVisible = false);
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
                '因为原生子窗口永远绘制在 Flutter 内容之上，'
                '进入本页面前通过 CefWindowedView.visible = false 主动隐藏了浏览器。',
                textAlign: TextAlign.center,
              ),
            ),
          ),
        ),
      ),
    );
    if (!mounted) {
      return;
    }
    setState(() => _browserVisible = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('CEF 窗口化渲染'),
        actions: <Widget>[
          Center(child: const Text('显示浏览器')),
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
          child: CefWindowedView(
            url: _loadedUrl,
            visible: _browserVisible,
            onGeometryChanged: (CefViewGeometry geometry) {
              setState(() => _geometry = geometry);
            },
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
          ],
        ),
      ),
    );
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
        '窗口化渲染说明：CEF 创建的是真实子 HWND，而不是把画面渲染进纹理。'
        '因此网页区域由系统合成、叠在 Flutter 内容之上，'
        '无法被 Flutter 裁剪或设置圆角；被 Flutter 遮挡时需要主动隐藏。',
        style: TextStyle(fontSize: 12, height: 1.6),
      ),
    );
  }
}
