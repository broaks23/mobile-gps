import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:archive/archive_io.dart';
import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

const _idPattern = r'^[a-z0-9_-]{1,64}$';
const _shaPattern = r'^[a-f0-9]{64}$';
const _files = ['map.pmtiles', 'terrain.pmtiles', 'search.sqlite'];

class RegionPackage {
  RegionPackage._(
    this.id,
    this.name,
    this.bounds,
    this.mapDetail,
    this.terrainResolution,
    this.terrainEncoding,
    this.terrainTileSize,
    this.vectorSchema,
    this.files,
    this.licenses,
    this.datasetVersions,
    this.mapAttribution,
    this.terrainAttribution,
    this.searchIndexVersion,
  );

  final String id, name, mapDetail, terrainResolution, terrainEncoding;
  final int terrainTileSize;
  final String vectorSchema;
  final int searchIndexVersion;
  final String mapAttribution, terrainAttribution;
  final List<double> bounds;
  final Map<String, (int, String)> files;
  final Map<String, String> licenses, datasetVersions;

  static RegionPackage parse(Object? value) {
    if (value is! Map<String, dynamic> || value['formatVersion'] != 1) {
      throw const FormatException('Unsupported region package version');
    }
    String required(String key, {int max = 256}) {
      final item = value[key];
      if (item is! String || item.isEmpty || item.length > max) {
        throw FormatException('Invalid $key');
      }
      return item;
    }

    final id = required('id', max: 64);
    if (!RegExp(_idPattern).hasMatch(id)) {
      throw const FormatException('Invalid region id');
    }
    final bounds = parseBounds(value['bounds']);
    final fileData = value['files'];
    if (fileData is! Map<String, dynamic> || fileData.length != _files.length) {
      throw const FormatException(
        'Package must contain map, terrain, and search',
      );
    }
    final files = <String, (int, String)>{};
    for (final name in _files) {
      final asset = fileData[name];
      if (asset is! Map<String, dynamic> ||
          asset['bytes'] is! int ||
          (asset['bytes'] as int) <= 0 ||
          asset['sha256'] is! String ||
          !RegExp(_shaPattern).hasMatch(asset['sha256'] as String)) {
        throw FormatException('Invalid $name metadata');
      }
      files[name] = (asset['bytes'] as int, asset['sha256'] as String);
    }
    Map<String, String> stringMap(String key) {
      final raw = value[key];
      if (raw is! Map<String, dynamic> ||
          raw.isEmpty ||
          raw.entries.any(
            (entry) =>
                entry.value is! String ||
                (entry.value as String).isEmpty ||
                (entry.value as String).length > 512,
          )) {
        throw FormatException('Invalid $key');
      }
      return raw.cast<String, String>();
    }

    final encoding = required('terrainEncoding');
    if (encoding != 'mapbox' && encoding != 'terrarium') {
      throw const FormatException('Invalid DEM encoding');
    }
    final detail = required('mapDetail');
    final resolution = required('terrainResolution');
    final schema = required('vectorSchema');
    if (schema != 'ridgewalk-hiking-v1' && schema != 'shortbread-1.0') {
      throw const FormatException('Unsupported vector schema');
    }
    final tileSize =
        value['terrainTileSize'] ?? (schema == 'shortbread-1.0' ? 512 : 256);
    if (tileSize != 256 && tileSize != 512) {
      throw const FormatException('Unsupported DEM tile size');
    }
    final indexVersion = value['searchIndexVersion'] ?? 1;
    if (indexVersion is! int || indexVersion < 1 || indexVersion > 2) {
      throw const FormatException('Unsupported search index version');
    }
    return RegionPackage._(
      id,
      required('name', max: 80),
      bounds,
      detail,
      resolution,
      encoding,
      tileSize as int,
      schema,
      files,
      stringMap('licenses'),
      stringMap('datasetVersions'),
      required('mapAttribution'),
      required('terrainAttribution'),
      indexVersion,
    );
  }

  int get unpackedBytes => files.values.fold(0, (sum, item) => sum + item.$1);
}

List<double> parseBounds(Object? raw) {
  if (raw is! List || raw.length != 4 || raw.any((v) => v is! num)) {
    throw const FormatException('Invalid geographic bounds');
  }
  final b = raw.map((v) => (v as num).toDouble()).toList();
  if (b.any((v) => !v.isFinite) ||
      b[0] < -180 ||
      b[2] > 180 ||
      b[1] < -85 ||
      b[3] > 85 ||
      b[0] >= b[2] ||
      b[1] >= b[3]) {
    throw const FormatException('Invalid geographic bounds');
  }
  return b;
}

