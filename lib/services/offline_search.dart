import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:sqlite3/sqlite3.dart';

import 'region_packages.dart';

class SearchResult {
  const SearchResult({
    required this.featureId,
    required this.name,
    required this.category,
    required this.latitude,
    required this.longitude,
    required this.distanceMeters,
    required this.attributes,
    this.regionId,
    this.elevationMeters,
  });

  final String featureId, name, category;
  final String? regionId;
  final double latitude, longitude, distanceMeters;
  final double? elevationMeters;
  final Map<String, String> attributes;

  String get coordinates =>
      '${latitude.toStringAsFixed(6)}, ${longitude.toStringAsFixed(6)}';
}

class OfflineSearch {
  OfflineSearch(this.store);
  final RegionStore store;

  static SearchResult? parseCoordinates(
    String input, {
    double nearLatitude = 0,
    double nearLongitude = 0,
  }) {
    final match = RegExp(
      r'^\s*([+-]?\d{1,2}(?:\.\d+)?)\s*[,;\s]\s*([+-]?\d{1,3}(?:\.\d+)?)\s*$',
    ).firstMatch(input);
    if (match == null) return null;
    final latitude = double.tryParse(match.group(1)!);
    final longitude = double.tryParse(match.group(2)!);
    if (latitude == null ||
        longitude == null ||
        latitude.abs() > 90 ||
        longitude.abs() > 180) {
      return null;
    }
    return SearchResult(
      featureId: 'coordinates:$latitude,$longitude',
      name: 'Coordinates',
      category: 'coordinates',
      latitude: latitude,
      longitude: longitude,
      distanceMeters: distanceMeters(
        nearLatitude,
        nearLongitude,
        latitude,
        longitude,
      ),
      attributes: const {},
    );
  }

