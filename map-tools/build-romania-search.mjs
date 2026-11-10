import { createOSMStream } from 'osm-pbf-parser-node';
import { DatabaseSync } from 'node:sqlite';
import { rm, readFile } from 'node:fs/promises';
import { createReadStream } from 'node:fs';
import { createHash } from 'node:crypto';
import { resolve } from 'node:path';

const source = resolve(process.argv[2] || '.cache/romania/romania.osm.pbf');
const output = resolve(process.argv[3] || '.cache/romania/search.sqlite');
const sourceInfo = JSON.parse(await readFile(new URL('./romania-sources.json', import.meta.url), 'utf8'));
const hash = createHash('sha256');
for await (const chunk of createReadStream(source)) hash.update(chunk);
if (hash.digest('hex') !== sourceInfo.sources.osm.sha256) throw new Error('OSM source checksum does not match romania-sources.json');
await rm(output, { force: true });
const db = new DatabaseSync(output);
db.exec(`PRAGMA journal_mode=DELETE; PRAGMA synchronous=OFF;
  CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
  CREATE TABLE places (id INTEGER PRIMARY KEY, feature_id TEXT NOT NULL UNIQUE, name TEXT NOT NULL, category TEXT NOT NULL, longitude REAL NOT NULL, latitude REAL NOT NULL, elevation_m REAL, attributes_json TEXT NOT NULL);
  CREATE VIRTUAL TABLE place_fts USING fts5(name, category, content='places', content_rowid='id', tokenize='unicode61 remove_diacritics 2', prefix='2 3 4');
  PRAGMA user_version=2; BEGIN;`);
const insert = db.prepare('INSERT OR IGNORE INTO places(feature_id,name,category,longitude,latitude,elevation_m,attributes_json) VALUES (?,?,?,?,?,?,?)');
const category = t => {
  if (['city','town','village','hamlet','locality'].includes(t.place)) return t.place;
  if (t.natural === 'peak') return 'peak';
  if (t.natural === 'saddle') return 'saddle';
  if (t.mountain_pass === 'yes') return 'mountain_pass';
  if (t.natural === 'waterfall' || t.waterway === 'waterfall') return 'waterfall';
  if (t.natural === 'water' || ['lake','reservoir'].includes(t.water)) return 'lake';
  if (['river','stream'].includes(t.waterway)) return t.waterway;
  if (['alpine_hut','wilderness_hut'].includes(t.tourism)) return 'mountain_hut';
  if (t.amenity === 'shelter') return 'shelter';
  if (t.tourism === 'camp_site') return 'campsite';
  if (t.highway === 'trailhead' || t.information === 'guidepost') return 'trailhead';
  if (['hiking','foot'].includes(t.route)) return 'hiking_route';
  if (['path','footway','pedestrian','track'].includes(t.highway)) return 'hiking_trail';
  return t.place ? 'place' : (t.tourism || t.amenity || t.natural) ? 'point_of_interest' : null;
};
const add = (item, lon, lat) => {
  const t = item.tags || {}, name = (t.name || t['name:ro'] || '').trim(), kind = category(t);
  if (!name || !kind || !Number.isFinite(lon) || !Number.isFinite(lat)) return;
  const ele = Number.parseFloat(t.ele);
  insert.run(`${item.type}/${item.id}`, name, kind, lon, lat, Number.isFinite(ele) ? ele : null, JSON.stringify(t));
};
const ways = [], needed = new Set();
for await (const item of createOSMStream(source)) {
  if (item.type === 'node') add(item, item.lon, item.lat);
  else if (item.type === 'way' && item.refs?.length && (item.tags?.name || item.tags?.['name:ro']) && category(item.tags)) {
    const ref = item.refs[Math.floor(item.refs.length / 2)];
    needed.add(ref); ways.push({ item, ref });
  }
}
console.log(`Named nodes indexed; resolving ${ways.length} named ways`);
const coordinates = new Map();
for await (const item of createOSMStream(source, { withTags: false })) {
  if (item.type === 'node' && needed.has(item.id)) coordinates.set(item.id, [item.lon, item.lat]);
}
for (const { item, ref } of ways) { const p = coordinates.get(ref); if (p) add(item, ...p); }
db.prepare('INSERT INTO metadata VALUES (?,?)').run('search_index_version','2');
db.exec("INSERT INTO place_fts(place_fts) VALUES ('rebuild'); COMMIT;");
if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok') throw new Error('Invalid search index');
console.log(`Indexed ${db.prepare('SELECT count(*) AS n FROM places').get().n} places to ${output}`);
db.close();
