import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { createHash } from 'node:crypto';
import { buildSearchIndex, bucegiBounds, searchIndexVersion } from './build-search-index.mjs';

const root = fileURLToPath(new URL('../', import.meta.url));
const sample = resolve(root, 'samples/bucegi');
const output = resolve(root, 'map-tools/.cache');
await mkdir(output, { recursive: true });
const sourceMeta = JSON.parse(await readFile(resolve(root, 'map-tools/source/metadata.json'), 'utf8'));
const { count, sourceSha256: sourceHash } = await buildSearchIndex({ expectedSha256: sourceMeta.sha256 });
if (count < 5) throw new Error('Search index unexpectedly sparse');

const sourceManifest = JSON.parse(await readFile(resolve(sample, 'manifest.json'), 'utf8'));
const mapAttribution = '© OpenStreetMap contributors · ODbL 1.0';
const terrainAttribution = 'Derived elevation tiles from Copernicus WorldDEM-30; © DLR e.V. 2010–2014 and © Airbus Defence and Space GmbH 2014–2018, provided under COPERNICUS by the European Union and ESA; all rights reserved.';
const files = {};
for (const name of ['map.pmtiles', 'terrain.pmtiles', 'search.sqlite']) {
  const data = await readFile(resolve(sample, name));
  files[name] = { bytes: data.length, sha256: createHash('sha256').update(data).digest('hex') };
}
const metadata = {
  formatVersion: 1, id: 'bucegi', name: 'Bucegi Mountains hiking and terrain sample',
  bounds: bucegiBounds, mapDetail: 'detailed (z14)', terrainResolution: 'GLO-30, z12 DEM',
  searchIndexVersion,
  vectorSchema: 'ridgewalk-hiking-v1', terrainEncoding: 'mapbox',
  mapAttribution,
  terrainAttribution,
  attribution: `${mapAttribution}; ${terrainAttribution}`,
  licenses: { map: 'ODbL 1.0', terrain: 'Copernicus DEM GLO-30 public license',
    search: 'ODbL 1.0' },
  datasetVersions: { osm: sourceMeta.downloadedAt, osmSha256: sourceHash,
    dem: sourceManifest.sourceType, demSha256: sourceManifest.sourceSha256,
    vectorSchema: 'ridgewalk-hiking-v1', searchIndex: String(searchIndexVersion) },
  files,
};
await writeFile(resolve(sample, 'package.json'), `${JSON.stringify(metadata, null, 2)}\n`);

// Store ZIP entries without recompressing PMTiles and SQLite. This keeps memory bounded
// to the already small development sample and produces deterministic entry order.
const entries = [
  ['package.json', await readFile(resolve(sample, 'package.json'))],
  ...await Promise.all(Object.keys(files).map(async (name) => [name, await readFile(resolve(sample, name))])),
];
const crcTable = Uint32Array.from({ length: 256 }, (_, index) => {
  let value = index;
  for (let i = 0; i < 8; i++) value = value & 1 ? 0xedb88320 ^ (value >>> 1) : value >>> 1;
  return value >>> 0;
});
function crc32(data) {
  let value = 0xffffffff;
  for (const byte of data) value = crcTable[(value ^ byte) & 255] ^ (value >>> 8);
  return (value ^ 0xffffffff) >>> 0;
}
const chunks = [], directory = [];
let position = 0;
for (const [name, data] of entries) {
  const filename = Buffer.from(name);
  const crc = crc32(data);
  const local = Buffer.alloc(30 + filename.length);
  local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4);
  local.writeUInt32LE(crc, 14); local.writeUInt32LE(data.length, 18);
  local.writeUInt32LE(data.length, 22); local.writeUInt16LE(filename.length, 26);
  filename.copy(local, 30);
  chunks.push(local, data);
  const central = Buffer.alloc(46 + filename.length);
  central.writeUInt32LE(0x02014b50, 0); central.writeUInt16LE(20, 4);
  central.writeUInt16LE(20, 6); central.writeUInt32LE(crc, 16);
  central.writeUInt32LE(data.length, 20); central.writeUInt32LE(data.length, 24);
  central.writeUInt16LE(filename.length, 28); central.writeUInt32LE(position, 42);
  filename.copy(central, 46);
  directory.push(central);
  position += local.length + data.length;
}
const centralOffset = position;
const centralSize = directory.reduce((sum, chunk) => sum + chunk.length, 0);
const end = Buffer.alloc(22);
end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(entries.length, 8);
end.writeUInt16LE(entries.length, 10); end.writeUInt32LE(centralSize, 12);
end.writeUInt32LE(centralOffset, 16);
const archive = Buffer.concat([...chunks, ...directory, end]);
const archivePath = resolve(output, 'bucegi.rwpkg');
await writeFile(archivePath, archive);
const packageHash = createHash('sha256').update(archive).digest('hex');
const catalog = { catalogVersion: 1, packages: [{
  package: metadata,
  url: 'https://OWNER.example/regions/bucegi.rwpkg',
  bytes: archive.length,
  sha256: packageHash,
}] };
await writeFile(resolve(output, 'catalog.json'), `${JSON.stringify(catalog, null, 2)}\n`);
console.log(`Indexed ${count} named OSM features; wrote ${archivePath} (${archive.length} bytes, SHA-256 ${packageHash})`);
