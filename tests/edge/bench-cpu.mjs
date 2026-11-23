// tests/edge/bench-cpu.mjs -- CPU time per request for a command-mode Workers
// module, the way tools/wasm/worker.mjs runs it: the module is compiled once,
// then every request instantiates it with tools/wasm/wasi_shim.mjs's WASI
// imports and enters _start.
//
//   node --experimental-wasm-exnref tests/edge/bench-cpu.mjs APP.wasm \
//        [--path /info] [--query a=1] [--method GET] [--body-bytes N | --body STR]
//        [--env K=V]... [--warmup 50] [--n 500] [--json]
//
// A MEASUREMENT, not a check: it prints percentiles and has no pass/fail.
//
// Per phase it records process.cpuUsage() (user + system) and performance.now()
// deltas, in microseconds. process.cpuUsage() is PROCESS-wide: V8's background
// threads (tier-up compiles, GC helpers) are included in whichever phase they
// overlap, which is why the requests are warmed up first. A module that imports
// `spinel_host` gets no host API here: every host import answers E_NOSYS, as
// worker.mjs does for a name with no binding (mvc-blog then keeps its posts in
// memory, as it does on Workers without a KV binding).
//
// It also counts V8's GC entries by kind over the measured requests, with their
// total duration (perf_hooks 'gc' entries). With a shim that has acquireWasi
// it measures the pooled path runModule uses; otherwise makeWasi, a fresh
// import object per request, so one harness compares the two.
//
// The numbers are this machine's, not Cloudflare's.
import fs from "node:fs";
import { PerformanceObserver, constants as PC } from "node:perf_hooks";
import * as shim from "../../tools/wasm/wasi_shim.mjs";
const { makeWasi, WasiExit, HOST_NS } = shim;
// The pooled path (acquireWasi/releaseWasi) is what runModule uses; a shim
// without it is measured through makeWasi, a fresh import object per request.
const POOLED = typeof shim.acquireWasi === "function";

const argv = process.argv.slice(2);
const file = argv.shift();
const opt = { path: "/", query: "", method: "GET", bodyBytes: 0, bodyStr: null, env: {}, warmup: 50, n: 500, json: false };
while (argv.length) {
  const a = argv.shift();
  if (a === "--path") opt.path = argv.shift();
  else if (a === "--query") opt.query = argv.shift();
  else if (a === "--method") opt.method = argv.shift();
  else if (a === "--body-bytes") opt.bodyBytes = Number(argv.shift());
  else if (a === "--body") { opt.bodyStr = argv.shift(); opt.bodyBytes = Buffer.byteLength(opt.bodyStr); }
  else if (a === "--env") { const kv = argv.shift(); const i = kv.indexOf("="); opt.env[kv.slice(0, i)] = kv.slice(i + 1); }
  else if (a === "--warmup") opt.warmup = Number(argv.shift());
  else if (a === "--n") opt.n = Number(argv.shift());
  else if (a === "--json") opt.json = true;
  else throw new Error(`unknown argument ${a}`);
}

const cpu = () => { const u = process.cpuUsage(); return u.user + u.system; };  // microseconds
const now = () => performance.now() * 1000;                                       // microseconds

const bytes = fs.readFileSync(file);
let c0 = cpu(), w0 = now();
const mod = await WebAssembly.compile(bytes);
const compile = { cpu: cpu() - c0, wall: now() - w0 };

const body = opt.bodyStr !== null ? new TextEncoder().encode(opt.bodyStr) : new Uint8Array(opt.bodyBytes).fill(0x61);
const env = { REQUEST_METHOD: opt.method, CONTENT_TYPE: "application/x-www-form-urlencoded",
              CONTENT_LENGTH: String(opt.bodyBytes), SPINEL_CGI_HEADERS: "1", ...opt.env };
const hostNames = WebAssembly.Module.imports(mod).filter((i) => i.module === HOST_NS).map((i) => i.name);
const hostTable = hostNames.length ? Object.fromEntries(hostNames.map((n) => [n, () => -6])) : null;

