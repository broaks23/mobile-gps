import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:geolocator/geolocator.dart';

enum LocationAccess { granted, denied, deniedForever, serviceDisabled }

enum LocationPhase {
  off,
  requesting,
  waiting,
  active,
  paused,
  denied,
  deniedForever,
  serviceDisabled,
  error,
}

abstract interface class LocationBackend {
  Future<LocationAccess> requestAccess();
  Stream<Position> positions();
}

class GeolocatorBackend implements LocationBackend {
  @override
  Future<LocationAccess> requestAccess() async {
    if (!await Geolocator.isLocationServiceEnabled()) {
      return LocationAccess.serviceDisabled;
    }
    var permission = await Geolocator.checkPermission();
    if (permission == LocationPermission.denied) {
      permission = await Geolocator.requestPermission();
    }
    return switch (permission) {
      LocationPermission.denied => LocationAccess.denied,
      LocationPermission.deniedForever => LocationAccess.deniedForever,
      LocationPermission.unableToDetermine => LocationAccess.denied,
      _ => LocationAccess.granted,
    };
  }

  @override
  Stream<Position> positions() {
    final LocationSettings settings = Platform.isAndroid
        ? AndroidSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
            intervalDuration: const Duration(seconds: 5),
            // Android LocationManager can obtain satellite fixes without Play Services.
            forceLocationManager: true,
          )
        : const LocationSettings(
            accuracy: LocationAccuracy.high,
            distanceFilter: 10,
          );
    return Geolocator.getPositionStream(locationSettings: settings);
  }
}

class LiveLocationState {
  const LiveLocationState({
    this.phase = LocationPhase.off,
    this.position,
    this.follow = false,
    this.error,
  });
  final LocationPhase phase;
  final Position? position;
  final bool follow;
  final String? error;

  bool get poorAccuracy =>
      position == null ||
      !position!.hasAccuracy ||
      !position!.accuracy.isFinite ||
      position!.accuracy <= 0 ||
      position!.accuracy > 100;
  bool get shouldFollow =>
      follow && phase == LocationPhase.active && !poorAccuracy;

  /// GPS course is meaningful only while moving and with measured bearing accuracy.
  double? get reliableCourse {
    final fix = position;
    if (fix == null ||
        poorAccuracy ||
        fix.accuracy > 50 ||
        !fix.hasSpeed ||
        !fix.speed.isFinite ||
        !fix.hasSpeedAccuracy ||
        !fix.speedAccuracy.isFinite ||
        fix.speedAccuracy < 0 ||
        fix.speed - fix.speedAccuracy < 1 ||
        !fix.hasHeading ||
        !fix.hasHeadingAccuracy ||
        !fix.headingAccuracy.isFinite ||
        fix.headingAccuracy <= 0 ||
        fix.headingAccuracy > 25 ||
        !fix.heading.isFinite ||
        fix.heading < 0 ||
        fix.heading >= 360) {
      return null;
    }
    return fix.heading;
  }
}

final locationBackendProvider = Provider<LocationBackend>(
  (ref) => GeolocatorBackend(),
);
final liveLocationProvider =
    NotifierProvider<LiveLocationController, LiveLocationState>(
      LiveLocationController.new,
    );

class LiveLocationController extends Notifier<LiveLocationState> {
  StreamSubscription<Position>? _subscription;
  bool _wanted = false;
  int _generation = 0;

  @override
  LiveLocationState build() {
    ref.onDispose(() {
      _generation++;
      unawaited(_subscription?.cancel());
    });
    return const LiveLocationState();
  }

  Future<void> start() async {
    _wanted = true;
    await _begin(follow: true);
  }

  Future<void> _begin({required bool follow}) async {
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (!_wanted || generation != _generation) return;
    state = LiveLocationState(
      phase: LocationPhase.requesting,
      position: state.position,
      follow: follow,
    );
    try {
      final backend = ref.read(locationBackendProvider);
      final access = await backend.requestAccess();
      if (!_wanted || generation != _generation) return;
      if (access != LocationAccess.granted) {
        _wanted = false;
        state = LiveLocationState(
          phase: switch (access) {
            LocationAccess.denied => LocationPhase.denied,
            LocationAccess.deniedForever => LocationPhase.deniedForever,
            LocationAccess.serviceDisabled => LocationPhase.serviceDisabled,
            LocationAccess.granted => LocationPhase.waiting,
          },
        );
        return;
      }
      state = LiveLocationState(
        phase: LocationPhase.waiting,
        position: state.position,
        follow: follow,
      );
      _subscription = backend.positions().listen(
        (position) {
          if (!_wanted || generation != _generation) return;
          if (!position.latitude.isFinite ||
              !position.longitude.isFinite ||
              position.latitude.abs() > 90 ||
              position.longitude.abs() > 180) {
            return;
          }
          if (DateTime.now().difference(position.timestamp).abs() >
              const Duration(minutes: 2)) {
            return;
          }
          state = LiveLocationState(
            phase: LocationPhase.active,
            position: position,
            follow: state.follow,
          );
        },
        onError: (Object error) {
          if (generation != _generation) return;
          _wanted = false;
          unawaited(_subscription?.cancel());
          _subscription = null;
          state = LiveLocationState(
            phase: LocationPhase.error,
            position: state.position,
            error: error.toString(),
          );
        },
        onDone: () {
          if (!_wanted || generation != _generation) return;
          _wanted = false;
          _subscription = null;
          state = LiveLocationState(
            phase: LocationPhase.error,
            position: state.position,
            error: 'Location updates stopped',
          );
        },
      );
    } catch (error) {
      if (generation != _generation) return;
      _wanted = false;
      state = LiveLocationState(
        phase: LocationPhase.error,
        error: error.toString(),
      );
    }
  }

  void setFollow(bool value) {
    state = LiveLocationState(
      phase: state.phase,
      position: state.position,
      follow: value,
      error: state.error,
    );
  }

  Future<void> stop() async {
    _wanted = false;
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (generation != _generation) return;
    state = const LiveLocationState();
  }

  Future<void> suspend() async {
    if (!_wanted) return;
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (generation != _generation) return;
    state = LiveLocationState(
      phase: LocationPhase.paused,
      position: state.position,
      follow: state.follow,
    );
  }

  Future<void> resume() async {
    if (_wanted && _subscription == null) await _begin(follow: state.follow);
  }
}