class CatalogEntry {
  CatalogEntry._(this.package, this.url, this.bytes, this.sha256);
  final RegionPackage package;
  final Uri url;
  final int bytes;
  final String sha256;

  static CatalogEntry parse(Object? value, {Uri? catalogUri}) {
    if (value is! Map<String, dynamic>) {
      throw const FormatException('Invalid catalog entry');
    }
    final url = Uri.tryParse(value['url']?.toString() ?? '');
    if (url == null ||
        !_allowedCatalogUri(url) ||
        (url.scheme == 'http' &&
            (catalogUri == null ||
                catalogUri.scheme != 'http' ||
                url.host != catalogUri.host ||
                url.port != catalogUri.port))) {
      throw const FormatException(
        'Package URL must be HTTPS or on the same private LAN server',
      );
    }
    final bytes = value['bytes'];
    final sha = value['sha256'];
    if (bytes is! int ||
        bytes <= 0 ||
        bytes > 20 * 1024 * 1024 * 1024 ||
        sha is! String ||
        !RegExp(_shaPattern).hasMatch(sha)) {
      throw const FormatException('Invalid package size or checksum');
    }
    return CatalogEntry._(
      RegionPackage.parse(value['package']),
      url,
      bytes,
      sha,
    );
  }
}

bool _allowedCatalogUri(Uri uri) {
  if (uri.host.isEmpty || uri.userInfo.isNotEmpty || uri.fragment.isNotEmpty) {
    return false;
  }
  if (uri.scheme == 'https') return true;
  if (uri.scheme != 'http') return false;
  final parts = uri.host.split('.');
  if (parts.length != 4) return false;
  final bytes = parts.map(int.tryParse).toList();
  if (bytes.any((n) => n == null || n < 0 || n > 255)) return false;
  return bytes[0] == 10 ||
      (bytes[0] == 172 && bytes[1]! >= 16 && bytes[1]! <= 31) ||
      (bytes[0] == 192 && bytes[1] == 168);
}

List<CatalogEntry> parseCatalog(Object? value, {Uri? catalogUri}) {
  if (value is! Map<String, dynamic> ||
      value['catalogVersion'] != 1 ||
      value['packages'] is! List) {
    throw const FormatException('Unsupported catalog');
  }
  final entries = (value['packages'] as List)
      .map((entry) => CatalogEntry.parse(entry, catalogUri: catalogUri))
      .toList();
  if (entries.length > 1000) {
    throw const FormatException('Catalog is too large');
  }
  return entries;
}

class TransferProgress {
  const TransferProgress(this.phase, this.transferred, this.total);
  final String phase;
  final int transferred, total;
}

class TransferCancel {
  bool cancelled = false;
  void cancel() => cancelled = true;
  void check() {
    if (cancelled) throw const TransferCancelled();
  }
}

class TransferCancelled implements Exception {
  const TransferCancelled();
  @override
  String toString() => 'Download paused';
}

typedef FreeBytes = Future<int> Function();
typedef PackageOpener = Future<PackageResponse> Function(Uri uri, int offset);

class PackageResponse {
  const PackageResponse(
    this.statusCode,
    this.contentLength,
    this.contentRange,
    this.contentEncoding,
    this.body,
  );
  final int statusCode, contentLength;
  final String? contentRange, contentEncoding;
  final Stream<List<int>> body;
}

class RegionStore {
  RegionStore(this.root, {FreeBytes? freeBytes}) : _freeBytes = freeBytes;
  final Directory root;
  final FreeBytes? _freeBytes;
  static const _storage = MethodChannel('org.ridgewalk.app/storage');

  static Future<RegionStore> open() async {
    final support = await getApplicationSupportDirectory();
    final store = RegionStore(support);
    await store._init();
    return store;
  }

  Directory get regions =>
      Directory('${root.path}${Platform.pathSeparator}regions');
  Directory get downloads =>
      Directory('${root.path}${Platform.pathSeparator}downloads');
  Future<void> _init() async {
    await regions.create(recursive: true);
    await downloads.create(recursive: true);
  }

  Future<int> _available() async => _freeBytes != null
      ? _freeBytes()
      : (await _storage.invokeMethod<int>('freeBytes', root.path)) ?? 0;

  Future<void> _ensureSpace(int bytes) async {
    final free = await _available();
    if (free < bytes + 32 * 1024 * 1024) {
      throw FileSystemException(
        'Insufficient storage: need ${bytes + 32 * 1024 * 1024} bytes, have $free',
      );
    }
  }

