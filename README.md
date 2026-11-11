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
powershell.exe -ExecutionPolicy Bypass -File .\scripts\publish-android-apk.ps1 -Tag v0.5.1
```

The script builds locally, creates a draft GitHub release, uploads the APK and checksum, and publishes it as a normal release. The tag must match the version in `pubspec.yaml`, for example `version: 0.5.1+3` and `-Tag v0.5.1`. Increase both the version and the number after `+` for each update so Android accepts it. For a new tag, GitHub uses its default branch, or the existing remote ref supplied with `-TargetCommitish dev`; an existing tag keeps its target. The script never commits or pushes code. The APK is built from your local working tree, which may differ from that remote ref. GitHub may also require **Workflows: write** if the selected remote ref changes workflow files relative to the default branch.

The release build uses `C:\Users\User\.android\debug.keystore`. Back up this file securely: the publish script pins its SHA-256 certificate (`dd2701d37ff47e856d5c09c97412dc215e3b7455b1835f8b14bd917c1d0d43a9`) so later releases use the same key. The old v0.5.0 APK had a different signer. Uninstall that app once before installing v0.5.1; uninstalling removes its stored regions, which must then be downloaded again.

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

### Higher-detail Țarcu Mountains package

`map-tools/.cache/romania/tarcu-hd/tarcu-hd.rwpkg` is a prepared 325 MB package covering 22.68–22.89°E, 45.28–45.43°N. It has locally extracted OSM vector tiles to z14, 173 indexed places, and Mapterhorn Terrarium WebP terrain to z16 (512-pixel tiles). The high-zoom archive contains a tile at the package center. MapLibre renders the terrain as a 3D mesh; z16 is the tile zoom level and does **not** mean all underlying elevations have 0.5 m accuracy. Mapterhorn lists ANCPI's 0.5 m LAKI II among its Romanian sources, with mixed-source coverage; see [data access](https://mapterhorn.com/data-access/) and [source attribution](https://mapterhorn.com/attribution/). The Bucegi area has no Mapterhorn z13+ coverage, so the bundled Bucegi terrain remains lower resolution. The full Romania package remains the country-wide option.

To download this package to the phone over the LAN, from the repository root run:

```powershell
node .\lan-server\server.mjs --package .\map-tools\.cache\romania\tarcu-hd\tarcu-hd.rwpkg --entry .\map-tools\.cache\romania\tarcu-hd\catalog-entry.json
```

In **Offline regions**, enter the displayed catalog URL and download **Țarcu Mountains HD**, then select it in installed regions. It uses a separate region ID, so the existing Romania package remains installed. Allow about 700 MB free during download and installation; the installed region is about 325 MB. You can also import the `.rwpkg` file directly from phone storage. The files are local and ignored by Git.

To rebuild, install the official [PMTiles CLI](https://github.com/protomaps/go-pmtiles/releases), set `PMTILES_BIN` to its executable path (or put it on `PATH`), and ensure the Romania source files named in `map-tools/romania-sources.json` are present. Then run:

```powershell
cd map-tools
node build-tarcu-hd.mjs
```

The script checks the local source checksums, extracts from Mapterhorn's downloadable **archive** (not its public tile endpoint), merges base and high-zoom terrain, clips the local OSM vector archive, subsets the local SQLite search index, and writes a checksum-protected region package and LAN catalog entry. Cached intermediate PMTiles files in `map-tools/.cache/romania/tarcu-hd` are reused; remove individual intermediate files before rebuilding if you need to refresh a changed Mapterhorn dataset. Source data attribution and license details travel in `package.json` inside the package.
