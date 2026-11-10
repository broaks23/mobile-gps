import { readFile, writeFile, mkdir } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync, gunzipSync } from 'node:zlib';
import { createHash } from 'node:crypto';
import { spawnSync } from 'node:child_process';
import geojsonvt from 'geojson-vt';
import vtpbf from 'vt-pbf';
import initSqlJs from 'sql.js';
import { XMLParser } from 'fast-xml-parser';

const root = fileURLToPath(new URL('../', import.meta.url));
const source = resolve(root, 'map-tools/source/bucegi.osm.gz');
const mbtiles = resolve(root, 'map-tools/.cache/bucegi.mbtiles');
const output = resolve(root, 'samples/bucegi/map.pmtiles');
const bounds = [25.41, 45.36, 25.52, 45.45];
const pmtilesBin = process.env.PMTILES_BIN || 'pmtiles';
const layers = Object.fromEntries(['landcover', 'water', 'waterway', 'transportation', 'hiking_routes', 'places', 'mountain', 'huts'].map((name) => [name, []]));
const sourceXml = gunzipSync(await readFile(source));
const sourceSha256 = createHash('sha256').update(sourceXml).digest('hex');
const sourceMeta = JSON.parse(await readFile(resolve(root, 'map-tools/source/metadata.json'), 'utf8'));
if (sourceMeta.sha256 !== sourceSha256) throw new Error('Pinned OSM extract SHA-256 does not match source metadata');
const parsed = new XMLParser({ ignoreAttributes: false, attributeNamePrefix: '', isArray: (name) => ['node', 'way', 'relation', 'nd', 'member', 'tag'].includes(name) }).parse(sourceXml.toString('utf8')).osm;
const tagsFor = (item) => Object.fromEntries((item.tag ?? []).map((tag) => [tag.k, tag.v]));
const nodes = new Map((parsed.node ?? []).map((node) => [Number(node.id), { lon: Number(node.lon), lat: Number(node.lat) }]));
const ways = new Map((parsed.way ?? []).map((way) => [Number(way.id), (way.nd ?? []).map((nd) => nodes.get(Number(nd.ref))).filter(Boolean)]));
const elements = [
  ...(parsed.node ?? []).map((node) => ({ type: 'node', id: Number(node.id), lon: Number(node.lon), lat: Number(node.lat), tags: tagsFor(node) })),
  ...(parsed.way ?? []).map((way) => ({ type: 'way', id: Number(way.id), geometry: ways.get(Number(way.id)), tags: tagsFor(way) })),
  ...(parsed.relation ?? []).map((relation) => ({ type: 'relation', id: Number(relation.id), members: (relation.member ?? []).map((member) => ({ type: member.type, ref: Number(member.ref), role: member.role, geometry: member.type === 'way' ? ways.get(Number(member.ref)) : undefined })), tags: tagsFor(relation) })),
];
const timestamp = sourceMeta.downloadedAt;
const within = ([lon, lat]) => lon >= bounds[0] && lon <= bounds[2] && lat >= bounds[1] && lat <= bounds[3];
const coord = (p) => [p.lon, p.lat];
const validLine = (points) => Array.isArray(points) && points.length >= 2 && points.every((p) => Number.isFinite(p.lon) && Number.isFinite(p.lat));
const feature = (layer, type, coordinates, properties, id) => {
  layers[layer].push({ type: 'Feature', id, geometry: { type, coordinates }, properties });
};
const properties = (tags, id) => {
  const keep = ['name', 'name:en', 'ref', 'highway', 'natural', 'landuse', 'leisure', 'water', 'waterway', 'place', 'tourism', 'amenity', 'ele', 'sac_scale', 'trail_visibility', 'surface', 'tracktype', 'foot', 'access', 'network', 'route', 'osmc:symbol', 'colour', 'symbol', 'description', 'mountain_pass'];
  const result = Object.fromEntries([['osm_id', String(id)], ...keep.filter((key) => tags[key] != null).map((key) => [key, String(tags[key])])]);
  const marking = String(tags['osmc:symbol'] ?? '').split(':')[0].toLowerCase();
  const colour = String(tags.colour ?? '').toLowerCase();
  const routeColor = [marking, colour].find((value) => ['red', 'blue', 'yellow', 'green'].includes(value));
  if (routeColor) result.route_color = routeColor;
  return result;
};
const land = (tags) => ['wood', 'grassland', 'scrub', 'heath', 'wetland'].includes(tags.natural) || ['forest', 'grass', 'meadow', 'residential', 'farmland'].includes(tags.landuse);
const water = (tags) => tags.natural === 'water' || tags.water != null;
const polygonLayer = (tags) => water(tags) ? 'water' : land(tags) ? 'landcover' : null;
const poi = (tags, position, id) => {
  if (tags.natural === 'peak' || tags.natural === 'saddle' || tags.mountain_pass === 'yes') feature('mountain', 'Point', position, properties(tags, id), id);
  if (['alpine_hut', 'wilderness_hut', 'camp_site'].includes(tags.tourism) || tags.amenity === 'shelter') feature('huts', 'Point', position, properties(tags, id), id);
  if (tags.place) feature('places', 'Point', position, properties(tags, id), id);
};

