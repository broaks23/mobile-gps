import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'services/local_resource_server.dart';
import 'services/sample_region_installer.dart';
import 'region_manager.dart';
import 'search_screen.dart';
import 'services/offline_search.dart';
import 'services/live_location.dart';
import 'location_panel.dart';

final resourceServerProvider = FutureProvider<LocalResourceServer>((ref) async {
  final server = await LocalResourceServer.start();
  ref.onDispose(() => unawaited(server.close()));
  return server;
});

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
  SystemChrome.setSystemUIOverlayStyle(
    const SystemUiOverlayStyle(
      statusBarColor: Colors.transparent,
      systemNavigationBarColor: Colors.transparent,
      statusBarIconBrightness: Brightness.dark,
      systemNavigationBarIconBrightness: Brightness.dark,
    ),
  );
  runApp(const ProviderScope(child: RidgewalkApp()));
}

class RidgewalkApp extends StatelessWidget {
  const RidgewalkApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Ridgewalk',
    debugShowCheckedModeBanner: false,
    theme: ThemeData(
      colorSchemeSeed: const Color(0xff3d6d57),
      useMaterial3: true,
    ),
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
          developer.log(
            'Could not start local map server',
            name: 'ridgewalk.app',
            error: error,
            stackTrace: stack,
          );
          return Center(
            child: Padding(
              padding: const EdgeInsets.all(24),
              child: Text(
                'Could not start the offline map.\n$error',
                textAlign: TextAlign.center,
              ),
            ),
          );
        },
        data: (value) => _MapPane(server: value),
      ),
    );
  }
}

class _MapPane extends ConsumerStatefulWidget {
  const _MapPane({required this.server});
  final LocalResourceServer server;

  @override
  ConsumerState<_MapPane> createState() => _MapPaneState();
}

