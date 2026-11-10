import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

import 'services/region_packages.dart';
import 'services/sample_region_installer.dart';

String formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KiB';
  return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MiB';
}

class RegionManager extends StatefulWidget {
  const RegionManager({
    super.key,
    required this.selectedBounds,
    required this.onSelectBounds,
    required this.onInstalled,
    required this.onSelectRegion,
  });
  final List<double>? selectedBounds;
  final VoidCallback onSelectBounds;
  final void Function(String id) onInstalled;
  final void Function(String id) onSelectRegion;

  @override
  State<RegionManager> createState() => _RegionManagerState();
}

class _RegionManagerState extends State<RegionManager> {
  RegionStore? _store;
  final _url = TextEditingController();
  List<CatalogEntry> _catalog = [];
  List<({RegionPackage package, int bytes})> _installed = [];
  String? _error;
  String? _message;
  TransferProgress? _progress;
  TransferCancel? _cancel;
  bool _busy = false;
  String? _detail, _resolution;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      final store = await RegionStore.open();
      final support = await getApplicationSupportDirectory();
      final setting = File(
        '${support.path}${Platform.pathSeparator}catalog-url.txt',
      );
      if (await setting.exists()) {
        _url.text = (await setting.readAsString()).trim();
      }
      if (!mounted) return;
      setState(() => _store = store);
      await _refresh();
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  Future<void> _refresh() async {
    final store = _store;
    if (store == null) return;
    final regions = await store.installed();
    if (mounted) setState(() => _installed = regions);
  }