for (const item of elements) {
  const tags = item.tags ?? {};
  if (item.type === 'node') {
    const position = [item.lon, item.lat];
    if (within(position)) poi(tags, position, item.id);
  } else if (item.type === 'way' && validLine(item.geometry)) {
    const line = item.geometry.map(coord);
    const closed = line.length >= 4 && line[0][0] === line.at(-1)[0] && line[0][1] === line.at(-1)[1];
    const areaLayer = polygonLayer(tags);
    if (closed && areaLayer) feature(areaLayer, 'Polygon', [line], properties(tags, item.id), item.id);
    if (tags.highway) feature('transportation', 'LineString', line, properties(tags, item.id), item.id);
    if (tags.waterway) feature('waterway', 'LineString', line, properties(tags, item.id), item.id);
    if (tags.natural === 'peak' || tags.natural === 'saddle' || tags.mountain_pass === 'yes' || tags.place || tags.tourism || tags.amenity === 'shelter') {
      const middle = line[Math.floor(line.length / 2)];
      if (within(middle)) poi(tags, middle, item.id);
    }
  } else if (item.type === 'relation') {
    if (['hiking', 'foot'].includes(tags.route)) {
      for (const member of item.members ?? []) {
        if (member.type !== 'way' || !validLine(member.geometry)) continue;
        const line = member.geometry.map(coord);
        if (!line.some(within)) continue;
        feature('hiking_routes', 'LineString', line, { ...properties(tags, item.id), way_id: String(member.ref), role: member.role ?? '' }, item.id);
      }
    }
    const areaLayer = polygonLayer(tags);
    if (tags.type === 'multipolygon' && areaLayer) {
      // Overpass supplies way geometries. Closed outer members can be tiled safely;
      // split/open rings and inner rings require a topology-aware production pipeline.
      for (const member of item.members ?? []) {
        if (member.type !== 'way' || member.role !== 'outer' || !validLine(member.geometry)) continue;
        const ring = member.geometry.map(coord);
        if (ring.length >= 4 && ring[0][0] === ring.at(-1)[0] && ring[0][1] === ring.at(-1)[1]) {
          feature(areaLayer, 'Polygon', [ring], properties(tags, item.id), item.id);
        }
      }
    }
  }
}

