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
powershell.exe -ExecutionPolicy Bypass -File .\scripts\publish-android-apk.ps1 -Tag v0.5.0
```

The script builds locally, creates a draft GitHub release, uploads the APK and checksum, and publishes it as a normal release. The tag must match the version in `pubspec.yaml`, for example `version: 0.5.0+2` and `-Tag v0.5.0`. Increase both the version and the number after `+` for each update so Android accepts it. For a new tag, GitHub uses its default branch, or the existing remote ref supplied with `-TargetCommitish dev`; an existing tag keeps its target. The script never commits or pushes code. The APK is built from your local working tree, which may differ from that remote ref. GitHub may also require **Workflows: write** if the selected remote ref changes workflow files relative to the default branch.

The current Android release build uses the local debug signing key. A key different from the one used for an existing installation can require uninstalling the old app, which removes its stored regions. Keep the same key for updates and configure a private release key before distributing production builds.

In Offline regions, **Check for updates** checks the latest normal GitHub release when online. **Install update** downloads the APK and verifies its checksum and signing key, then opens Android's installer; Android may first ask you to allow Ridgewalk to install apps and will require confirmation. The existing 0.4.1 installation needs this version installed manually once before it can check for future updates. These are full APK updates; installed regions remain in place when Android accepts an update signed with the same key.

Project convention: do not add automated tests or automatically commit or push code changes.

## Romania map and LAN downloads

The prepared Romania package is `map-tools/.cache/romania/romania.rwpkg` (about 1.21 GB). It requires an APK built from the current code. Keep at least 2.5 GB free on the phone for downloading and installation. The package contains a z14 Shortbread OSM basemap, 30 m Mapterhorn terrain, and an offline OSM search index. Peaks and passes come from the search index; the Shortbread map does not retain SAC difficulty or hiking-route markings. The downloaded satellite mosaic is not included or supported as a map layer.

To serve the package from a computer on the same Wi-Fi network, run from the repository root:

```powershell
node .\lan-server\server.mjs
```

Open Regions in the updated app, enter the printed `http://<computer-private-IP>:8765/catalog.json` address, load the catalog, and download Romania. Select the installed region after installation. Allow Node through the computer's firewall for private networks if necessary. HTTP is unencrypted: use a trusted LAN; checksums detect corruption but do not authenticate a malicious server or network. Close the server with Ctrl+C. For another prepared package, use `node .\lan-server\server.mjs --package <path-to-rwpkg> --entry <path-to-catalog-entry.json>`; the sidecar contains package metadata, archive size, and SHA-256.

The large data files are ignored by Git. To rebuild the Romania package from the downloaded source files listed in `map-tools/romania-sources.json`, use Node.js 24 and run:

```powershell
cd map-tools
npm.cmd ci
node build-romania-search.mjs
node package-romania.mjs
cd ..
```

The OSM data requires attribution and is subject to the [ODbL](https://www.openstreetmap.org/copyright); terrain source credits and license details are in the package metadata and [Mapterhorn's attribution](https://mapterhorn.com/attribution/). See `map-tools/romania-sources.json` for the source provenance and checksums.