  Future<List<SearchResult>> search(
    String input, {
    required double nearLatitude,
    required double nearLongitude,
    int limit = 30,
  }) async {
    final query = input.trim();
    if (query.isEmpty) return [];
    final coordinate = parseCoordinates(
      query,
      nearLatitude: nearLatitude,
      nearLongitude: nearLongitude,
    );
    if (coordinate != null) return [coordinate];
    final tokens = RegExp(
      r'[\p{L}\p{N}]+',
      unicode: true,
    ).allMatches(query).map((m) => m.group(0)!).take(8).toList();
    if (tokens.isEmpty) return [];
    // Quoted tokens prevent FTS query operators in user input from being executed.
    final match = tokens.map((token) => '"$token"*').join(' ');
    final byId = <String, SearchResult>{};
    final byPlace = <String>{};
    final regions = await store.installed();
    regions.sort(
      (a, b) => (b.package.datasetVersions['osm'] ?? '').compareTo(
        a.package.datasetVersions['osm'] ?? '',
      ),
    );
    for (final installed in regions) {
      final package = installed.package;
      final file = File(
        '${store.regions.path}${Platform.pathSeparator}${package.id}'
        '${Platform.pathSeparator}search.sqlite',
      );
      if (await FileSystemEntity.type(file.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final Database db = sqlite3.open(file.path, mode: OpenMode.readOnly);
      try {
        final actualVersion =
            (db.select('PRAGMA user_version').single.columnAt(0) as int);
        if (package.searchIndexVersion == 2 && actualVersion != 2) {
          throw FormatException(
            'Search index for ${package.name} has an incompatible version',
          );
        }
        final sql = package.searchIndexVersion == 2
            ? '''SELECT p.feature_id, p.name, p.category, p.latitude, p.longitude,
                   p.elevation_m, p.attributes_json
                 FROM place_fts JOIN places p ON p.id = place_fts.rowid
                 WHERE place_fts MATCH ? LIMIT 100'''
            : '''SELECT CAST(p.id AS TEXT) AS feature_id, p.name,
                   p.kind AS category, p.latitude, p.longitude, p.elevation_m,
                   '{}' AS attributes_json
                 FROM place_fts JOIN places p ON p.id = place_fts.rowid
                 WHERE place_fts MATCH ? LIMIT 100''';
        for (final row in db.select(sql, [match])) {
          final latitude = (row['latitude'] as num).toDouble();
          final longitude = (row['longitude'] as num).toDouble();
          final name = row['name'] as String;
          final rawCategory = row['category'] as String;
          final category = switch (rawCategory) {
            'alpine_hut' || 'wilderness_hut' => 'mountain_hut',
            'camp_site' => 'campsite',
            'trail' => 'hiking_trail',
            _ => rawCategory,
          };
          final featureId = package.searchIndexVersion == 2
              ? row['feature_id'] as String
              : 'legacy:${package.id}/${row['feature_id']}';
          final attributesRaw = jsonDecode(row['attributes_json'] as String);
          final attributes = attributesRaw is Map<String, dynamic>
              ? attributesRaw.map(
                  (key, value) => MapEntry(key, value.toString()),
                )
              : <String, String>{};
          final result = SearchResult(
            featureId: featureId,
            name: name,
            category: category,
            latitude: latitude,
            longitude: longitude,
            elevationMeters: (row['elevation_m'] as num?)?.toDouble(),
            distanceMeters: distanceMeters(
              nearLatitude,
              nearLongitude,
              latitude,
              longitude,
            ),
            attributes: attributes,
            regionId: package.id,
          );
          final placeKey =
              '${foldName(name)}|$category|'
              '${latitude.toStringAsFixed(5)}|${longitude.toStringAsFixed(5)}';
          if (byId.containsKey(featureId) || byPlace.contains(placeKey)) {
            continue;
          }
          byId[featureId] = result;
          byPlace.add(placeKey);
        }
      } finally {
        db.close();
      }
    }
    final normalized = foldName(query);
    int nameRank(SearchResult result) {
      final name = foldName(result.name);
      if (name == normalized) return 0;
      if (name.startsWith(normalized)) return 1;
      if (name.contains(normalized)) return 2;
      return 3;
    }

    final results = byId.values.toList()
      ..sort((a, b) {
        final rank = nameRank(a).compareTo(nameRank(b));
        if (rank != 0) return rank;
        final near = a.distanceMeters.compareTo(b.distanceMeters);
        if (near != 0) return near;
        return a.name.compareTo(b.name);
      });
    return results.take(limit).toList();
  }
}

String foldName(String value) {
  const accents = <String, String>{
    'ă': 'a',
    'â': 'a',
    'î': 'i',
    'ș': 's',
    'ş': 's',
    'ț': 't',
    'ţ': 't',
    'á': 'a',
    'à': 'a',
    'ä': 'a',
    'ã': 'a',
    'å': 'a',
    'é': 'e',
    'è': 'e',
    'ë': 'e',
    'ê': 'e',
    'í': 'i',
    'ì': 'i',
    'ï': 'i',
    'ó': 'o',
    'ò': 'o',
    'ö': 'o',
    'ô': 'o',
    'õ': 'o',
    'ú': 'u',
    'ù': 'u',
    'ü': 'u',
    'û': 'u',
    'ç': 'c',
    'ñ': 'n',
  };
  final lower = value.toLowerCase();
  final buffer = StringBuffer();
  for (final rune in lower.runes) {
    final char = String.fromCharCode(rune);
    buffer.write(accents[char] ?? char);
  }
  return buffer.toString().replaceAll(RegExp(r'[\u0300-\u036f]'), '');
}

double distanceMeters(
  double latitudeA,
  double longitudeA,
  double latitudeB,
  double longitudeB,
) {
  const radius = 6371000.0;
  final lat1 = latitudeA * math.pi / 180;
  final lat2 = latitudeB * math.pi / 180;
  final dLat = (latitudeB - latitudeA) * math.pi / 180;
  final dLon = (longitudeB - longitudeA) * math.pi / 180;
  final a =
      math.pow(math.sin(dLat / 2), 2) +
      math.cos(lat1) * math.cos(lat2) * math.pow(math.sin(dLon / 2), 2);
  return 2 * radius * math.asin(math.min(1, math.sqrt(a)));
}