const indexes = Object.fromEntries(Object.entries(layers).map(([name, features]) => [name, geojsonvt({ type: 'FeatureCollection', features }, { maxZoom: 14, indexMaxZoom: 7, tolerance: 2, extent: 4096, buffer: 64 })]));
const SQL = await initSqlJs();
const db = new SQL.Database();
db.run('CREATE TABLE metadata (name text, value text); CREATE TABLE tiles (zoom_level integer, tile_column integer, tile_row integer, tile_data blob); CREATE UNIQUE INDEX tile_index ON tiles (zoom_level, tile_column, tile_row)');
const addMeta = db.prepare('INSERT INTO metadata VALUES (?, ?)');
for (const [key, value] of Object.entries({ name: 'Ridgewalk Bucegi hiking sample', type: 'baselayer', version: '1', description: 'OSM-derived Ridgewalk hiking schema v1', format: 'pbf', minzoom: '9', maxzoom: '14', bounds: bounds.join(','), center: '25.47,45.41,11', attribution: '© OpenStreetMap contributors (ODbL)', json: JSON.stringify({ vector_layers: Object.entries(layers).map(([id]) => ({ id, minzoom: 9, maxzoom: 14, fields: {} })) }) })) addMeta.run([key, value]);
addMeta.free();
const addTile = db.prepare('INSERT INTO tiles VALUES (?, ?, ?, ?)');
const tileX = (lon, z) => Math.floor((lon + 180) / 360 * 2 ** z);
const tileY = (lat, z) => Math.floor((1 - Math.asinh(Math.tan(lat * Math.PI / 180)) / Math.PI) / 2 * 2 ** z);
let tileCount = 0;
for (let z = 9; z <= 14; z++) {
  const n = 2 ** z;
  for (let x = tileX(bounds[0], z); x <= tileX(bounds[2], z); x++) {
    for (let y = tileY(bounds[3], z); y <= tileY(bounds[1], z); y++) {
      const tileLayers = Object.fromEntries(Object.entries(indexes).map(([name, index]) => [name, index.getTile(z, x, y)]).filter(([, tile]) => tile?.features.length));
      if (!Object.keys(tileLayers).length) continue;
      const tile = gzipSync(vtpbf.fromGeojsonVt(tileLayers), { level: 9 });
      addTile.run([z, x, n - y - 1, tile]);
      tileCount++;
    }
  }
}
addTile.free();
await mkdir(resolve(root, 'samples/bucegi'), { recursive: true });
await mkdir(resolve(root, 'map-tools/.cache'), { recursive: true });
await writeFile(mbtiles, Buffer.from(db.export()));
db.close();
const converted = spawnSync(pmtilesBin, ['convert', mbtiles, output], { encoding: 'utf8' });
if (converted.error) throw converted.error;
if (converted.status !== 0) throw new Error(`pmtiles convert failed: ${converted.stderr || converted.stdout}`);
const archiveSha256 = createHash('sha256').update(await readFile(output)).digest('hex');
const manifestPath = resolve(root, 'samples/bucegi/manifest.json');
const manifest = JSON.parse(await readFile(manifestPath, 'utf8'));
Object.assign(manifest, {
  name: 'Bucegi Mountains hiking and terrain sample',
  bounds,
  vectorSchema: 'ridgewalk-hiking-v1',
  mapAttribution: '© OpenStreetMap contributors · ODbL 1.0',
  terrainAttribution: manifest.terrainAttribution ?? manifest.attribution,
  terrainBounds: manifest.terrainBounds ?? [25.32, 45.30, 25.62, 45.52],
  mapSource: sourceMeta.url,
  mapSourceDate: timestamp,
  mapSourceSha256: sourceSha256,
  mapRawSourceSha256: sourceMeta.rawSha256,
  mapSha256: archiveSha256,
  mapLicense: 'ODbL 1.0',
  mapLicenseUrl: 'https://www.openstreetmap.org/copyright',
  mapBounds: bounds,
});
await writeFile(manifestPath, `${JSON.stringify(manifest, null, 2)}\n`);
console.log(JSON.stringify({ source, timestamp, sourceSha256, archiveSha256, features: Object.fromEntries(Object.entries(layers).map(([name, list]) => [name, list.length])), tileCount, output }, null, 2));
