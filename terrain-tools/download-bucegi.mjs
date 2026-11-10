import { createHash } from 'node:crypto';
import { createWriteStream } from 'node:fs';
import { mkdir, readFile, rename, rm, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { pipeline } from 'node:stream/promises';
import { Readable } from 'node:stream';
import { fileURLToPath } from 'node:url';
import { sourceName, sourceSha256, sourceUrl } from './source.mjs';

const root = fileURLToPath(new URL('./', import.meta.url));
const cache = resolve(root, '.cache');
await mkdir(cache, { recursive: true });
const destination = resolve(cache, sourceName);
const partial = `${destination}.partial`;
try {
  if ((await stat(destination)).size === 42545531) {
    const existingHash = createHash('sha256').update(await readFile(destination)).digest('hex');
    if (existingHash === sourceSha256) {
      console.log(`Verified existing source: ${destination}`);
      process.exit(0);
    }
  }
} catch { /* Download below. */ }

const response = await fetch(sourceUrl);
if (!response.ok || !response.body) throw new Error(`Source download returned HTTP ${response.status}`);
const digest = createHash('sha256');
try {
  await pipeline(Readable.fromWeb(response.body), async function* (chunks) {
    for await (const chunk of chunks) {
      digest.update(chunk);
      yield chunk;
    }
  }, createWriteStream(partial));
  const actual = digest.digest('hex');
  if (actual !== sourceSha256) throw new Error(`Source SHA-256 mismatch: ${actual}`);
  await rename(partial, destination);
  console.log(`Verified Copernicus DEM source: ${destination}`);
} catch (error) {
  await rm(partial, { force: true });
  throw error;
}

