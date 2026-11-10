import 'dart:io';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';

import 'services/live_location.dart';

enum AltitudeSource { gps, terrain }

class LocationPanel extends StatelessWidget {
  const LocationPanel({
    super.key,
    required this.location,
    required this.altitudeSource,
    required this.onAltitudeSource,
    required this.terrainElevation,
    required this.terrainPending,
    required this.onStop,
    required this.onFollow,
  });
  final LiveLocationState location;
  final AltitudeSource altitudeSource;
  final ValueChanged<AltitudeSource> onAltitudeSource;
  final double? terrainElevation;
  final bool terrainPending;
  final VoidCallback onStop, onFollow;

  @override
  Widget build(BuildContext context) {
    final position = location.position;
    final altitude =
        position != null && position.hasAltitude && position.altitude.isFinite
        ? '${position.altitude.toStringAsFixed(0)} m'
        : 'Unavailable';
    final altitudeAccuracy =
        position != null &&
            position.hasAltitudeAccuracy &&
            position.altitudeAccuracy.isFinite &&
            position.altitudeAccuracy > 0
        ? ' ±${position.altitudeAccuracy.toStringAsFixed(0)} m'
        : '';
    final status = switch (location.phase) {
      LocationPhase.requesting => 'Requesting location permission…',
      LocationPhase.waiting => 'Waiting for a GPS fix…',
      LocationPhase.paused => 'Location paused while the app is away',
      LocationPhase.denied => 'Location permission denied',
      LocationPhase.deniedForever => 'Location permission blocked in settings',
      LocationPhase.serviceDisabled => 'Location services are turned off',
      LocationPhase.error => 'Location unavailable. Try again.',
      LocationPhase.active =>
        location.poorAccuracy ? 'Low GPS accuracy' : 'GPS active',
      LocationPhase.off => 'Location off',
    };
    return Card(
      child: SingleChildScrollView(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Flexible(
                    child: Text(
                      status,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    tooltip: 'Stop GPS',
                    onPressed: onStop,
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
              if (position != null) ...[
                Text(
                  '${position.latitude.toStringAsFixed(6)}, ${position.longitude.toStringAsFixed(6)}°',
                ),
                Text(
                  'Fix ${TimeOfDay.fromDateTime(position.timestamp.toLocal()).format(context)}',
                ),
                Text(
                  position.hasAccuracy &&
                          position.accuracy.isFinite &&
                          position.accuracy > 0
                      ? 'Accuracy ±${position.accuracy.toStringAsFixed(0)} m'
                      : 'Accuracy unavailable',
                ),
                if (location.reliableCourse != null)
                  Text(
                    'Course ${location.reliableCourse!.toStringAsFixed(0)}°',
                  ),
                const SizedBox(height: 4),
                SegmentedButton<AltitudeSource>(
                  segments: const [
                    ButtonSegment(
                      value: AltitudeSource.gps,
                      label: Text('GPS'),
                    ),
                    ButtonSegment(
                      value: AltitudeSource.terrain,
                      label: Text('DEM'),
                    ),
                  ],
                  selected: {altitudeSource},
                  onSelectionChanged: (value) => onAltitudeSource(value.first),
                ),
                const SizedBox(height: 4),
                Text(
                  altitudeSource == AltitudeSource.gps
                      ? '$altitude$altitudeAccuracy'
                      : terrainPending
                      ? 'Reading local DEM…'
                      : terrainElevation == null
                      ? 'No local DEM at this position'
                      : '${terrainElevation!.toStringAsFixed(0)} m (approximate)',
                ),
                Text(
                  altitudeSource == AltitudeSource.gps
                      ? (Platform.isAndroid
                            ? 'GPS datum may be ellipsoid or mean sea level; it depends on the device.'
                            : 'GPS altitude datum depends on the device.')
                      : 'DEM datum depends on the region. GPS uncertainty affects this estimate.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (location.follow && location.poorAccuracy)
                  Text(
                    'Follow waits for accuracy within 100 m.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                TextButton.icon(
                  onPressed: onFollow,
                  icon: Icon(
                    location.follow ? Icons.gps_fixed : Icons.gps_not_fixed,
                  ),
                  label: Text(
                    location.follow ? 'Stop following' : 'Follow location',
                  ),
                ),
              ],
              if (location.phase == LocationPhase.waiting)
                Text(
                  'A satellite fix may take several minutes; try an open view of the sky.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              if (location.phase == LocationPhase.deniedForever)
                TextButton(
                  onPressed: Geolocator.openAppSettings,
                  child: const Text('Open app settings'),
                ),
              if (location.phase == LocationPhase.serviceDisabled)
                TextButton(
                  onPressed: Geolocator.openLocationSettings,
                  child: const Text('Open location settings'),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
