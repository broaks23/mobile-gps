import { cp, mkdir, rm } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = fileURLToPath(new URL('../', import.meta.url));
const source = resolve(packageRoot, 'dist');
const target = resolve(packageRoot, '../assets/renderer');
await rm(target, { recursive: true, force: true });
await mkdir(target, { recursive: true });
await cp(source, target, { recursive: true });
await mkdir(resolve(target, 'licenses'), { recursive: true });
for (const name of ['MapLibre-BSD-3-Clause.txt', 'PMTiles-BSD-3-Clause.txt', 'NotoSans-OFL.txt']) {
  await cp(resolve(packageRoot, '../licenses', name), resolve(target, 'licenses', name));
}
console.log(`Copied renderer bundle to ${target}`);