function request() {
  const got = (POOLED ? shim.acquireWasi : makeWasi)({ env, args: [opt.path, opt.query], stdin: body });
  const state = got.state;
  const imports = hostTable ? { ...got.imports, [HOST_NS]: hostTable } : got.imports;
  let c = cpu(), w = now();
  const inst = new WebAssembly.Instance(mod, imports);
  const inst_t = { cpu: cpu() - c, wall: now() - w };
  state.mem = inst.exports.memory;
  let code = 0;
  c = cpu(); w = now();
  try { inst.exports._start(); } catch (e) { if (e instanceof WasiExit) code = e.code; else throw e; }
  const run_t = { cpu: cpu() - c, wall: now() - w };
  const outLen = state.outBytes().length;
  if (POOLED) shim.releaseWasi(got.slot);
  return { inst: inst_t, run: run_t, code, outLen };
}

const first = request();
for (let i = 0; i < opt.warmup; i++) request();
// V8 GC entries over the measured requests only (perf_hooks shares performance.now's clock).
const gcs = [];
const gcObs = new PerformanceObserver((l) => { for (const e of l.getEntries()) gcs.push(e); });
const rows = [];
const tStart = performance.now();
gcObs.observe({ entryTypes: ["gc"] });
for (let i = 0; i < opt.n; i++) rows.push(request());
const tEnd = performance.now();
await new Promise((r) => setTimeout(r, 20));
gcObs.disconnect();

const pct = (xs, p) => { const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.ceil(p / 100 * s.length) - 1)]; };
const stat = (xs) => ({ p50: pct(xs, 50), p90: pct(xs, 90), p99: pct(xs, 99), max: Math.max(...xs) });
const res = { shim: POOLED ? "pooled" : "fresh", file, request: `${opt.method} ${opt.path}${opt.query ? "?" + opt.query : ""} body=${opt.bodyBytes}B`,
              exit: first.code, stdout_bytes: first.outLen, compile };
{ const kinds = { [PC.NODE_PERFORMANCE_GC_MAJOR]: "major", [PC.NODE_PERFORMANCE_GC_MINOR]: "minor",
                  [PC.NODE_PERFORMANCE_GC_INCREMENTAL]: "incremental", [PC.NODE_PERFORMANCE_GC_WEAKCB]: "weakcb" };
  const inRun = gcs.filter((g) => g.startTime >= tStart && g.startTime <= tEnd);
  res.gc = { count: {}, ms: 0 };
  for (const g of inRun) { const k = kinds[g.detail?.kind] ?? String(g.detail?.kind); res.gc.count[k] = (res.gc.count[k] || 0) + 1; res.gc.ms += g.duration; }
  res.gc.ms = Math.round(res.gc.ms * 100) / 100; }
for (const ph of ["inst", "run"]) for (const k of ["cpu", "wall"]) res[`${ph}_${k}`] = stat(rows.map((r) => r[ph][k]));
for (const k of ["cpu", "wall"]) res[`total_${k}`] = stat(rows.map((r) => r.inst[k] + r.run[k]));

if (opt.json) { console.log(JSON.stringify(res)); }
else {
  const f = (s) => `p50 ${s.p50.toFixed(0)}  p90 ${s.p90.toFixed(0)}  p99 ${s.p99.toFixed(0)}  max ${s.max.toFixed(0)}`;
  console.log(`${res.request}  exit=${res.exit} stdout=${res.stdout_bytes}B`);
  console.log(`  compile once   cpu ${compile.cpu.toFixed(0)}  wall ${compile.wall.toFixed(0)} us`);
  console.log(`  GC over ${opt.n} requests: ${JSON.stringify(res.gc.count)}, ${res.gc.ms} ms`);
  for (const ph of ["inst", "run", "total"]) {
    console.log(`  ${ph.padEnd(6)} cpu  ${f(res[ph + "_cpu"])} us`);
    console.log(`  ${ph.padEnd(6)} wall ${f(res[ph + "_wall"])} us`);
  }
}
