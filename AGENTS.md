# Project conventions

- Keep the Flutter app at the repository root and the independent TypeScript map package in `renderer/`.
- Use Riverpod for Flutter application state. Keep platform permissions, location, storage, and local HTTP service in Dart; keep camera rendering and map style in TypeScript.
- Never add runtime CDN URLs, API keys, telemetry, accounts, or remote tile fallbacks. A missing offline region must be shown explicitly.
- Bundle every renderer runtime dependency with `cd renderer && npm run bundle:app`; commit the resulting `assets/renderer/` files and relevant license notices.
- Keep the local server bound to `127.0.0.1`, use a random path token, validate file paths, and preserve byte range support for PMTiles.
- Any new map data source must document its tile schema, DEM encoding, attribution, license, and offline packaging. Do not silently mix incompatible vector tile schemas.
- Treat region installation and deletion as atomic operations. Verify file integrity before exposing a region to the renderer.
- Add tests for behavior with real failure modes, especially HTTP range parsing and path access. Avoid tests that merely repeat implementation details.
- Before changing Android or iOS platform settings, check current Flutter and plugin requirements. Run `flutter analyze`, `flutter test`, and an Android build when the toolchains are available; report any checks that could not run.
