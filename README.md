# Ridgewalk

An offline-first Android hiking map foundation built with Flutter and a locally bundled MapLibre GL JS renderer. The first launch shows an empty map until an offline region is installed. The current milestone establishes the local rendering pipeline, not a region downloader or search database.

## Development prerequisites

- Flutter SDK with Dart 3.9 or newer
- Android SDK with a platform and build tools supported by the selected Flutter release
- JDK 17 or 21 for the Android Gradle build
- Node.js 20.19+ and npm

This repository includes the Android platform scaffold and Gradle wrapper. iOS platform files will be generated on macOS when iOS support is implemented.

## Build

```sh
cd renderer
npm ci
npm run bundle:app
cd ..
flutter pub get
flutter analyze
flutter test
flutter run
```

`npm run bundle:app` writes every renderer runtime asset into `assets/renderer/`. Flutter packages that directory into the app. The renderer does not request a CDN at runtime. A normal build uses the checked-in bundle, so npm is not required on a user's device.

## Offline region package contract

The resource server reads directories under the app support directory's `regions/` folder. A region ID uses lowercase letters, digits, `_`, or `-` (maximum 64 characters):

```text
regions/
  bucegi/
    manifest.json
    map.pmtiles
    terrain.pmtiles     # optional; needed for true 3D terrain
```

Example `manifest.json`:

```json
{
  "name": "Bucegi Mountains",
  "bounds": [25.25, 45.32, 25.62, 45.55],
  "terrainEncoding": "mapbox",
  "attribution": "© OpenStreetMap contributors; elevation data: add provider attribution"
}
```

`map.pmtiles` must contain Mapbox Vector Tiles in the documented OpenMapTiles layer schema used by `renderer/src/main.ts`: `landcover`, `landuse`, `water`, `transportation`, `transportation_name`, `poi`, `mountain_peak`, and `place`. `terrain.pmtiles` must contain raster DEM PNG tiles encoded as Mapbox Terrain RGB (`mapbox`) or Terrarium RGB (`terrarium`). The terrain source drives `map.setTerrain`, which renders an elevation mesh. The two archives must cover compatible bounds and zoom levels. Only installed local archives are exposed to the renderer.

There is no in-app importer in this milestone. During development, place a prepared region in the app support directory by debug tooling, then restart the app. Region acquisition, integrity checks, storage accounting, deletion, and licensing workflows are future work. Do not assume arbitrary PMTiles files follow the required layer schema or DEM encoding.

## Current status

The renderer TypeScript check and production bundle complete in the available environment. Flutter, Dart, and Android SDK were not installed there, so `flutter pub get`, `flutter analyze`, `flutter test`, Android assembly, and device behavior could not be run. The bundled renderer has no included map or DEM data. See [ARCHITECTURE.md](ARCHITECTURE.md) for components and remaining work.

