import { createReadStream, createWriteStream } from 'node:fs';
import { mkdir, readFile, writeFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { once } from 'node:events';
import { resolve } from 'node:path';

const dir = resolve(process.argv[2] || '.cache/romania');
const output = resolve(process.argv[3] || `${dir}/romania.rwpkg`);
const paths = { 'map.pmtiles': `${dir}/shortbread/romania-pmtiles-shortbread/romania.pmtiles`, 'terrain.pmtiles': `${dir}/terrain-romania.pmtiles`, 'search.sqlite': `${dir}/search.sqlite` };
const table = Uint32Array.from({ length: 256 }, (_, i) => { let n = i; for (let j = 0; j < 8; j++) n = n & 1 ? 0xedb88320 ^ (n >>> 1) : n >>> 1; return n >>> 0; });
async function info(path) {
  const hash = createHash('sha256'); let crc = 0xffffffff, bytes = 0;
  for await (const chunk of createReadStream(path)) { hash.update(chunk); bytes += chunk.length; for (const b of chunk) crc = table[(crc ^ b) & 255] ^ (crc >>> 8); }
  return { bytes, sha256: hash.digest('hex'), crc: (crc ^ 0xffffffff) >>> 0 };
}
const infoByName = {};
for (const [name, path] of Object.entries(paths)) { console.log(`Hashing ${name}`); infoByName[name] = await info(path); }
const sources = JSON.parse(await readFile(new URL('./romania-sources.json', import.meta.url), 'utf8')).sources;
if (infoByName['map.pmtiles'].sha256 !== sources.shortbread.sha256 || infoByName['terrain.pmtiles'].sha256 !== sources.terrain.sha256) throw new Error('Map or terrain source checksum mismatch');
const metadata = {
  formatVersion: 1, id: 'romania', name: 'Romania offline map', bounds: [20.2,43.6,30.3,48.3],
  mapDetail: 'Shortbread z14', terrainResolution: 'Mapterhorn 30m z12', terrainEncoding: 'terrarium', vectorSchema: 'shortbread-1.0', searchIndexVersion: 2,
  mapAttribution: '© OpenStreetMap contributors · ODbL 1.0', terrainAttribution: '© Mapterhorn; Copernicus WorldDEM-30 © DLR and Airbus; see mapterhorn.com/attribution',
  licenses: { map: 'ODbL 1.0', terrain: 'Mapterhorn source licenses: https://mapterhorn.com/attribution/', search: 'ODbL 1.0' },
  datasetVersions: { osm: '2026-11-10', osmSha256: '82d35a6467e5955792fa7efd8e94d3c6f39337124f72c9346d99ae5ff7923027', vector: 'BBBike Shortbread 2026-11-09', dem: 'Mapterhorn z0-12 extract 2026-11-10', searchIndex: '2' },
  files: Object.fromEntries(Object.entries(infoByName).map(([name, v]) => [name, { bytes: v.bytes, sha256: v.sha256 }])),
};
await mkdir(dir, { recursive: true });
await writeFile(`${dir}/package.json`, JSON.stringify(metadata, null, 2) + '\n');
paths['package.json'] = `${dir}/package.json`;
infoByName['package.json'] = await info(paths['package.json']);
const names = ['package.json','map.pmtiles','terrain.pmtiles','search.sqlite'];
const total = names.reduce((s, name) => s + infoByName[name].bytes + 200, 0);
if (total >= 0xffffffff) throw new Error('Package exceeds classic ZIP size limit');
const out = createWriteStream(output); let position = 0; const central = [];
async function emit(buffer) { position += buffer.length; if (!out.write(buffer)) await once(out, 'drain'); }
for (const name of names) {
  const { bytes, crc } = infoByName[name], filename = Buffer.from(name), offset = position;
  const local = Buffer.alloc(30 + filename.length); local.writeUInt32LE(0x04034b50, 0); local.writeUInt16LE(20, 4); local.writeUInt32LE(crc, 14); local.writeUInt32LE(bytes, 18); local.writeUInt32LE(bytes, 22); local.writeUInt16LE(filename.length, 26); filename.copy(local, 30);
  await emit(local); for await (const chunk of createReadStream(paths[name])) await emit(chunk);
  const c = Buffer.alloc(46 + filename.length); c.writeUInt32LE(0x02014b50, 0); c.writeUInt16LE(20, 4); c.writeUInt16LE(20, 6); c.writeUInt32LE(crc, 16); c.writeUInt32LE(bytes, 20); c.writeUInt32LE(bytes, 24); c.writeUInt16LE(filename.length, 28); c.writeUInt32LE(offset, 42); filename.copy(c, 46); central.push(c);
}
const start = position; for (const c of central) await emit(c);
const end = Buffer.alloc(22); end.writeUInt32LE(0x06054b50, 0); end.writeUInt16LE(names.length, 8); end.writeUInt16LE(names.length, 10); end.writeUInt32LE(position - start, 12); end.writeUInt32LE(start, 16); await emit(end);
out.end(); await once(out, 'finish');
const archive = await info(output);
await writeFile(`${dir}/catalog-entry.json`, JSON.stringify({ package: metadata, bytes: archive.bytes, sha256: archive.sha256 }, null, 2) + '\n');
console.log(`Wrote ${output}: ${archive.bytes} bytes SHA-256 ${archive.sha256}`);
