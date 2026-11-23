// tests/compute/browser.mjs REPO WASM MODE -- run a compute host under headless
// Chromium's software WebGPU adapter and print its stdout. MODE is normal,
// nogpu (no navigator.gpu is handed to the host) or nojspi (no JSPI).
//
// COMPUTE_WEBGPU=hardware uses the machine's GPU and fails on a software adapter;
// COMPUTE_CHROME_CHANNEL (for example chrome) selects an installed browser.
import { createRequire } from 'node:module'; import http from 'node:http'; import fs from 'node:fs'; import path from 'node:path';
const require = createRequire(process.env.PLAYWRIGHT_DIR + '/');
const { chromium } = require('playwright');
const [repo, wasm, mode] = process.argv.slice(2);
const types = { '.mjs': 'text/javascript', '.wasm': 'application/wasm', '.html': 'text/html' };
const srv = http.createServer((q, r) => {
  const u = q.url.split('?')[0];
  const f = u === '/app.wasm' ? wasm : u === '/' ? null : path.join(repo, u);
  if (f === null) { r.writeHead(200, { 'content-type': 'text/html' }); return r.end('<!doctype html>'); }
  fs.readFile(f, (e, d) => {
    if (e) { r.writeHead(404); return r.end(); }
    r.writeHead(200, { 'content-type': types[path.extname(f)] || 'application/octet-stream' }); r.end(d);
  });
}).listen(0, '127.0.0.1');
const hardware = process.env.COMPUTE_WEBGPU === 'hardware';
const args = hardware ? ['--enable-unsafe-webgpu', '--ignore-gpu-blocklist']
  : ['--enable-unsafe-webgpu', '--enable-features=Vulkan', '--use-vulkan=swiftshader', '--use-webgpu-adapter=swiftshader', '--ignore-gpu-blocklist'];
const channel = process.env.COMPUTE_CHROME_CHANNEL;
const b = await chromium.launch({ args, ...(channel ? { channel } : {}) });
const p = await b.newPage();
await p.goto(`http://127.0.0.1:${srv.address().port}/`);
const adapter = await p.evaluate(async () => {
  const a = await navigator.gpu?.requestAdapter();
  return a ? { vendor: a.info.vendor, architecture: a.info.architecture, description: a.info.description, fallback: a.info.isFallbackAdapter } : null;
});
console.error('adapter ' + JSON.stringify(adapter));
if (hardware && mode === 'normal' && (!adapter || adapter.fallback || /swiftshader/i.test(JSON.stringify(adapter)))) {
  console.error('FAIL COMPUTE_WEBGPU=hardware got no hardware adapter');
  await b.close(); srv.close(); process.exit(91);
}
const r = await p.evaluate(async (mode) => {
  if (mode === 'nojspi') delete WebAssembly.Suspending;
  const { runModule } = await import('/tools/wasm/wasi_shim.mjs');
  const { makeComputeApi } = await import('/tools/wasm/compute_host.mjs');
  const mod = await WebAssembly.compileStreaming(fetch('/app.wasm'));
  try {
    const res = await runModule(mod, { host: (state) => makeComputeApi(state, mode === 'nogpu' ? null : navigator.gpu) });
    return { code: res.code, out: res.stdout, err: res.stderr };
  } catch (e) { return { code: 90, out: '', err: String(e && e.message || e) }; }
}, mode);
await b.close(); srv.close();
process.stdout.write(r.out); if (r.err) process.stderr.write(r.err + '\n');
process.exit(r.code);
