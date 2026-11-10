import { readFile, stat } from 'node:fs/promises';
import { resolve } from 'node:path';
import { fileURLToPath } from 'node:url';

const packageRoot = fileURLToPath(new URL('../', import.meta.url));
const root = resolve(packageRoot, '../assets/renderer');
const html = await readFile(resolve(root, 'index.html'), 'utf8');
const js = await readFile(resolve(root, 'assets/renderer.js'), 'utf8');
const css = await readFile(resolve(root, 'assets/index.css'), 'utf8');

if (/<(?:script|link)[^>]+(?:src|href)=["']https?:\/\//i.test(html)) {
  throw new Error('HTML has a remote runtime dependency');
}
if (/(?:@import|url\()\s*["']?https?:\/\//i.test(css)) {
  throw new Error('CSS has a remote runtime dependency');
}

const referenced = new Set([
  ...[...html.matchAll(/(?:src|href)="\.\/assets\/([^"]+)"/g)].map((match) => match[1]),
  ...[...js.matchAll(/(?:maplibre-gl-worker-[\w-]+|noto-sans-[\w-]+)\.(?:js|woff2)/g)].map((match) => match[0]),
]);
for (const file of referenced) {
  const entry = await stat(resolve(root, 'assets', file));
  if (!entry.isFile()) throw new Error(`Missing bundled asset: ${file}`);
}
if (![...referenced].some((name) => name.startsWith('maplibre-gl-worker')) ||
    ![...referenced].some((name) => name.endsWith('.woff2'))) {
  throw new Error('Expected local worker and font assets');
}
console.log(`Verified ${referenced.size} local renderer asset references`);
