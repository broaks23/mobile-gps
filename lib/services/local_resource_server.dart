import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqlite3/sqlite3.dart';

/// Serves only bundled renderer assets and approved region archive filenames.
class LocalResourceServer {
  LocalResourceServer._(
    this._server,
    this._basePath,
    this._assets,
    this._regions,
  );

  final HttpServer _server;
  final String _basePath;
  final Set<String> _assets;
  final Directory _regions;
  String? activeRegionId;
  void selectRegion(String id) {
    if (!RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(id)) {
      throw const FormatException('Invalid region id');
    }
    activeRegionId = id;
  }

  Uri get indexUri =>
      Uri.parse('http://127.0.0.1:${_server.port}$_basePath/index.html');
  String get basePath => _basePath;
  int get port => _server.port;

  static Future<LocalResourceServer> start() async {
    final support = await getApplicationSupportDirectory();
    final regions = Directory(
      '${support.path}${Platform.pathSeparator}regions',
    );
    await regions.create(recursive: true);
    final assets = (await AssetManifest.loadFromAssetBundle(rootBundle))
        .listAssets()
        .where((name) => name.startsWith('assets/renderer/'))
        .toSet();
    if (!assets.contains('assets/renderer/index.html')) {
      throw StateError(
        'Bundled renderer is missing. Run npm run bundle:app in renderer/.',
      );
    }
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final random = Random.secure();
    final token = List<int>.generate(
      16,
      (_) => random.nextInt(256),
    ).map((byte) => byte.toRadixString(16).padLeft(2, '0')).join();
    final instance = LocalResourceServer._(server, '/$token', assets, regions);
    server.listen(
      (request) => unawaited(instance._handle(request)),
      onError: (Object error, StackTrace stack) {
        developer.log(
          'Local server listener failed',
          name: 'ridgewalk.server',
          error: error,
          stackTrace: stack,
        );
      },
    );
    developer.log(
      'Local map server listening on 127.0.0.1:${server.port}',
      name: 'ridgewalk.server',
    );
    return instance;
  }

  Future<void> close() async {
    await _server.close(force: true);
  }