  Future<void> _fetch() async {
    final store = _store;
    if (store == null) return;
    setState(() {
      _busy = true;
      _error = null;
      _message = null;
    });
    try {
      final uri = Uri.parse(_url.text.trim());
      final catalog = await store.fetchCatalog(uri);
      final support = await getApplicationSupportDirectory();
      await File(
        '${support.path}${Platform.pathSeparator}catalog-url.txt',
      ).writeAsString(uri.toString(), flush: true);
      if (mounted) {
        setState(() {
          _catalog = catalog;
          _message = '${catalog.length} prepared packages available';
        });
      }
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _download(CatalogEntry entry) async {
    final store = _store;
    if (store == null) return;
    final cancel = TransferCancel();
    setState(() {
      _busy = true;
      _cancel = cancel;
      _error = null;
      _message = null;
      _progress = null;
    });
    try {
      await store.download(entry, cancel, (progress) {
        if (mounted) setState(() => _progress = progress);
      });
      widget.onInstalled(entry.package.id);
      await _refresh();
      if (mounted) setState(() => _message = '${entry.package.name} installed');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _cancel = null;
        });
      }
    }
  }

  Future<void> _import() async {
    final store = _store;
    if (store == null) return;
    try {
      final result = await FilePicker.pickFile(type: FileType.any);
      if (result == null) return;
      final path = result.path;
      if (path == null) {
        throw const FileSystemException(
          'Picker did not provide a local package copy',
        );
      }
      final oldIds = _installed.map((item) => item.package.id).toSet();
      setState(() {
        _busy = true;
        _error = null;
        _message = 'Verifying and installing package…';
      });
      await store.importArchive(File(path));
      await _refresh();
      final added = _installed.where(
        (item) => !oldIds.contains(item.package.id),
      );
      if (added.isNotEmpty) widget.onInstalled(added.first.package.id);
      if (mounted) setState(() => _message = 'Package installed');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _sample() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await installBucegiSample();
      await _refresh();
      widget.onInstalled('bucegi');
      if (mounted) setState(() => _message = 'Bucegi sample installed');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(RegionPackage package) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Delete ${package.name}?'),
        content: Text(
          'Remove ${formatBytes(package.unpackedBytes)} of offline map, terrain, and search data?',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Keep'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true || _store == null) return;
    try {
      await _store!.delete(package.id);
      await _refresh();
      if (mounted) setState(() => _message = '${package.name} deleted');
      widget.onInstalled('');
    } catch (error) {
      if (mounted) setState(() => _error = '$error');
    }
  }

  bool _covers(List<double> outer, List<double>? inner) =>
      inner == null ||
      (outer[0] <= inner[0] &&
          outer[1] <= inner[1] &&
          outer[2] >= inner[2] &&
          outer[3] >= inner[3]);

  @override
  void dispose() {
    _url.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final details = _catalog.map((e) => e.package.mapDetail).toSet().toList()
      ..sort();
    final resolutions =
        _catalog.map((e) => e.package.terrainResolution).toSet().toList()
          ..sort();
    final entries = _catalog
        .where(
          (e) =>
              _covers(e.package.bounds, widget.selectedBounds) &&
              (_detail == null || e.package.mapDetail == _detail) &&
              (_resolution == null ||
                  e.package.terrainResolution == _resolution),
        )
        .toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Offline regions')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          const Text(
            'Choose an area on the map',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 6),
          Text(
            widget.selectedBounds == null
                ? 'Select two opposite corners on the map. Prepared packages covering that rectangle will be shown.'
                : 'Selected rectangle: ${widget.selectedBounds!.map((n) => n.toStringAsFixed(4)).join(', ')}',
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: widget.onSelectBounds,
              icon: const Icon(Icons.crop_free),
              label: const Text('Select rectangle'),
            ),
          ),
          const Divider(),
          const Text(
            'Predefined hiking region',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          ListTile(
            title: const Text('Bucegi Mountains sample'),
            subtitle: const Text('Bundled hiking map and 3D terrain'),
            trailing: FilledButton(
              onPressed: _busy ? null : _sample,
              child: const Text('Install'),
            ),
          ),
          const Divider(),
          const Text(
            'Import prepared package',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: OutlinedButton.icon(
              onPressed: _busy ? null : _import,
              icon: const Icon(Icons.file_open),
              label: const Text('Open .rwpkg file'),
            ),
          ),
          const Divider(),
          const Text(
            'Project owner catalog',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          const Text(
            'Enter an HTTPS catalog URL or a private-network HTTP URL. LAN transfers are unencrypted; use a trusted network.',
          ),
          TextField(
            controller: _url,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(labelText: 'Catalog URL'),
          ),
          Align(
            alignment: Alignment.centerLeft,
            child: FilledButton.icon(
              onPressed: _busy ? null : _fetch,
              icon: const Icon(Icons.refresh),
              label: const Text('Load catalog'),
            ),
          ),
          if (_catalog.isNotEmpty) ...[
            Wrap(
              spacing: 12,
              children: [
                DropdownButton<String>(
                  hint: const Text('Map detail'),
                  value: _detail,
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Any map detail'),
                    ),
                    ...details.map(
                      (s) => DropdownMenuItem(value: s, child: Text(s)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _detail = v),
                ),
                DropdownButton<String>(
                  hint: const Text('Terrain resolution'),
                  value: _resolution,
                  items: [
                    const DropdownMenuItem<String>(
                      value: null,
                      child: Text('Any terrain resolution'),
                    ),
                    ...resolutions.map(
                      (s) => DropdownMenuItem(value: s, child: Text(s)),
                    ),
                  ],
                  onChanged: (v) => setState(() => _resolution = v),
                ),
              ],
            ),
            if (entries.isEmpty)
              const Text(
                'No prepared package covers this selection and quality choice.',
              ),
            ...entries.map(
              (entry) => ListTile(
                title: Text(entry.package.name),
                subtitle: Text(
                  '${entry.package.mapDetail} map · ${entry.package.terrainResolution} DEM\n'
                  'Download ${formatBytes(entry.bytes)} · installed ${formatBytes(entry.package.unpackedBytes)}',
                ),
                isThreeLine: true,
                trailing: FilledButton(
                  onPressed: _busy ? null : () => _download(entry),
                  child: const Text('Download'),
                ),
              ),
            ),
          ],
          if (_progress != null) ...[
            const SizedBox(height: 12),
            LinearProgressIndicator(
              value: _progress!.total > 0
                  ? _progress!.transferred / _progress!.total
                  : null,
            ),
            Text(
              '${_progress!.phase}: ${formatBytes(_progress!.transferred)} / ${formatBytes(_progress!.total)}',
            ),
            if (_cancel != null)
              TextButton(
                onPressed: _cancel!.cancel,
                child: const Text('Pause download'),
              ),
          ],
          if (_error != null)
            Text(
              _error!,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          if (_message != null) Text(_message!),
          const Divider(),
          const Text(
            'Installed regions',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
          ),
          if (_installed.isEmpty)
            const Text('No managed regions installed yet.'),
          ..._installed.map(
            (item) => ListTile(
              title: Text(item.package.name),
              subtitle: Text(
                '${formatBytes(item.bytes)} · ${item.package.mapDetail} · ${item.package.terrainResolution}',
              ),
              onTap: () => widget.onSelectRegion(item.package.id),
              trailing: IconButton(
                tooltip: 'Delete region',
                icon: const Icon(Icons.delete_outline),
                onPressed: _busy ? null : () => _delete(item.package),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
