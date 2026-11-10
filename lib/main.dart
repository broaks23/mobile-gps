import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:geolocator/geolocator.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'services/local_resource_server.dart';

final resourceServerProvider = FutureProvider<LocalResourceServer>((ref) async {
  final server = await LocalResourceServer.start();
  ref.onDispose(() => unawaited(server.close()));
  return server;
});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(const SystemUiOverlayStyle(
    statusBarColor: Colors.transparent,
    systemNavigationBarColor: Colors.transparent,
    statusBarIconBrightness: Brightness.dark,
    systemNavigationBarIconBrightness: Brightness.dark,
  ));
  runApp(const ProviderScope(child: RidgewalkApp()));
}

class RidgewalkApp extends StatelessWidget {
  const RidgewalkApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
        title: 'Ridgewalk',
        debugShowCheckedModeBanner: false,
        theme: ThemeData(colorSchemeSeed: const Color(0xff3d6d57), useMaterial3: true),
        home: const MapScreen(),
      );
}

class MapScreen extends ConsumerWidget {
  const MapScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final server = ref.watch(resourceServerProvider);
    return Scaffold(
      body: server.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, stack) {
          developer.log('Could not start local map server', name: 'ridgewalk.app', error: error, stackTrace: stack);
          return Center(child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text('Could not start the offline map.\n$error', textAlign: TextAlign.center),
          ));
        },
        data: (value) => _MapPane(server: value),
      ),
    );
  }
}

class _MapPane extends StatefulWidget {
  const _MapPane({required this.server});
  final LocalResourceServer server;

  @override
  State<_MapPane> createState() => _MapPaneState();
}

class _MapPaneState extends State<_MapPane> {
  late final WebViewController _controller;
  bool _ready = false;
  bool _hasTerrain = false;

  @override
  void initState() {
    super.initState();
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xffdce6dc))
      ..addJavaScriptChannel('HikingBridge', onMessageReceived: _onMessage)
      ..setNavigationDelegate(NavigationDelegate(
        onNavigationRequest: (request) {
          final uri = Uri.tryParse(request.url);
          final allowed = uri?.scheme == 'http' &&
              uri?.host == '127.0.0.1' &&
              uri?.port == widget.server.port &&
              uri!.path.startsWith('${widget.server.basePath}/');
          if (!allowed) {
            developer.log('Blocked WebView navigation: ${request.url}', name: 'ridgewalk.webview');
          }
          return allowed ? NavigationDecision.navigate : NavigationDecision.prevent;
        },
        onWebResourceError: (error) {
          developer.log('WebView resource error: ${error.description}', name: 'ridgewalk.webview');
          if (error.isForMainFrame ?? true) _showError('Map page failed to load');
        },
      ))
      ..loadRequest(widget.server.indexUri);
  }

  void _onMessage(JavaScriptMessage message) {
    try {
      final event = jsonDecode(message.message);
      if (event is! Map<String, dynamic>) throw const FormatException('Invalid bridge payload');
      switch (event['type']) {
        case 'ready':
          if (mounted) setState(() {
            _ready = true;
            _hasTerrain = event['hasTerrain'] == true;
          });
          break;
        case 'error':
          final detail = event['message']?.toString() ?? 'Unknown renderer error';
          developer.log('Renderer: $detail', name: 'ridgewalk.renderer');
          _showError('Map resource error');
          break;
        case 'camera':
          developer.log('Camera: ${event['latitude']}, ${event['longitude']}, z=${event['zoom']}', name: 'ridgewalk.camera');
          break;
      }
    } catch (error, stack) {
      developer.log('Invalid renderer message', name: 'ridgewalk.bridge', error: error, stackTrace: stack);
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send(Map<String, Object> command) async {
    if (!_ready) return;
    try {
      await _controller.runJavaScript('window.hikingMap?.handleCommand(${jsonEncode(command)});');
    } catch (error, stack) {
      developer.log('Bridge command failed', name: 'ridgewalk.bridge', error: error, stackTrace: stack);
      _showError('Map control failed');
    }
  }

  Future<void> _locate() async {
    try {
      if (!await Geolocator.isLocationServiceEnabled()) {
        _showError('Enable device location to use GPS');
        return;
      }
      var permission = await Geolocator.checkPermission();
      if (permission == LocationPermission.denied) permission = await Geolocator.requestPermission();
      if (permission == LocationPermission.denied || permission == LocationPermission.deniedForever) {
        _showError('Location permission is required for GPS');
        return;
      }
      final position = await Geolocator.getCurrentPosition();
      await _send({'type': 'flyTo', 'longitude': position.longitude, 'latitude': position.latitude});
    } catch (error, stack) {
      developer.log('GPS lookup failed', name: 'ridgewalk.location', error: error, stackTrace: stack);
      _showError('Could not get GPS location');
    }
  }

  @override
  Widget build(BuildContext context) => Stack(children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        SafeArea(child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            const Spacer(),
            _MapButton(icon: Icons.add, tooltip: 'Zoom in', onPressed: _ready ? () => _send({'type': 'zoomIn'}) : null),
            const SizedBox(height: 8),
            _MapButton(icon: Icons.remove, tooltip: 'Zoom out', onPressed: _ready ? () => _send({'type': 'zoomOut'}) : null),
            const SizedBox(height: 8),
            _MapButton(icon: Icons.explore_outlined, tooltip: 'Reset view', onPressed: _ready ? () => _send({'type': 'resetBearing'}) : null),
            if (_hasTerrain) ...[
              const SizedBox(height: 8),
              _MapButton(icon: Icons.terrain, tooltip: 'Toggle terrain', onPressed: _ready ? () => _send({'type': 'toggleTerrain'}) : null),
            ],
            const SizedBox(height: 8),
            _MapButton(icon: Icons.my_location, tooltip: 'My location', onPressed: _ready ? _locate : null),
          ]),
        )),
      ]);
}

class _MapButton extends StatelessWidget {
  const _MapButton({required this.icon, required this.tooltip, required this.onPressed});
  final IconData icon;
  final String tooltip;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Material(
        color: const Color(0xfff7faf0),
        elevation: 3,
        borderRadius: BorderRadius.circular(14),
        child: IconButton(icon: Icon(icon), tooltip: tooltip, onPressed: onPressed),
      );
}
