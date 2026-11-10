import http from 'node:http';
import { createReadStream } from 'node:fs';
import { readFile, stat } from 'node:fs/promises';
import { networkInterfaces } from 'node:os';
import { resolve, dirname } from 'node:path';

const args = process.argv.slice(2);
function option(name, fallback) { const i = args.indexOf(name); return i < 0 ? fallback : args[i + 1]; }
const file = resolve(option('--package', 'map-tools/.cache/romania/romania.rwpkg'));
const entryFile = resolve(option('--entry', `${dirname(file)}/catalog-entry.json`));
const port = Number(option('--port', '8765'));
const host = option('--host', '0.0.0.0');
if (!Number.isInteger(port) || port < 1 || port > 65535) throw new Error('Invalid port');
const entry = JSON.parse(await readFile(entryFile, 'utf8'));
const size = (await stat(file)).size;
if (size !== entry.bytes || !/^[a-f0-9]{64}$/.test(entry.sha256) || !entry.package?.id) throw new Error('Package and catalog entry do not match');

const server = http.createServer((req, res) => {
  const peer = req.socket.remoteAddress?.replace(/^::ffff:/, '') || '';
  if (!/^(?:127\.|10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(peer)) { res.writeHead(403).end(); return; }
  const address = req.socket.localAddress?.replace(/^::ffff:/, '');
  if (!address || !/^(?:\d{1,3}\.){3}\d{1,3}$/.test(address)) { res.writeHead(400).end(); return; }
  res.setHeader('X-Content-Type-Options', 'nosniff');
  res.setHeader('Cache-Control', 'no-store');
  if (!['GET', 'HEAD'].includes(req.method)) { res.writeHead(405).end(); return; }
  if (req.url === '/catalog.json') {
    const body = Buffer.from(JSON.stringify({ catalogVersion: 1, packages: [{ ...entry, url: `http://${address}:${port}/region.rwpkg` }] }));
    res.writeHead(200, { 'Content-Type': 'application/json', 'Content-Length': body.length });
    res.end(req.method === 'HEAD' ? undefined : body); return;
  }
  if (req.url !== '/region.rwpkg') { res.writeHead(404).end(); return; }
  let start = 0, end = size - 1, status = 200;
  if (req.headers.range) {
    const match = /^bytes=(\d+)-(\d*)$/.exec(req.headers.range);
    if (!match) { res.writeHead(416, { 'Content-Range': `bytes */${size}` }).end(); return; }
    start = Number(match[1]); end = match[2] ? Math.min(Number(match[2]), end) : end;
    if (!Number.isSafeInteger(start) || !Number.isSafeInteger(end) || start > end || start >= size) { res.writeHead(416, { 'Content-Range': `bytes */${size}` }).end(); return; }
    status = 206; res.setHeader('Content-Range', `bytes ${start}-${end}/${size}`);
  }
  res.writeHead(status, { 'Content-Type': 'application/octet-stream', 'Content-Length': end - start + 1, 'Accept-Ranges': 'bytes' });
  if (req.method === 'HEAD') { res.end(); return; }
  const stream = createReadStream(file, { start, end });
  stream.on('error', () => res.destroy());
  res.on('close', () => stream.destroy());
  stream.pipe(res);
});
server.listen(port, host, () => {
  console.log(`Serving ${file} on ${host}:${port}. Use only on a trusted network.`);
  for (const group of Object.values(networkInterfaces())) for (const item of group || []) {
    if (item.family === 'IPv4' && !item.internal && /^(?:10\.|192\.168\.|172\.(?:1[6-9]|2\d|3[01])\.)/.test(item.address)) console.log(`Catalog: http://${item.address}:${port}/catalog.json`);
  }
});