class _MapPaneState extends ConsumerState<_MapPane>
    with WidgetsBindingObserver {
  late final WebViewController _controller;
  bool _ready = false;
  bool _hasRegion = false;
  bool _hasTerrain = false;
  bool _installing = false;
  String _terrainStatus = 'missing';
  String _terrainMessage = '';
  String _mapStatus = 'missing';
  String _mapMessage = '';
  String _mode = '2d';
  double _exaggeration = 1;
  double _bearing = 0;
  double _centerLatitude = 45.41;
  double _centerLongitude = 25.47;
  List<double>? _selectedBounds;
  SearchResult? _pendingSearchResult;
  AltitudeSource _altitudeSource = AltitudeSource.gps;
  double? _locationTerrain;
  bool _locationTerrainPending = false;
  double? _terrainLatitude, _terrainLongitude;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setBackgroundColor(const Color(0xffdce6dc))
      ..addJavaScriptChannel('HikingBridge', onMessageReceived: _onMessage)
      ..setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            final allowed =
                uri?.scheme == 'http' &&
                uri?.host == '127.0.0.1' &&
                uri?.port == widget.server.port &&
                uri!.path.startsWith('${widget.server.basePath}/');
            if (!allowed) {
              developer.log(
                'Blocked WebView navigation: ${request.url}',
                name: 'ridgewalk.webview',
              );
            }
            return allowed
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            developer.log(
              'WebView resource error: ${error.description}',
              name: 'ridgewalk.webview',
            );
            if (error.isForMainFrame ?? true) {
              _showError('Map page failed to load');
            }
          },
        ),
      )
      ..loadRequest(widget.server.indexUri);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    final location = ref.read(liveLocationProvider.notifier);
    if (state == AppLifecycleState.resumed) {
      unawaited(location.resume());
    } else if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.hidden ||
        state == AppLifecycleState.detached) {
      unawaited(location.suspend());
    }
  }

  void _onMessage(JavaScriptMessage message) {
    try {
      final event = jsonDecode(message.message);
      if (event is! Map<String, dynamic>) {
        throw const FormatException('Invalid bridge payload');
      }
      switch (event['type']) {
        case 'ready':
          if (mounted) {
            setState(() {
              _ready = true;
              _hasRegion = event['hasRegion'] == true;
              _hasTerrain = event['hasTerrain'] == true;
            });
            final pending = _pendingSearchResult;
            if (pending != null) {
              _pendingSearchResult = null;
              unawaited(_showSearchMarker(pending));
            }
            unawaited(_syncLocation(ref.read(liveLocationProvider)));
          }
          break;
        case 'terrainStatus':
          if (mounted) {
            setState(() {
              _terrainStatus = event['status']?.toString() ?? 'error';
              _terrainMessage = event['message']?.toString() ?? '';
              _mode = event['mode'] == '3d' ? '3d' : '2d';
              _exaggeration = (event['exaggeration'] as num?)?.toDouble() ?? 1;
            });
          }
          break;
        case 'mapStatus':
          if (mounted) {
            setState(() {
              _mapStatus = event['status']?.toString() ?? 'error';
              _mapMessage = event['message']?.toString() ?? '';
            });
          }
          break;
        case 'terrainSample':
          developer.log(
            'Rendered terrain elevation: ${event['elevation']} m',
            name: 'ridgewalk.terrain',
          );
          break;
        case 'userMapMove':
          if (ref.read(liveLocationProvider).follow) {
            ref.read(liveLocationProvider.notifier).setFollow(false);
          }
          break;
        case 'locationTerrain':
          final fix = ref.read(liveLocationProvider).position;
          if (mounted &&
              fix != null &&
              event['latitude'] == fix.latitude &&
              event['longitude'] == fix.longitude) {
            setState(() {
              _locationTerrainPending = false;
              _locationTerrain = (event['elevation'] as num?)?.toDouble();
            });
          }
          break;
        case 'error':
          final detail =
              event['message']?.toString() ?? 'Unknown renderer error';
          developer.log('Renderer: $detail', name: 'ridgewalk.renderer');
          _showError('Map resource error');
          break;
        case 'camera':
          if (mounted && event['bearing'] is num) {
            setState(() {
              _bearing = (event['bearing'] as num).toDouble();
              if (event['latitude'] is num) {
                _centerLatitude = (event['latitude'] as num).toDouble();
              }
              if (event['longitude'] is num) {
                _centerLongitude = (event['longitude'] as num).toDouble();
              }
            });
          }
          break;
        case 'notice':
          _showError(event['message']?.toString() ?? 'Map notice');
          break;
        case 'selectionStatus':
          _showError(event['message']?.toString() ?? 'Tap two corners');
          break;
        case 'selectedBounds':
          try {
            final values = event['bounds'];
            if (values is List &&
                values.length == 4 &&
                values.every((v) => v is num)) {
              setState(
                () => _selectedBounds = values
                    .map((v) => (v as num).toDouble())
                    .toList(),
              );
              _openRegions();
            }
          } catch (_) {}
          break;
      }
    } catch (error, stack) {
      developer.log(
        'Invalid renderer message',
        name: 'ridgewalk.bridge',
        error: error,
        stackTrace: stack,
      );
    }
  }

  void _showError(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _send(Map<String, Object?> command) async {
    if (!_ready) return;
    try {
      await _controller.runJavaScript(
        'window.hikingMap?.handleCommand(${jsonEncode(command)});',
      );
    } catch (error, stack) {
      developer.log(
        'Bridge command failed',
        name: 'ridgewalk.bridge',
        error: error,
        stackTrace: stack,
      );
      _showError('Map control failed');
    }
  }

  Future<void> _locate() async {
    final location = ref.read(liveLocationProvider);
    if (location.phase == LocationPhase.off ||
        location.phase == LocationPhase.denied ||
        location.phase == LocationPhase.deniedForever ||
        location.phase == LocationPhase.serviceDisabled ||
        location.phase == LocationPhase.error) {
      await ref.read(liveLocationProvider.notifier).start();
    } else if (location.position != null) {
      await _send({'type': 'centerLocation'});
    }
  }

  Future<void> _syncLocation(LiveLocationState location) async {
    if (!_ready) return;
    final position = location.position;
    if (position == null || location.phase == LocationPhase.off) {
      _terrainLatitude = null;
      _terrainLongitude = null;
      if (mounted) {
        setState(() {
          _locationTerrain = null;
          _locationTerrainPending = false;
        });
      }
      await _send({'type': 'clearLocation'});
      return;
    }
    if (_terrainLatitude != position.latitude ||
        _terrainLongitude != position.longitude) {
      _terrainLatitude = position.latitude;
      _terrainLongitude = position.longitude;
      if (mounted) {
        setState(() {
          _locationTerrain = null;
          _locationTerrainPending = true;
        });
      }
    }
    await _send({
      'type': 'updateLocation',
      'latitude': position.latitude,
      'longitude': position.longitude,
      'accuracy':
          position.hasAccuracy &&
              position.accuracy.isFinite &&
              position.accuracy > 0
          ? position.accuracy
          : null,
      'heading': location.reliableCourse,
      'follow': location.shouldFollow,
    });
  }

  Future<void> _installSample() async {
    if (_installing) return;
    setState(() => _installing = true);
    try {
      await installBucegiSample();
      widget.server.selectRegion('bucegi');
      if (!mounted) return;
      setState(() {
        _ready = false;
        _hasRegion = false;
      });
      await _controller.loadRequest(widget.server.indexUri);
    } catch (error, stack) {
      developer.log(
        'Sample import failed',
        name: 'ridgewalk.import',
        error: error,
        stackTrace: stack,
      );
      _showError('Could not install Bucegi hiking sample: $error');
    } finally {
      if (mounted) setState(() => _installing = false);
    }
  }

  Future<void> _retryMap() async {
    setState(() => _ready = false);
    await _controller.loadRequest(widget.server.indexUri);
  }

  void _reloadRegion(String id) {
    if (id.isNotEmpty) widget.server.selectRegion(id);
    _retryMap();
  }

  void _openRegions() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => RegionManager(
          selectedBounds: _selectedBounds,
          onSelectBounds: () {
            Navigator.of(context).pop();
            _send({'type': 'selectBounds'});
          },
          onInstalled: _reloadRegion,
          onSelectRegion: (id) {
            _reloadRegion(id);
            Navigator.of(context).pop();
          },
        ),
      ),
    );
  }

  Future<void> _openSearch() async {
    final result = await Navigator.of(context).push<SearchResult>(
      MaterialPageRoute(
        builder: (_) => SearchScreen(
          nearLatitude: _centerLatitude,
          nearLongitude: _centerLongitude,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.regionId != null &&
        widget.server.activeRegionId != result.regionId) {
      widget.server.selectRegion(result.regionId!);
      _pendingSearchResult = result;
      await _retryMap();
    } else if (!_ready) {
      _pendingSearchResult = result;
      _showError('The result will appear when the map is ready.');
    } else {
      await _showSearchMarker(result);
    }
    if (!mounted) return;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(result.name, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 4),
              Text(categoryLabel(result.category)),
              if (result.elevationMeters != null)
                Text(
                  'Elevation: ${result.elevationMeters!.toStringAsFixed(0)} m',
                ),
              const SizedBox(height: 12),
              SelectableText(result.coordinates),
              TextButton.icon(
                onPressed: () async {
                  await Clipboard.setData(
                    ClipboardData(text: result.coordinates),
                  );
                  if (context.mounted) {
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('Coordinates copied')),
                    );
                  }
                },
                icon: const Icon(Icons.copy),
                label: const Text('Copy coordinates'),
              ),
              if (result.attributes.isNotEmpty) ...[
                const Divider(),
                Text(
                  'OSM attributes',
                  style: Theme.of(context).textTheme.titleMedium,
                ),
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 250),
                  child: ListView(
                    shrinkWrap: true,
                    children: result.attributes.entries
                        .map(
                          (entry) => Padding(
                            padding: const EdgeInsets.symmetric(vertical: 3),
                            child: Text(
                              '${entry.key.replaceAll('_', ' ')}: ${entry.value}',
                            ),
                          ),
                        )
                        .toList(),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showSearchMarker(SearchResult result) => _send({
    'type': 'showSearchResult',
    'longitude': result.longitude,
    'latitude': result.latitude,
  });

  @override
  Widget build(BuildContext context) {
    final location = ref.watch(liveLocationProvider);
    ref.listen<LiveLocationState>(liveLocationProvider, (previous, next) {
      unawaited(_syncLocation(next));
    });
    return Stack(
      children: [
        Positioned.fill(child: WebViewWidget(controller: _controller)),
        SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    _MapButton(
                      icon: Icons.search,
                      tooltip: 'Offline search',
                      onPressed: _openSearch,
                    ),
                    const SizedBox(width: 8),
                    _MapButton(
                      icon: Icons.offline_pin,
                      tooltip: 'Offline regions',
                      onPressed: _openRegions,
                    ),
                    const SizedBox(width: 8),
                    if (_hasTerrain) _NorthIndicator(bearing: _bearing),
                  ],
                ),
                if (!_hasRegion && _ready)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('No map region installed'),
                          const SizedBox(height: 8),
                          FilledButton.icon(
                            onPressed: _installing ? null : _installSample,
                            icon: _installing
                                ? const SizedBox(
                                    width: 16,
                                    height: 16,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 2,
                                    ),
                                  )
                                : const Icon(Icons.download_for_offline),
                            label: const Text('Install Bucegi hiking sample'),
                          ),
                        ],
                      ),
                    ),
                  ),
                if (_hasRegion && _terrainStatus != 'ready')
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          if (_terrainStatus == 'loading')
                            const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                          if (_terrainStatus == 'loading')
                            const SizedBox(width: 8),
                          Flexible(
                            child: Text(
                              _terrainStatus == 'loading'
                                  ? 'Loading local elevation tiles…'
                                  : _terrainMessage,
                            ),
                          ),
                          if (_terrainStatus == 'error')
                            TextButton(
                              onPressed: _retryMap,
                              child: const Text('Retry'),
                            ),
                        ],
                      ),
                    ),
                  ),
                if (_hasRegion && _mapStatus != 'ready')
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_mapStatus == 'loading')
                                const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                  ),
                                ),
                              if (_mapStatus == 'loading')
                                const SizedBox(width: 8),
                              Flexible(
                                child: Text(
                                  _mapStatus == 'loading'
                                      ? 'Loading local hiking tiles…'
                                      : _mapMessage,
                                ),
                              ),
                              if (_mapStatus == 'error')
                                TextButton(
                                  onPressed: _retryMap,
                                  child: const Text('Retry'),
                                ),
                            ],
                          ),
                          if (_mapStatus == 'missing' || _mapStatus == 'error')
                            TextButton.icon(
                              onPressed: _installing ? null : _installSample,
                              icon: const Icon(Icons.download_for_offline),
                              label: const Text('Install sample hiking map'),
                            ),
                        ],
                      ),
                    ),
                  ),
                const Spacer(),
                if (_hasTerrain)
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          SegmentedButton<String>(
                            segments: const [
                              ButtonSegment(
                                value: '2d',
                                label: Text('2D'),
                                icon: Icon(Icons.map_outlined),
                              ),
                              ButtonSegment(
                                value: '3d',
                                label: Text('3D'),
                                icon: Icon(Icons.terrain),
                              ),
                            ],
                            selected: {_mode},
                            onSelectionChanged: _ready
                                ? (selection) => _send({
                                    'type': 'setView',
                                    'mode': selection.first,
                                  })
                                : null,
                          ),
                          if (_mode == '3d') ...[
                            Text(
                              'Terrain ×${_exaggeration.toStringAsFixed(1)}',
                            ),
                            SizedBox(
                              width: 210,
                              child: Slider(
                                value: _exaggeration.clamp(1.0, 2.5).toDouble(),
                                min: 1,
                                max: 2.5,
                                divisions: 15,
                                label: _exaggeration.toStringAsFixed(1),
                                onChanged: _ready
                                    ? (value) =>
                                          setState(() => _exaggeration = value)
                                    : null,
                                onChangeEnd: (value) => _send({
                                  'type': 'setExaggeration',
                                  'value': value,
                                }),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                if (_hasTerrain) const SizedBox(height: 8),
                _MapButton(
                  icon: Icons.add,
                  tooltip: 'Zoom in',
                  onPressed: _ready ? () => _send({'type': 'zoomIn'}) : null,
                ),
                const SizedBox(height: 8),
                _MapButton(
                  icon: Icons.remove,
                  tooltip: 'Zoom out',
                  onPressed: _ready ? () => _send({'type': 'zoomOut'}) : null,
                ),
                const SizedBox(height: 8),
                _MapButton(
                  icon: Icons.center_focus_strong,
                  tooltip: 'Reset camera',
                  onPressed: _ready
                      ? () => _send({'type': 'resetCamera'})
                      : null,
                ),
                const SizedBox(height: 8),
                _MapButton(
                  icon: Icons.my_location,
                  tooltip: 'My location',
                  onPressed: _locate,
                ),
              ],
            ),
          ),
        ),
        if (location.phase != LocationPhase.off)
          Positioned(
            left: 12,
            top: MediaQuery.paddingOf(context).top + 64,
            child: ConstrainedBox(
              constraints: BoxConstraints(
                maxWidth: math.max(
                  0,
                  math.min(300, MediaQuery.sizeOf(context).width - 80),
                ),
                maxHeight: math.min(
                  300,
                  MediaQuery.sizeOf(context).height * 0.48,
                ),
              ),
              child: LocationPanel(
                location: location,
                altitudeSource: _altitudeSource,
                onAltitudeSource: (value) =>
                    setState(() => _altitudeSource = value),
                terrainElevation: _locationTerrain,
                terrainPending: _locationTerrainPending,
                onStop: () =>
                    unawaited(ref.read(liveLocationProvider.notifier).stop()),
                onFollow: () => ref
                    .read(liveLocationProvider.notifier)
                    .setFollow(!location.follow),
              ),
            ),
          ),
      ],
    );
  }
}

class _NorthIndicator extends StatelessWidget {
  const _NorthIndicator({required this.bearing});
  final double bearing;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'North indicator, map bearing ${bearing.round()} degrees',
    child: Material(
      color: const Color(0xfff7faf0),
      elevation: 3,
      borderRadius: BorderRadius.circular(14),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Transform.rotate(
              angle: -bearing * math.pi / 180,
              child: const Icon(Icons.navigation, size: 20),
            ),
            const SizedBox(width: 4),
            const Text('N', style: TextStyle(fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    ),
  );
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });
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
