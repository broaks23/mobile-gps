import { createHash } from 'node:crypto';
import { readFile, mkdir, writeFile } from 'node:fs/promises';
import { spawnSync } from 'node:child_process';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { fromFile } from 'geotiff';
import { PNG } from 'pngjs';
import initSqlJs from 'sql.js';
import { attribution, sampleBounds, sourceName, sourceSha256, sourceUrl } from './source.mjs';

const root = fileURLToPath(new URL('./', import.meta.url));
const sourcePath = resolve(root, '.cache', sourceName);
const output = resolve(root, '../samples/bucegi');
const temporary = resolve(root, 'tmp');
const mbtilesPath = resolve(temporary, 'bucegi-terrain.mbtiles');
const archivePath = resolve(output, 'terrain.pmtiles');
const pmtiles = process.env.PMTILES_BIN || 'pmtiles';
const size = 256;
const minZoom = 10;
const maxZoom = 12;

const file = await readFile(sourcePath).catch(() => {
  throw new Error('Source GeoTIFF missing. Run npm run download:bucegi first.');
});
const actualHash = createHash('sha256').update(file).digest('hex');
if (actualHash !== sourceSha256) throw new Error(`Unexpected source SHA-256: ${actualHash}`);
const tiff = await fromFile(sourcePath);
const image = await tiff.getImage();
const bounds = image.getBoundingBox();
if (image.getWidth() !== 3600 || image.getHeight() !== 3600 ||
    bounds.join(',') !== '25,45,26,46' || image.getSamplesPerPixel() !== 1) {
  throw new Error('Source GeoTIFF geometry or band count changed');
}
const elevations = await image.readRasters({ samples: [0], interleave: true });
if (!(elevations instanceof Float32Array) || elevations.length !== 3600 * 3600) {
  throw new Error('Source DEM is not the expected Float32 raster');
}

const SQL = await initSqlJs({ locateFile: (name) => resolve(root, 'node_modules/sql.js/dist', name) });
const db = new SQL.Database();
db.run('CREATE TABLE metadata (name TEXT PRIMARY KEY, value TEXT)');
db.run('CREATE TABLE tiles (zoom_level INTEGER, tile_column INTEGER, tile_row INTEGER, tile_data BLOB, PRIMARY KEY (zoom_level, tile_column, tile_row))');
const metadata = {
  name: 'Bucegi Mountains terrain sample',
  type: 'baselayer',
  version: '1',
  format: 'png',
  minzoom: String(minZoom),
  maxzoom: String(maxZoom),
  bounds: sampleBounds.join(','),
  center: `${(sampleBounds[0] + sampleBounds[2]) / 2},${(sampleBounds[1] + sampleBounds[3]) / 2},11`,
  attribution,
};
const insertMetadata = db.prepare('INSERT INTO metadata (name, value) VALUES (?, ?)');
for (const [name, value] of Object.entries(metadata)) insertMetadata.run([name, value]);
insertMetadata.free();

const toX = (longitude, zoom) => Math.floor((longitude + 180) / 360 * 2 ** zoom);
const toY = (latitude, zoom) => Math.floor((1 - Math.asinh(Math.tan(latitude * Math.PI / 180)) / Math.PI) / 2 * 2 ** zoom);
const longitudeAt = (x, zoom) => x / 2 ** zoom * 360 - 180;
const latitudeAt = (y, zoom) => Math.atan(Math.sinh(Math.PI * (1 - 2 * y / 2 ** zoom))) * 180 / Math.PI;

function heightAt(longitude, latitude) {
  const px = Math.min(3599, Math.max(0, (longitude - 25) * 3600 - 0.5));
  const py = Math.min(3599, Math.max(0, (46 - latitude) * 3600 - 0.5));
  const x0 = Math.floor(px), y0 = Math.floor(py);
  const x1 = Math.min(3599, x0 + 1), y1 = Math.min(3599, y0 + 1);
  const fx = px - x0, fy = py - y0;
  const top = elevations[y0 * 3600 + x0] * (1 - fx) + elevations[y0 * 3600 + x1] * fx;
  const bottom = elevations[y1 * 3600 + x0] * (1 - fx) + elevations[y1 * 3600 + x1] * fx;
  return top * (1 - fy) + bottom * fy;
}