  Future<void> _handle(HttpRequest request) async {
    final response = request.response;
    try {
      if (request.headers.value(HttpHeaders.hostHeader) !=
              '127.0.0.1:${_server.port}' ||
          (request.method != 'GET' && request.method != 'HEAD')) {
        await _reject(response, HttpStatus.forbidden);
        return;
      }
      final path = request.uri.path;
      if (!path.startsWith('$_basePath/')) {
        await _reject(response, HttpStatus.notFound);
        return;
      }
      response.headers.set('X-Content-Type-Options', 'nosniff');
      response.headers.set('Referrer-Policy', 'no-referrer');
      final relative = path.substring(_basePath.length + 1);
      if (relative == 'config.json') {
        final config = utf8.encode(
          jsonEncode({'regions': await _readRegions()}),
        );
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        await _sendBytes(
          request,
          Uint8List.fromList(config),
          'application/json; charset=utf-8',
        );
        return;
      }
      final peaksMatch = RegExp(
        r'^regions/([a-z0-9_-]{1,64})/peaks\.json$',
      ).firstMatch(relative);
      if (peaksMatch != null) {
        final file = await _safeRegionFile(
          peaksMatch.group(1)!,
          'search.sqlite',
        );
        if (file == null) {
          await _reject(response, HttpStatus.notFound);
          return;
        }
        final db = sqlite3.open(file.path, mode: OpenMode.readOnly);
        try {
          final rows = db.select(
            "SELECT name, category, longitude, latitude, elevation_m FROM places WHERE category IN ('peak','saddle','mountain_pass') LIMIT 50000",
          );
          final features = rows
              .map(
                (row) => {
                  'type': 'Feature',
                  'geometry': {
                    'type': 'Point',
                    'coordinates': [row['longitude'], row['latitude']],
                  },
                  'properties': {
                    'name': row['name'],
                    'category': row['category'],
                    if (row['elevation_m'] != null)
                      'ele': row['elevation_m'].toString(),
                  },
                },
              )
              .toList();
          await _sendBytes(
            request,
            Uint8List.fromList(
              utf8.encode(
                jsonEncode({'type': 'FeatureCollection', 'features': features}),
              ),
            ),
            'application/geo+json',
          );
        } finally {
          db.close();
        }
        return;
      }
      final regionMatch = RegExp(
        r'^regions/([a-z0-9_-]{1,64})/(map|terrain)\.pmtiles$',
      ).firstMatch(relative);
      if (regionMatch != null) {
        final file = await _safeRegionFile(
          regionMatch.group(1)!,
          '${regionMatch.group(2)!}.pmtiles',
        );
        if (file == null) {
          await _reject(response, HttpStatus.notFound);
        } else {
          await _sendFile(request, file);
        }
        return;
      }
      final assetKey = 'assets/renderer/$relative';
      if (!_assets.contains(assetKey)) {
        await _reject(response, HttpStatus.notFound);
        return;
      }
      if (relative == 'index.html') {
        response.headers.set(HttpHeaders.cacheControlHeader, 'no-store');
        response.headers.set(
          'Content-Security-Policy',
          "default-src 'none'; script-src 'self'; style-src 'self' 'unsafe-inline'; img-src 'self' data: blob:; font-src 'self'; connect-src 'self'; worker-src 'self' blob:",
        );
      } else {
        response.headers.set(
          HttpHeaders.cacheControlHeader,
          'public, max-age=31536000, immutable',
        );
      }
      final data = await rootBundle.load(assetKey);
      await _sendBytes(
        request,
        data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes),
        _mime(relative),
      );
    } catch (error, stack) {
      developer.log(
        'Local resource request failed: ${request.uri}',
        name: 'ridgewalk.server',
        error: error,
        stackTrace: stack,
      );
      try {
        response.statusCode = HttpStatus.internalServerError;
        await response.close();
      } catch (_) {
        // The client may have disconnected after a streamed response began.
      }
    }
  }

  Future<List<Map<String, Object>>> _readRegions() async {
    final result = <Map<String, Object>>[];
    await for (final entity in _regions.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
      if (!RegExp(r'^[a-z0-9_-]{1,64}$').hasMatch(id)) continue;
      try {
        final map = await _safeRegionFile(id, 'map.pmtiles');
        final manifest =
            await _safeRegionFile(id, 'package.json') ??
            await _safeRegionFile(id, 'manifest.json');
        final terrain = await _safeRegionFile(id, 'terrain.pmtiles');
        if ((map == null && terrain == null) || manifest == null) continue;
        final raw = jsonDecode(await manifest.readAsString());
        if (raw is! Map<String, dynamic>) continue;
        final bounds = raw['bounds'];
        if (bounds is! List ||
            bounds.length != 4 ||
            bounds.any((value) => value is! num)) {
          continue;
        }
        final west = (bounds[0] as num).toDouble();
        final south = (bounds[1] as num).toDouble();
        final east = (bounds[2] as num).toDouble();
        final north = (bounds[3] as num).toDouble();
        if (![west, south, east, north].every((value) => value.isFinite) ||
            west < -180 ||
            east > 180 ||
            south < -85 ||
            north > 85 ||
            west >= east ||
            south >= north) {
          continue;
        }
        final name = raw['name'];
        if (name is! String || name.isEmpty || name.length > 80) continue;
        final encoding = raw['terrainEncoding'];
        if (map == null &&
            terrain != null &&
            encoding != 'mapbox' &&
            encoding != 'terrarium') {
          continue;
        }
        final region = <String, Object>{
          'id': id,
          'name': name,
          'bounds': [west, south, east, north],
          'attribution': raw['attribution'] is String
              ? raw['attribution'] as String
              : '© OpenStreetMap contributors',
        };
        if (map != null) {
          region['mapUrl'] =
              'http://127.0.0.1:${_server.port}$_basePath/regions/$id/map.pmtiles';
          if (raw['vectorSchema'] == 'ridgewalk-hiking-v1') {
            region['vectorSchema'] = 'ridgewalk-hiking-v1';
          }
          if (raw['vectorSchema'] == 'shortbread-1.0') {
            region['vectorSchema'] = 'shortbread-1.0';
            region['peaksUrl'] =
                'http://127.0.0.1:${_server.port}$_basePath/regions/$id/peaks.json';
          }
          if (raw['mapAttribution'] is String) {
            region['mapAttribution'] = raw['mapAttribution'] as String;
          }
        }
        if (terrain != null &&
            (encoding == 'mapbox' || encoding == 'terrarium')) {
          region['terrainUrl'] =
              'http://127.0.0.1:${_server.port}$_basePath/regions/$id/terrain.pmtiles';
          region['terrainEncoding'] = encoding as String;
          if (raw['terrainAttribution'] is String) {
            region['terrainAttribution'] = raw['terrainAttribution'] as String;
          }
        }
        result.add(region);
      } catch (error, stack) {
        developer.log(
          'Skipping invalid region $id',
          name: 'ridgewalk.server',
          error: error,
          stackTrace: stack,
        );
      }
    }
    result.sort((a, b) {
      if (a['id'] == activeRegionId) return -1;
      if (b['id'] == activeRegionId) return 1;
      return (a['name'] as String).compareTo(b['name'] as String);
    });
    return result;
  }

  Future<File?> _safeRegionFile(String id, String filename) async {
    final root = await _regions.resolveSymbolicLinks();
    final candidate = File(
      '${_regions.path}${Platform.pathSeparator}$id${Platform.pathSeparator}$filename',
    );
    if (!await candidate.exists()) return null;
    final resolved = await candidate.resolveSymbolicLinks();
    if (!resolved.startsWith('$root${Platform.pathSeparator}')) return null;
    return candidate;
  }

  Future<void> _sendFile(HttpRequest request, File file) async {
    final response = request.response;
    final length = await file.length();
    final range = _range(request, length);
    if (range == null) {
      await _rejectRange(response, length);
      return;
    }
    final (start, end, partial) = range;
    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    response.headers.set(
      HttpHeaders.contentTypeHeader,
      'application/octet-stream',
    );
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set(HttpHeaders.contentLengthHeader, end - start + 1);
    response.headers.set(
      HttpHeaders.cacheControlHeader,
      'private, max-age=3600',
    );
    if (partial) {
      response.headers.set('Content-Range', 'bytes $start-$end/$length');
    }
    if (request.method == 'GET') {
      await response.addStream(file.openRead(start, end + 1));
    }
    await response.close();
  }

  Future<void> _sendBytes(
    HttpRequest request,
    Uint8List bytes,
    String mime,
  ) async {
    final response = request.response;
    final range = _range(request, bytes.length);
    if (range == null) {
      await _rejectRange(response, bytes.length);
      return;
    }
    final (start, end, partial) = range;
    response.statusCode = partial ? HttpStatus.partialContent : HttpStatus.ok;
    response.headers.set(HttpHeaders.contentTypeHeader, mime);
    response.headers.set('Accept-Ranges', 'bytes');
    response.headers.set(HttpHeaders.contentLengthHeader, end - start + 1);
    if (partial) {
      response.headers.set(
        'Content-Range',
        'bytes $start-$end/${bytes.length}',
      );
    }
    if (request.method == 'GET') response.add(bytes.sublist(start, end + 1));
    await response.close();
  }

  /// Returns null for an invalid or unsatisfiable single byte range.
  (int, int, bool)? _range(HttpRequest request, int length) {
    if (length == 0) return null;
    final value = request.headers.value(HttpHeaders.rangeHeader);
    if (value == null) return (0, length - 1, false);
    final match = RegExp(r'^bytes=(\d*)-(\d*)$').firstMatch(value);
    if (match == null || (match.group(1)!.isEmpty && match.group(2)!.isEmpty)) {
      return null;
    }
    final first = match.group(1)!;
    final last = match.group(2)!;
    final start = first.isEmpty
        ? length - (int.tryParse(last) ?? 0)
        : int.tryParse(first);
    final end = first.isEmpty
        ? length - 1
        : (last.isEmpty ? length - 1 : int.tryParse(last));
    if (start == null ||
        end == null ||
        start < 0 ||
        start >= length ||
        end < start) {
      return null;
    }
    return (start, min(end, length - 1), true);
  }

  Future<void> _rejectRange(HttpResponse response, int length) async {
    response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
    response.headers.set('Content-Range', 'bytes */$length');
    await response.close();
  }

  Future<void> _reject(HttpResponse response, int status) async {
    response.statusCode = status;
    response.headers.contentType = ContentType.text;
    response.write('Resource unavailable');
    await response.close();
  }

  String _mime(String path) {
    if (path.endsWith('.html')) return 'text/html; charset=utf-8';
    if (path.endsWith('.js')) return 'application/javascript; charset=utf-8';
    if (path.endsWith('.css')) return 'text/css; charset=utf-8';
    if (path.endsWith('.json')) return 'application/json; charset=utf-8';
    if (path.endsWith('.woff2')) return 'font/woff2';
    if (path.endsWith('.png')) return 'image/png';
    if (path.endsWith('.svg')) return 'image/svg+xml';
    return 'application/octet-stream';
  }
}
