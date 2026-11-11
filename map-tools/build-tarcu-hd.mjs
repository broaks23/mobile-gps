import { createReadStream, createWriteStream } from 'node:fs';
import { access, copyFile, mkdir, readFile, rm, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import { once } from 'node:events';
import { resolve } from 'node:path';
import { DatabaseSync } from 'node:sqlite';

// A compact high-detail sample in western Romania where Mapterhorn publishes
// actual z13-z16 terrain. No public tile endpoint is scraped.
const bounds = [22.68, 45.28, 22.89, 45.43];
const base = resolve(import.meta.dirname, '.cache/romania');
const dir = resolve(base, 'tarcu-hd');
const cli = process.env.PMTILES_BIN || (process.platform === 'win32'
  ? resolve(base, '../tools/pmtiles.exe') : 'pmtiles');
const bbox = bounds.join(',');
const sourceInfo = JSON.parse(await readFile(new URL('./romania-sources.json', import.meta.url), 'utf8')).sources;
const mapSource = resolve(base, 'shortbread/romania-pmtiles-shortbread/romania.pmtiles');
const lowSource = resolve(base, 'terrain-romania.pmtiles');
const searchSource = resolve(base, 'search.sqlite');
const mapWork = resolve(dir, 'map-source.pmtiles');
const map = resolve(dir, 'map.pmtiles');
const low = resolve(dir, 'terrain-low.pmtiles');
const high = resolve(dir, 'terrain-high.pmtiles');
const highStamp = resolve(dir, 'terrain-high-source.json');
const terrain = resolve(dir, 'terrain.pmtiles');
const search = resolve(dir, 'search.sqlite');
const output = resolve(dir, 'tarcu-hd.rwpkg');
const sourceUrl = 'https://download.mapterhorn.com/6-36-22.pmtiles';

function run(...args) {
  console.log('pmtiles', args.join(' '));
  const result = spawnSync(cli, args, { stdio: 'inherit' });
  if (result.error) throw result.error;
  if (result.status !== 0) throw new Error(`pmtiles exited with ${result.status}`);
}
async function hash(path) {
  const sha = createHash('sha256');
  let bytes = 0, crc = 0xffffffff;
  for await (const chunk of createReadStream(path)) {
    sha.update(chunk); bytes += chunk.length;
    for (const byte of chunk) crc = crcTable[(crc ^ byte) & 255] ^ (crc >>> 8);
  }
  return { bytes, sha256: sha.digest('hex'), crc: (crc ^ 0xffffffff) >>> 0 };
}
const crcTable = Uint32Array.from({ length: 256 }, (_, i) => {
  let n = i;
  for (let j = 0; j < 8; j++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1;
  return n >>> 0;
});
const quoted = path => `'${path.replaceAll("'", "''")}'`;
const exists = async path => access(path).then(() => true, () => false);

await mkdir(dir, { recursive: true });
for (const [path, expected] of [[mapSource, sourceInfo.shortbread.sha256],
  [lowSource, sourceInfo.terrain.sha256]]) {
  console.log(`Checking source ${path}`);
  if ((await hash(path)).sha256 !== expected) throw new Error(`Source checksum mismatch: ${path}`);
}
const urlList = await fetch('https://download.mapterhorn.com/download_urls.json').then(r => {
  if (!r.ok) throw new Error(`Mapterhorn catalog HTTP ${r.status}`);
  return r.json();
});
const upper = urlList.items.find(item => item.url === sourceUrl);
if (!upper || upper.max_zoom < 16) throw new Error('High-resolution terrain source is unavailable');
if (await exists(high)) {
  if (!await exists(highStamp)) {
    throw new Error('Cached high-resolution extract has no source stamp; remove it and rebuild');
  }
  const stamp = JSON.parse(await readFile(highStamp, 'utf8'));
  if (stamp.sourceMd5 !== upper.md5sum || stamp.sourceUrl !== sourceUrl || stamp.bbox !== bbox) {
    throw new Error('Mapterhorn high-resolution source changed; remove cached high and merged terrain');
  }
}

if (!await exists(map)) {
  await copyFile(mapSource, mapWork);
  run('cluster', '--quiet', mapWork);
  run('extract', '--quiet', `--bbox=${bbox}`, mapWork, map);
  await rm(mapWork);
}
if (!await exists(low)) run('extract', '--quiet', `--bbox=${bbox}`, lowSource, low);
if (!await exists(high)) {
  run('extract', '--quiet', `--bbox=${bbox}`, sourceUrl, high);
  await writeFile(highStamp, JSON.stringify({ sourceUrl, sourceMd5: upper.md5sum, bbox }, null, 2) + '\n');
}
if (!await exists(terrain)) run('merge', '--quiet', low, high, terrain);
run('verify', '--quiet', map);
run('verify', '--quiet', terrain);

await rm(search, { force: true });
const db = new DatabaseSync(search);
try {
  db.exec(`ATTACH DATABASE ${quoted(searchSource)} AS source;
    PRAGMA user_version=2;
    CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
    CREATE TABLE places (id INTEGER PRIMARY KEY, feature_id TEXT NOT NULL UNIQUE,
      name TEXT NOT NULL, category TEXT NOT NULL, longitude REAL NOT NULL,
      latitude REAL NOT NULL, elevation_m REAL, attributes_json TEXT NOT NULL);
    CREATE VIRTUAL TABLE place_fts USING fts5(name, category, content='places',
      content_rowid='id', tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
    BEGIN;`);
  db.prepare(`INSERT INTO places(feature_id,name,category,longitude,latitude,elevation_m,attributes_json)
    SELECT feature_id,name,category,longitude,latitude,elevation_m,attributes_json
    FROM source.places WHERE longitude BETWEEN ? AND ? AND latitude BETWEEN ? AND ?`)
    .run(bounds[0], bounds[2], bounds[1], bounds[3]);
  db.prepare('INSERT INTO metadata VALUES (?,?)').run('search_index_version', '2');
  db.exec("INSERT INTO place_fts(place_fts) VALUES ('rebuild'); COMMIT;");
  if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok')
    throw new Error('Search index failed integrity check');
  console.log(`Indexed ${db.prepare('SELECT count(*) AS n FROM places').get().n} local places`);
} finally { db.close(); }

const paths = { 'map.pmtiles': map, 'terrain.pmtiles': terrain, 'search.sqlite': search };
const info = {};
for (const [name, path] of Object.entries(paths)) info[name] = await hash(path);
const metadata = {
  formatVersion: 1, id: 'tarcu-hd', name: 'Țarcu Mountains HD', bounds,
  mapDetail: 'OSM Shortbread z14', terrainResolution: 'Mapterhorn z16 (mixed native resolution)',
  terrainEncoding: 'terrarium', terrainTileSize: 512, vectorSchema: 'shortbread-1.0',
  searchIndexVersion: 2,
  mapAttribution: '© OpenStreetMap contributors · ODbL 1.0',
  terrainAttribution: '© Mapterhorn; © ANCPI LAKI II and Copernicus DEM where sourced; mapterhorn.com/attribution',
  licenses: { map: 'ODbL 1.0', search: 'ODbL 1.0',
    terrain: 'Mapterhorn source licenses: https://mapterhorn.com/attribution/; ANCPI OGL-ROU-1.0' },
  datasetVersions: { osm: sourceInfo.osm.sha256, vector: 'BBBike Shortbread 2026-11-09',
    dem: `Mapterhorn ${urlList.version} / 6-36-22.pmtiles ${upper.md5sum}`, searchIndex: '2' },
  files: Object.fromEntries(Object.entries(info).map(([name, item]) =>
    [name, { bytes: item.bytes, sha256: item.sha256 }])),
};
await writeFile(resolve(dir, 'package.json'), JSON.stringify(metadata, null, 2) + '\n');
paths['package.json'] = resolve(dir, 'package.json');
info['package.json'] = await hash(paths['package.json']);
const names = ['package.json', 'map.pmtiles', 'terrain.pmtiles', 'search.sqlite'];
if (names.reduce((sum, name) => sum + info[name].bytes + 200, 0) >= 0xffffffff)
  throw new Error('Package exceeds classic ZIP limit; split the region');
const out = createWriteStream(output);
let offset = 0;
const central = [];
async function emit(chunk) { offset += chunk.length; if (!out.write(chunk)) await once(out, 'drain'); }
for (const name of names) {
  const filename = Buffer.from(name), start = offset;
  const { bytes, crc } = info[name];
  const header = Buffer.alloc(30 + filename.length);
  header.writeUInt32LE(0x04034b50, 0); header.writeUInt16LE(20, 4);
  header.writeUInt32LE(crc, 14); header.writeUInt32LE(bytes, 18);
  header.writeUInt32LE(bytes, 22); header.writeUInt16LE(filename.length, 26);
  filename.copy(header, 30); await emit(header);
  for await (const chunk of createReadStream(paths[name])) await emit(chunk);
  const entry = Buffer.alloc(46 + filename.length);
  entry.writeUInt32LE(0x02014b50, 0); entry.writeUInt16LE(20, 4);
  entry.writeUInt16LE(20, 6); entry.writeUInt32LE(crc, 16);
  entry.writeUInt32LE(bytes, 20); entry.writeUInt32LE(bytes, 24);
  entry.writeUInt16LE(filename.length, 28); entry.writeUInt32LE(start, 42);
  filename.copy(entry, 46); central.push(entry);
}
const directoryStart = offset;
for (const entry of central) await emit(entry);
const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50, 0);
end.writeUInt16LE(names.length, 8); end.writeUInt16LE(names.length, 10);
end.writeUInt32LE(offset - directoryStart, 12); end.writeUInt32LE(directoryStart, 16);
await emit(end); out.end(); await once(out, 'finish');
const archive = await hash(output);
await writeFile(resolve(dir, 'catalog-entry.json'),
  JSON.stringify({ package: metadata, bytes: archive.bytes, sha256: archive.sha256 }, null, 2) + '\n');
console.log(`Prepared ${output}: ${archive.bytes} bytes SHA-256 ${archive.sha256}`);
