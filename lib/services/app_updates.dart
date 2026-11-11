import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'region_packages.dart' show sha256File;

class AppRelease {
  const AppRelease(this.version, this.asset, this.bytes, this.sha256);
  final String version, sha256;
  final Uri asset;
  final int bytes;
}

class AppUpdates {
  static const _channel = MethodChannel('org.ridgewalk.app/updates');
  static final _latest = Uri.https(
    'api.github.com',
    '/repos/broaks23/mobile-gps/releases/latest',
  );
  static const _maxApk = 500 * 1024 * 1024;

  Future<String> currentVersion() async {
    final info = await _channel.invokeMapMethod<String, dynamic>('version');
    return info?['version'] as String? ?? 'unknown';
  }

  bool _trusted(Uri uri) =>
      uri.scheme == 'https' &&
      uri.userInfo.isEmpty &&
      (uri.host == 'api.github.com' ||
          uri.host == 'github.com' ||
          uri.host.endsWith('.githubusercontent.com'));

  Future<HttpClientResponse> _get(HttpClient client, Uri uri) async {
    for (var redirects = 0; redirects < 6; redirects++) {
      if (!_trusted(uri)) {
        throw const FormatException('Untrusted update download URL');
      }
      final request = await client.getUrl(uri);
      request.followRedirects = false;
      request.headers.set(HttpHeaders.userAgentHeader, 'Ridgewalk-Android');
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      final response = await request.close();
      if ([301, 302, 303, 307, 308].contains(response.statusCode)) {
        final next = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (next == null) throw const FormatException('Missing redirect URL');
        uri = uri.resolve(next);
        continue;
      }
      if (response.statusCode != 200) {
        await response.drain<void>();
        throw HttpException(
          'Update server returned HTTP ${response.statusCode}',
          uri: uri,
        );
      }
      return response;
    }
    throw const FormatException('Too many update redirects');
  }

  Future<String> _text(HttpClient client, Uri uri, int limit) async {
    final response = await _get(client, uri);
    final bytes = <int>[];
    await for (final chunk in response) {
      bytes.addAll(chunk);
      if (bytes.length > limit) {
        throw const FormatException('Update response is too large');
      }
    }
    return utf8.decode(bytes);
  }

  List<int>? _version(String value) {
    final match = RegExp(r'^v?(\d+)\.(\d+)\.(\d+)$').firstMatch(value);
    return match == null
        ? null
        : [int.parse(match[1]!), int.parse(match[2]!), int.parse(match[3]!)];
  }

  Future<AppRelease?> check(String current) async {
    final installed = _version(current);
    if (installed == null) {
      throw const FormatException(
        'Installed version is not a stable semantic version',
      );
    }
    final client = HttpClient();
    try {
      final release = jsonDecode(await _text(client, _latest, 1024 * 1024));
      if (release is! Map ||
          release['draft'] == true ||
          release['prerelease'] == true) {
        throw const FormatException('Invalid release');
      }
      final tag = release['tag_name'];
      final parsed = tag is String ? _version(tag) : null;
      if (parsed == null) {
        throw const FormatException('Release has an invalid version');
      }
      var comparison = 0;
      for (var i = 0; i < 3; i++) {
        if (parsed[i] != installed[i]) {
          comparison = parsed[i].compareTo(installed[i]);
          break;
        }
      }
      if (comparison <= 0) return null;
      final assets = release['assets'];
      if (assets is! List) throw const FormatException('Release has no assets');
      final apkName = 'ridgewalk-$tag.apk';
      final apk = assets
          .whereType<Map>()
          .where((a) => a['name'] == apkName)
          .firstOrNull;
      if (apk == null ||
          apk['size'] is! int ||
          (apk['size'] as int) <= 0 ||
          (apk['size'] as int) > _maxApk) {
        throw const FormatException('Release APK is missing or too large');
      }
      final url = Uri.tryParse(apk['browser_download_url']?.toString() ?? '');
      if (url == null || !_trusted(url)) {
        throw const FormatException('Invalid APK URL');
      }
      var digest = apk['digest']?.toString() ?? '';
      if (digest.startsWith('sha256:')) digest = digest.substring(7);
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        final sums = assets
            .whereType<Map>()
            .where((a) => a['name'] == 'SHA256SUMS.txt')
            .firstOrNull;
        final sumsUrl = Uri.tryParse(
          sums?['browser_download_url']?.toString() ?? '',
        );
        if (sumsUrl == null || !_trusted(sumsUrl)) {
          throw const FormatException('Release checksum is missing');
        }
        final text = await _text(client, sumsUrl, 16384);
        final line = text
            .split('\n')
            .where((s) => s.trim().endsWith('  $apkName'))
            .firstOrNull;
        digest = line?.trim().split(RegExp(r'\s+')).first ?? '';
      }
      if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(digest)) {
        throw const FormatException('Release checksum is invalid');
      }
      return AppRelease(parsed.join('.'), url, apk['size'] as int, digest);
    } finally {
      client.close(force: true);
    }
  }

  Future<String> downloadAndInstall(
    AppRelease release,
    void Function(int, int) progress,
  ) async {
    final dir = Directory(
      '${(await getTemporaryDirectory()).path}${Platform.pathSeparator}updates',
    );
    await dir.create(recursive: true);
    final part = File('${dir.path}${Platform.pathSeparator}update.part');
    final apk = File('${dir.path}${Platform.pathSeparator}update.apk');
    final client = HttpClient();
    try {
      final response = await _get(client, release.asset);
      if (response.contentLength >= 0 &&
          response.contentLength != release.bytes) {
        throw const FormatException('Update size does not match release');
      }
      var count = 0;
      final sink = part.openWrite();
      try {
        await for (final chunk in response) {
          count += chunk.length;
          if (count > release.bytes) {
            throw const FormatException('Update exceeds expected size');
          }
          sink.add(chunk);
          progress(count, release.bytes);
        }
      } finally {
        await sink.flush();
        await sink.close();
      }
      if (count != release.bytes || await sha256File(part) != release.sha256) {
        throw const FormatException('Update checksum mismatch');
      }
      if (await apk.exists()) await apk.delete();
      await part.rename(apk.path);
      return await installDownloaded();
    } finally {
      client.close(force: true);
      if (await part.exists()) await part.delete();
    }
  }

  Future<String> installDownloaded() async =>
      await _channel.invokeMethod<String>('install') ?? 'installer';
}
