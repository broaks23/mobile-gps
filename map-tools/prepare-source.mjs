import { createHash } from 'node:crypto';
import { readFile, writeFile } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';
import { gzipSync } from 'node:zlib';

const origin = process.argv[2];
if (!origin) throw new Error('Pass the raw OSM extract URL as the first argument');
const root = fileURLToPath(new URL('../', import.meta.url));
const input = resolve(root, 'map-tools/.cache/bucegi.osm');
const raw = await readFile(input, 'utf8');
if (!raw.startsWith('<?xml') || !raw.includes('<osm ')) throw new Error('Input is not OSM XML');
const sanitized = raw.replace(/ (?:user|uid|changeset|version|timestamp)="[^"]*"/g, '');
const sha256 = (data) => createHash('sha256').update(data).digest('hex');
await writeFile(resolve(root, 'map-tools/source/bucegi.osm.gz'), gzipSync(Buffer.from(sanitized), { level: 9, mtime: 0 }));
await writeFile(resolve(root, 'map-tools/source/metadata.json'), `${JSON.stringify({
  downloadedAt: new Date().toISOString().slice(0, 10),
  url: origin,
  rawSha256: sha256(raw),
  sha256: sha256(sanitized),
}, null, 2)}\n`);
console.log(`Prepared ${Buffer.byteLength(sanitized)} bytes of OSM XML without contributor account metadata; SHA-256 ${sha256(sanitized)}`);
