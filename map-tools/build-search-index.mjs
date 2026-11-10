import { readFile, mkdir, rm } from 'node:fs/promises';
import { resolve, dirname } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { DatabaseSync } from 'node:sqlite';
import { XMLParser } from 'fast-xml-parser';

const root = fileURLToPath(new URL('../', import.meta.url));
const defaultSource = resolve(root, 'map-tools/source/bucegi.osm.gz');
const defaultOutput = resolve(root, 'samples/bucegi/search.sqlite');
export const bucegiBounds = [25.41, 45.36, 25.52, 45.45];
export const searchIndexVersion = 2;

const tagMap = (element) => Object.fromEntries((element.tag ?? []).map((tag) => [tag.k, tag.v]));
const attributeKeys = ['name:ro', 'name:en', 'ref', 'ele', 'highway', 'natural', 'mountain_pass',
  'waterway', 'water', 'tourism', 'amenity', 'place', 'information', 'sac_scale',
  'trail_visibility', 'surface', 'network', 'route', 'osmc:symbol', 'colour',
  'description', 'operator', 'opening_hours', 'website'];

function category(t) {
  if (['city', 'town', 'village', 'hamlet', 'locality'].includes(t.place)) return t.place;
  if (t.natural === 'peak') return 'peak';
  if (t.natural === 'saddle') return 'saddle';
  if (t.mountain_pass === 'yes') return 'mountain_pass';
  if (t.natural === 'waterfall' || t.waterway === 'waterfall') return 'waterfall';
  if (t.natural === 'water' || ['lake', 'reservoir'].includes(t.water)) return 'lake';
  if (['river', 'stream'].includes(t.waterway)) return t.waterway;
  if (['alpine_hut', 'wilderness_hut'].includes(t.tourism)) return 'mountain_hut';
  if (t.amenity === 'shelter') return 'shelter';
  if (t.tourism === 'camp_site') return 'campsite';
  if (t.highway === 'trailhead' || t.information === 'guidepost') return 'trailhead';
  if (['hiking', 'foot'].includes(t.route)) return 'hiking_route';
  if (['path', 'footway', 'pedestrian', 'track'].includes(t.highway)) return 'hiking_trail';
  if (t.place) return 'place';
  if (t.tourism || t.amenity || t.natural) return 'point_of_interest';
  return null;
}

export async function buildSearchIndex({ sourcePath = defaultSource, outputPath = defaultOutput,
  bounds = bucegiBounds, expectedSha256 } = {}) {
  const source = gunzipSync(await readFile(sourcePath));
  const sourceHash = createHash('sha256').update(source).digest('hex');
  if (expectedSha256 && sourceHash !== expectedSha256) throw new Error('OSM source checksum mismatch');
  const osm = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '',
    isArray: (name) => ['node', 'way', 'relation', 'nd', 'member', 'tag'].includes(name) }).parse(source.toString('utf8')).osm;
  const nodes = new Map((osm.node ?? []).map((node) => [String(node.id), node]));
  const ways = new Map((osm.way ?? []).map((way) => [String(way.id), way]));
  const inside = (lon, lat) => Number.isFinite(lon) && Number.isFinite(lat) &&
    lon >= bounds[0] && lon <= bounds[2] && lat >= bounds[1] && lat <= bounds[3];
  await mkdir(dirname(outputPath), { recursive: true });
  await rm(outputPath, { force: true });
  const db = new DatabaseSync(outputPath);
  try {
    db.exec(`PRAGMA journal_mode=DELETE;
      CREATE TABLE metadata (key TEXT PRIMARY KEY, value TEXT NOT NULL);
      CREATE TABLE places (
        id INTEGER PRIMARY KEY,
        feature_id TEXT NOT NULL UNIQUE,
        name TEXT NOT NULL,
        category TEXT NOT NULL,
        longitude REAL NOT NULL,
        latitude REAL NOT NULL,
        elevation_m REAL,
        attributes_json TEXT NOT NULL
      );
      CREATE VIRTUAL TABLE place_fts USING fts5(
        name, category, content='places', content_rowid='id',
        tokenize='unicode61 remove_diacritics 2', prefix='2 3 4'
      );
      PRAGMA user_version=2;`);
    db.prepare('INSERT INTO metadata VALUES (?, ?)').run('source_sha256', sourceHash);
    db.prepare('INSERT INTO metadata VALUES (?, ?)').run('search_index_version', String(searchIndexVersion));
    const insert = db.prepare(`INSERT OR IGNORE INTO places
      (feature_id, name, category, longitude, latitude, elevation_m, attributes_json)
      VALUES (?, ?, ?, ?, ?, ?, ?)`);
    let count = 0;
    function add(type, element, lon, lat) {
      const t = tagMap(element);
      const name = String(t.name ?? t['name:ro'] ?? '').trim();
      const kind = category(t);
      if (!name || !kind || !inside(lon, lat)) return;
      const elevation = t.ele == null ? null : Number(String(t.ele).replace(/\s*m$/, ''));
      const attributes = Object.fromEntries(attributeKeys.filter((key) => t[key] != null)
        .map((key) => [key, String(t[key])]));
      const result = insert.run(`${type}/${element.id}`, name, kind, lon, lat,
        Number.isFinite(elevation) ? elevation : null, JSON.stringify(attributes));
      if (result.changes) count++;
    }
    for (const node of osm.node ?? []) add('node', node, Number(node.lon), Number(node.lat));
    for (const way of osm.way ?? []) {
      const refs = (way.nd ?? []).map((nd) => nodes.get(String(nd.ref))).filter(Boolean);
      if (!refs.length) continue;
      const point = refs[Math.floor(refs.length / 2)];
      add('way', way, Number(point.lon), Number(point.lat));
    }
    for (const relation of osm.relation ?? []) {
      const t = tagMap(relation);
      if (!['hiking', 'foot'].includes(t.route)) continue;
      for (const member of relation.member ?? []) {
        if (member.type !== 'way' || !ways.has(String(member.ref))) continue;
        const refs = (ways.get(String(member.ref)).nd ?? []).map((nd) => nodes.get(String(nd.ref))).filter(Boolean);
        if (!refs.length) continue;
        const point = refs[Math.floor(refs.length / 2)];
        if (!inside(Number(point.lon), Number(point.lat))) continue;
        add('relation', relation, Number(point.lon), Number(point.lat));
        break;
      }
    }
    db.exec("INSERT INTO place_fts(place_fts) VALUES ('rebuild');");
    if (db.prepare('PRAGMA integrity_check').get().integrity_check !== 'ok') {
      throw new Error('Search database integrity check failed');
    }
    return { count, sourceSha256: sourceHash, indexVersion: searchIndexVersion };
  } finally {
    db.close();
  }
}

if (process.argv[1] && resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const sourceMeta = JSON.parse(await readFile(resolve(root, 'map-tools/source/metadata.json'), 'utf8'));
  const result = await buildSearchIndex({ expectedSha256: sourceMeta.sha256 });
  if (result.count < 5) throw new Error('Search index unexpectedly sparse');
  console.log(`Indexed ${result.count} named OSM features (search schema v${result.indexVersion})`);
}
