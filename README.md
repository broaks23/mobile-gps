# Ridgewalk

Ridgewalk is a personal Android hiking map with offline regions, 3D terrain, OSM place search, and foreground GPS. It uses Flutter/Dart, Riverpod, MapLibre GL JS/TypeScript in a WebView, local PMTiles, raster DEM, SQLite FTS5, and a loopback HTTP server. The bundled Bucegi sample includes [OpenStreetMap](https://www.openstreetmap.org/copyright) data and [Copernicus DEM GLO-30](https://dataspace.copernicus.eu/explore-data/data-collections/copernicus-contributing-missions/collections-description/COP-DEM) elevation; its package metadata and license notices are included with the app.

## Quick start

Install Flutter 3.47.9 or a compatible stable version, Android SDK and build tools, JDK 17, Node.js 24, npm, and PowerShell. Run `flutter doctor -v` and accept the Android SDK licenses with `flutter doctor --android-licenses`.

From the repository root, create a clean local APK:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\publish-android-apk.ps1 -BuildOnly
```

The script cleans Flutter output, installs renderer dependencies, bundles the local map assets, runs `flutter analyze`, and builds `build/release/ridgewalk.apk` with a SHA-256 file beside it.

To publish a new GitHub release, first update `version` in `pubspec.yaml`. Create a fine-grained token for `broaks23/mobile-gps` with **Contents: read and write**, copy `.env.example` to `.env`, and put the token in `GITHUB_TOKEN`. Alternatively, set `GITHUB_TOKEN` in your shell. Then run:

```powershell
powershell.exe -ExecutionPolicy Bypass -File .\scripts\publish-android-apk.ps1 -Tag v0.4.1
```

The script builds locally, creates a draft GitHub release, uploads the APK and checksum, and publishes it as a prerelease. Add `-Stable` for a normal release. For a new tag, GitHub uses its default branch, or the existing remote ref supplied with `-TargetCommitish dev`; an existing tag keeps its target. The script never commits or pushes code. The APK is built from your local working tree, which may differ from that remote ref. GitHub may also require **Workflows: write** if the selected remote ref changes workflow files relative to the default branch.

The current Android release build uses the local debug signing key. A key different from the one used for an existing installation can require uninstalling the old app, which removes its stored regions. Keep the same key for updates and configure a private release key before distributing production builds.

Project convention: do not add automated tests or automatically commit or push code changes.
