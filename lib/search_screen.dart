import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'services/offline_search.dart';
import 'services/region_packages.dart';

final offlineSearchProvider = FutureProvider<OfflineSearch>((ref) async {
  return OfflineSearch(await RegionStore.open());
});

String categoryLabel(String category) => switch (category) {
  'city' => 'City',
  'town' => 'Town',
  'village' => 'Village',
  'hamlet' => 'Hamlet',
  'locality' => 'Locality',
  'peak' => 'Peak',
  'saddle' => 'Saddle',
  'mountain_pass' => 'Mountain pass',
  'mountain_hut' => 'Mountain hut',
  'shelter' => 'Shelter',
  'campsite' || 'camp_site' => 'Campsite',
  'lake' => 'Lake',
  'river' => 'River',
  'stream' => 'Stream',
  'waterfall' => 'Waterfall',
  'trailhead' => 'Trailhead',
  'hiking_trail' || 'trail' => 'Hiking trail',
  'hiking_route' => 'Hiking route',
  'coordinates' => 'Coordinates',
  _ => 'Place',
};

String approximateDistance(double meters) => meters < 1000
    ? '${(meters / 100).round() * 100} m'
    : '${(meters / 1000).toStringAsFixed(meters < 10000 ? 1 : 0)} km';

class SearchScreen extends ConsumerStatefulWidget {
  const SearchScreen({
    super.key,
    required this.nearLatitude,
    required this.nearLongitude,
  });
  final double nearLatitude, nearLongitude;

  @override
  ConsumerState<SearchScreen> createState() => _SearchScreenState();
}

class _SearchScreenState extends ConsumerState<SearchScreen> {
  final _input = TextEditingController();
  Timer? _debounce;
  int _generation = 0;
  List<SearchResult> _results = [];
  String? _error;
  bool _busy = false;
  bool _queried = false;

  @override
  void initState() {
    super.initState();
    _input.addListener(() {
      _debounce?.cancel();
      _debounce = Timer(const Duration(milliseconds: 180), _search);
    });
  }

  Future<void> _search() async {
    final generation = ++_generation;
    final query = _input.text.trim();
    if (query.isEmpty) {
      setState(() {
        _results = [];
        _error = null;
        _busy = false;
        _queried = false;
      });
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _queried = true;
    });
    try {
      final service = await ref.read(offlineSearchProvider.future);
      final results = await service.search(
        query,
        nearLatitude: widget.nearLatitude,
        nearLongitude: widget.nearLongitude,
      );
      if (mounted && generation == _generation) {
        setState(() {
          _results = results;
          _busy = false;
        });
      }
    } catch (error) {
      if (mounted && generation == _generation) {
        setState(() {
          _error = '$error';
          _busy = false;
        });
      }
    }
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _input.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Offline search')),
    body: Column(
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: TextField(
            controller: _input,
            autofocus: true,
            textInputAction: TextInputAction.search,
            decoration: InputDecoration(
              prefixIcon: const Icon(Icons.search),
              hintText: 'Peak, hut, trail, or 45.41, 25.47',
              border: const OutlineInputBorder(),
              suffixIcon: _input.text.isEmpty
                  ? null
                  : IconButton(
                      tooltip: 'Clear search',
                      onPressed: _input.clear,
                      icon: const Icon(Icons.clear),
                    ),
            ),
          ),
        ),
        if (_busy) const LinearProgressIndicator(),
        if (_error != null)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'Search unavailable: $_error',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (!_queried)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'Search installed regions only. Distances are from the map center. '
              'Enter latitude, longitude to jump to coordinates.',
            ),
          ),
        if (_queried && !_busy && _results.isEmpty && _error == null)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('No matching place in installed regions.'),
          ),
        Expanded(
          child: ListView.builder(
            itemCount: _results.length,
            itemBuilder: (context, index) {
              final result = _results[index];
              return ListTile(
                leading: Icon(
                  result.category == 'coordinates'
                      ? Icons.pin_drop
                      : result.category.contains('trail') ||
                            result.category == 'hiking_route'
                      ? Icons.route
                      : Icons.place_outlined,
                ),
                title: Text(result.name),
                subtitle: Text(
                  '${categoryLabel(result.category)} · '
                  '${approximateDistance(result.distanceMeters)} from map center',
                ),
                onTap: () => Navigator.of(context).pop(result),
              );
            },
          ),
        ),
      ],
    ),
  );
}