let tileCount = 0;
let minimum = Infinity;
let maximum = -Infinity;
db.run('BEGIN TRANSACTION');
const insertTile = db.prepare('INSERT INTO tiles (zoom_level, tile_column, tile_row, tile_data) VALUES (?, ?, ?, ?)');
for (let zoom = minZoom; zoom <= maxZoom; zoom++) {
  const x0 = toX(sampleBounds[0], zoom) - 1;
  const x1 = toX(sampleBounds[2], zoom) + 1;
  const y0 = toY(sampleBounds[3], zoom) - 1;
  const y1 = toY(sampleBounds[1], zoom) + 1;
  for (let x = x0; x <= x1; x++) {
    for (let y = y0; y <= y1; y++) {
      // Buffer tiles prevent terrain skirts at the sample viewport edge.
      // Pixels beyond the single source geocell are clamped to its border.
      const png = new PNG({ width: size, height: size, colorType: 6 });
      for (let row = 0; row < size; row++) {
        const latitude = latitudeAt(y + (row + 0.5) / size, zoom);
        for (let col = 0; col < size; col++) {
          const longitude = longitudeAt(x + (col + 0.5) / size, zoom);
          const height = heightAt(longitude, latitude);
          if (!Number.isFinite(height)) throw new Error(`Non-finite DEM value in ${zoom}/${x}/${y}`);
          minimum = Math.min(minimum, height);
          maximum = Math.max(maximum, height);
          // Mapbox Terrain-RGB: height in metres = -10000 + (R*65536 + G*256 + B)*0.1.
          const encoded = Math.round((height + 10000) * 10);
          const offset = (row * size + col) * 4;
          png.data[offset] = (encoded >> 16) & 255;
          png.data[offset + 1] = (encoded >> 8) & 255;
          png.data[offset + 2] = encoded & 255;
          png.data[offset + 3] = 255;
        }
      }
      const bytes = PNG.sync.write(png);
      insertTile.run([zoom, x, 2 ** zoom - 1 - y, bytes]);
      tileCount++;
    }
  }
}
insertTile.free();
db.run('COMMIT');
if (tileCount < 20 || maximum - minimum < 500 || maximum > 4000 || minimum < 0) {
  throw new Error(`Unexpected sample DEM statistics: ${tileCount} tiles, ${minimum}..${maximum} m`);
}
await mkdir(temporary, { recursive: true });
await mkdir(output, { recursive: true });
await writeFile(mbtilesPath, Buffer.from(db.export()));
db.close();
const conversion = spawnSync(pmtiles, ['convert', mbtilesPath, archivePath], { encoding: 'utf8' });
if (conversion.error) throw conversion.error;
if (conversion.status !== 0) throw new Error(`pmtiles convert failed: ${conversion.stderr || conversion.stdout}`);

const manifestPath = resolve(output, 'manifest.json');
let existing = {};
try { existing = JSON.parse(await readFile(manifestPath, 'utf8')); } catch (error) {
  if (error.code !== 'ENOENT') throw error;
}
const manifest = {
  ...existing,
  name: existing.mapSource ? 'Bucegi Mountains hiking and terrain sample' : 'Bucegi Mountains terrain sample',
  bounds: existing.mapSource ? existing.bounds : sampleBounds,
  terrainBounds: sampleBounds,
  terrainEncoding: 'mapbox',
  attribution,
  terrainAttribution: attribution,
  source: sourceUrl,
  sourceSha256,
  sourceResolution: '1 arc-second (~30 m at equator)',
  sourceType: 'Copernicus DEM GLO-30 Public digital surface model',
};
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
const archiveHash = createHash('sha256').update(await readFile(archivePath)).digest('hex');
console.log(`Generated ${tileCount} Terrain-RGB PNG tiles; heights ${minimum.toFixed(1)}–${maximum.toFixed(1)} m`);
console.log(`Archive: ${archivePath}; SHA-256 ${archiveHash}`);