  Future<List<({RegionPackage package, int bytes})>> installed() async {
    await _init();
    final found = <({RegionPackage package, int bytes})>[];
    await for (final entity in regions.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final id = entity.uri.pathSegments.where((s) => s.isNotEmpty).last;
      if (!RegExp(_idPattern).hasMatch(id)) continue;
      try {
        final manifest = File(
          '${entity.path}${Platform.pathSeparator}package.json',
        );
        if (!await manifest.exists()) continue;
        final package = RegionPackage.parse(
          jsonDecode(await manifest.readAsString()),
        );
        if (package.id != id) continue;
        var bytes = await manifest.length();
        var complete = true;
        for (final name in _files) {
          final file = File('${entity.path}${Platform.pathSeparator}$name');
          if (!await file.exists() ||
              await file.length() != package.files[name]!.$1) {
            complete = false;
            break;
          }
          bytes += await file.length();
        }
        if (complete) found.add((package: package, bytes: bytes));
      } catch (_) {}
    }
    found.sort((a, b) => a.package.name.compareTo(b.package.name));
    return found;
  }

  Future<void> delete(String id) async {
    if (!RegExp(_idPattern).hasMatch(id)) {
      throw const FormatException('Invalid region id');
    }
    final target = Directory('${regions.path}${Platform.pathSeparator}$id');
    if (!await target.exists()) return;
    if (await FileSystemEntity.type(target.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      throw const FileSystemException('Region is not a directory');
    }
    final hidden = Directory(
      '${regions.path}${Platform.pathSeparator}.delete-$id-${DateTime.now().microsecondsSinceEpoch}',
    );
    await target.rename(hidden.path);
    await hidden.delete(recursive: true);
  }

  Future<List<CatalogEntry>> fetchCatalog(Uri uri, {HttpClient? client}) async {
    if (!_allowedCatalogUri(uri)) {
      throw const FormatException(
        'Use HTTPS or an HTTP URL with a private IPv4 address',
      );
    }
    final http = client ?? HttpClient();
    try {
      final request = await http.getUrl(uri);
      request.followRedirects = false;
      final response = await request.close();
      if (response.statusCode != 200 ||
          response.contentLength > 2 * 1024 * 1024) {
        throw HttpException('Catalog HTTP ${response.statusCode}', uri: uri);
      }
      final body = await response.fold<List<int>>(<int>[], (bytes, chunk) {
        bytes.addAll(chunk);
        if (bytes.length > 2 * 1024 * 1024) {
          throw const FormatException('Catalog is too large');
        }
        return bytes;
      });
      return parseCatalog(jsonDecode(utf8.decode(body)), catalogUri: uri);
    } finally {
      if (client == null) http.close();
    }
  }

  Future<void> download(
    CatalogEntry entry,
    TransferCancel cancel,
    void Function(TransferProgress) progress, {
    PackageOpener? opener,
  }) async {
    await _init();
    if ((await installed()).any(
      (item) =>
          item.package.id == entry.package.id ||
          _files.every(
            (name) =>
                item.package.files[name]!.$2 == entry.package.files[name]!.$2,
          ),
    )) {
      throw StateError('Region data already installed');
    }
    final part = File(
      '${downloads.path}${Platform.pathSeparator}${entry.package.id}-${entry.sha256}.part',
    );
    final current = await part.exists() ? await part.length() : 0;
    if (current > entry.bytes) await part.delete();
    var offset = await part.exists() ? await part.length() : 0;
    await _ensureSpace(entry.bytes - offset + entry.package.unpackedBytes);
    final http = opener == null ? HttpClient() : null;
    try {
      cancel.check();
      final PackageResponse response;
      if (opener != null) {
        response = await opener(entry.url, offset);
      } else {
        final request = await http!.getUrl(entry.url);
        request.followRedirects = false;
        request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
        if (offset > 0) {
          request.headers.set(HttpHeaders.rangeHeader, 'bytes=$offset-');
        }
        final raw = await request.close();
        response = PackageResponse(
          raw.statusCode,
          raw.contentLength,
          raw.headers.value(HttpHeaders.contentRangeHeader),
          raw.headers.value(HttpHeaders.contentEncodingHeader),
          raw,
        );
      }
      if (offset > 0 && response.statusCode == 200) {
        // Some HTTPS hosts ignore Range. A full 200 response can safely restart.
        await _ensureSpace(entry.bytes + entry.package.unpackedBytes);
        offset = 0;
      }
      if (response.statusCode != (offset > 0 ? 206 : 200)) {
        throw HttpException(
          'Package HTTP ${response.statusCode}',
          uri: entry.url,
        );
      }
      if (offset > 0 &&
          response.contentRange !=
              'bytes $offset-${entry.bytes - 1}/${entry.bytes}') {
        throw const FormatException(
          'Resume response has incorrect Content-Range',
        );
      }
      if (response.contentEncoding != null ||
          (response.contentLength >= 0 &&
              response.contentLength != entry.bytes - offset)) {
        throw const FormatException(
          'Package response length or encoding changed',
        );
      }
      var transferred = offset;
      final sink = part.openWrite(
        mode: offset > 0 ? FileMode.append : FileMode.write,
      );
      try {
        progress(TransferProgress('Downloading', transferred, entry.bytes));
        await for (final chunk in response.body) {
          cancel.check();
          transferred += chunk.length;
          if (transferred > entry.bytes) {
            throw const FormatException('Package exceeds declared size');
          }
          sink.add(chunk);
          progress(TransferProgress('Downloading', transferred, entry.bytes));
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (transferred != entry.bytes) {
        throw const FormatException('Download interrupted; retry to resume');
      }
      progress(TransferProgress('Verifying', transferred, entry.bytes));
      if (await sha256File(part) != entry.sha256) {
        await part.delete();
        throw const FormatException(
          'Package checksum mismatch; partial file discarded',
        );
      }
      cancel.check();
      await installArchive(part, expected: entry.package);
      await part.delete();
      progress(TransferProgress('Installed', entry.bytes, entry.bytes));
    } finally {
      http?.close(force: true);
    }
  }

  Future<void> importArchive(File archive) async {
    await _init();
    await _ensureSpace(await archive.length() * 2);
    await installArchive(archive);
  }

  Future<void> installArchive(File file, {RegionPackage? expected}) async {
    await _init();
    final input = InputFileStream(file.path);
    try {
      final decoded = ZipDecoder().decodeStream(input, verify: true);
      final names = decoded.files.map((item) => item.name).toList();
      if (names.length != 4 ||
          names.toSet().length != 4 ||
          names.any((name) => !['package.json', ..._files].contains(name)) ||
          decoded.files.any(
            (item) => !item.isFile || item.isSymbolicLink || item.isHardLink,
          )) {
        throw const FormatException('Unexpected package contents');
      }
      final metadata = decoded.files.firstWhere(
        (item) => item.name == 'package.json',
      );
      if (metadata.size > 64 * 1024) {
        throw const FormatException('Package metadata too large');
      }
      final package = RegionPackage.parse(
        jsonDecode(utf8.decode(metadata.readBytes()!)),
      );
      if (expected != null &&
          (package.id != expected.id ||
              package.mapDetail != expected.mapDetail ||
              package.terrainResolution != expected.terrainResolution ||
              package.terrainEncoding != expected.terrainEncoding ||
              package.terrainTileSize != expected.terrainTileSize ||
              package.vectorSchema != expected.vectorSchema ||
              package.searchIndexVersion != expected.searchIndexVersion ||
              jsonEncode(package.bounds) != jsonEncode(expected.bounds) ||
              _files.any(
                (name) =>
                    package.files[name]!.$1 != expected.files[name]!.$1 ||
                    package.files[name]!.$2 != expected.files[name]!.$2,
              ))) {
        throw const FormatException('Package differs from catalog');
      }
      final target = Directory(
        '${regions.path}${Platform.pathSeparator}${package.id}',
      );
      if (await target.exists()) throw StateError('Region already installed');
      if ((await installed()).any(
        (item) => _files.every(
          (name) => item.package.files[name]!.$2 == package.files[name]!.$2,
        ),
      )) {
        throw StateError(
          'This map, terrain, and search data is already installed',
        );
      }
      await _ensureSpace(package.unpackedBytes);
      for (final item in decoded.files.where(
        (item) => item.name != 'package.json',
      )) {
        if (item.size != package.files[item.name]!.$1) {
          throw FormatException('${item.name} size mismatch');
        }
      }
      final stage = Directory(
        '${regions.path}${Platform.pathSeparator}.install-${package.id}-${Random.secure().nextInt(1 << 32)}',
      );
      await stage.create();
      try {
        await extractArchiveToDisk(
          decoded,
          stage.path,
          throwOnError: true,
          maxSize: package.unpackedBytes + 64 * 1024,
        );
        for (final name in _files) {
          final extracted = File('${stage.path}${Platform.pathSeparator}$name');
          if (await extracted.length() != package.files[name]!.$1 ||
              await sha256File(extracted) != package.files[name]!.$2) {
            throw FormatException('$name checksum mismatch');
          }
        }
        await stage.rename(target.path);
      } finally {
        if (await stage.exists()) await stage.delete(recursive: true);
      }
    } finally {
      await input.close();
    }
  }
}

Future<String> sha256File(File file) async =>
    (await sha256.bind(file.openRead()).first).toString();
