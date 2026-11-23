// E079 wasm32 leg -- the EDGE.  node run_node.mjs kern.wasm [--shipped hex...]
//
// Written independently of drv/e079_drv.c, on purpose: E067 s1 makes the point
// that if the four legs' drivers came out of one generator, "the four legs
// agree" would be a much weaker sentence.  What is shared is e079_kern.rb and
// nothing else.  This file must produce the same stream by doing the same
// things in the same order, and if it does not, that is a finding.
//
// The buffers live above __heap_base (E063 / E077): the CALLER owns memory,
// so the edge puts the training set wherever it likes and hands the kernel
// (ptr, len).  There is no allocator in the module to ask.
import { readFileSync } from "node:fs";

const NROW = 64, NW = 5, NSTEP = 40;
const W0 = [0.2, -0.1, 0.3, 0.0, 0.5];
const PROBE = [[0.2, -0.1, 0.3, 0.0, 0.5],
               [0.0, 0.0, 0.0, 0.0, 0.0],
               [1.5, 0.8, -1.2, 0.4, -0.3]];

const wasmPath = process.argv[2];
if (!wasmPath) { console.error("usage: run_node.mjs <kern.wasm>"); process.exit(2); }

class SpinelTrap extends Error {
  constructor(code, detail) { super(detail); this.code = code; }
}
let memory = null;
const cstr = (p) => {
  if (!memory || !p) return "";
  const u8 = new Uint8Array(memory.buffer);
  let e = p; while (u8[e]) e++;
  return new TextDecoder().decode(u8.subarray(p, e));
};
const inst = new WebAssembly.Instance(
  new WebAssembly.Module(readFileSync(wasmPath)),
  { env: { spinel_trap: (c, a, b, d) => { throw new SpinelTrap(c, cstr(d)); } } });
memory = inst.exports.memory;
const K = inst.exports;

const align = (n, a) => (n + a - 1) & ~(a - 1);
let cursor = align(K.__heap_base?.value ?? 65536, 8);
const alloc = (n) => { const p = cursor; cursor = align(cursor + n * 8, 8); return p; };
const P_DATA = alloc(NROW * 5), P_ROW = alloc(NW), P_W = alloc(NW),
      P_G = alloc(NW), P_S = alloc(NW);
{
  const have = memory.buffer.byteLength;
  if (cursor > have) memory.grow(Math.ceil((cursor - have) / 65536));
}
// memory.buffer is re-read on every view: memory.grow detaches the old one.
const f64 = (p, n) => new Float64Array(memory.buffer, p, n);
const bitsOf = (x) => {
  const b = new ArrayBuffer(8);
  new Float64Array(b)[0] = x;
  return new DataView(b).getBigUint64(0, true).toString(16).padStart(16, "0");
};
const out = [];
const say = (s) => out.push(s);
const bitsLine = (tag, a, b, d) =>
  say(b < 0 ? `${tag} ${a} ${bitsOf(d)}` : `${tag} ${a} ${b} ${bitsOf(d)}`);

say(`#kern ${K.spinel_kern_version()}`);
say(`#rows ${NROW}`);
say(`#steps ${NSTEP}`);
say(`#nw ${NW}`);

// ---- A. the samples ------------------------------------------------------
for (let r = 0; r < NROW; r++) {
  K.spinel_gen_row(P_ROW, 5, r);
  f64(P_DATA, NROW * 5).set(f64(P_ROW, 5), r * 5);
}
f64(P_W, NW).set(W0);

// ---- B. phase 0 ----------------------------------------------------------
const confusion = (wp) => {
  const c = [0, 0, 0, 0];
  const v = [];
  for (let r = 0; r < NROW; r++) {
    const o = K.spinel_outcome(P_DATA + r * 5 * 8, 5, wp, NW);
    v.push(o); c[o]++;
  }
  return [v, c];
};
{
  const [v, c] = confusion(P_W);
  v.forEach((o, r) => say(`V0 ${r} ${o}`));
  say(`C0 ${c.join(" ")}`);
}

// ---- C. the gradient at three probe points -------------------------------
for (let p = 0; p < 3; p++) {
  f64(P_S, NW).set(PROBE[p]);
  const L = K.spinel_grad_sq_hinge_loss(P_DATA, NROW * 5, P_S, P_G, NW);
  bitsLine("P", p, -1, L);
  const g = f64(P_G, NW);
  for (let i = 0; i < NW; i++) bitsLine("G", p, i, g[i]);
}

// ---- D. the calibration loop (the edge's actual job) ---------------------
bitsLine("L", 0, -1, K.spinel_sq_hinge_loss(P_DATA, NROW * 5, P_W, NW));
for (let t = 1; t <= NSTEP; t++) {
  K.spinel_grad_sq_hinge_loss(P_DATA, NROW * 5, P_W, P_G, NW);
  const ok = K.spinel_sgd_step(P_W, P_G, NW, 0.1);
  say(`K ${t} ${ok}`);
  bitsLine("L", t, -1, K.spinel_sq_hinge_loss(P_DATA, NROW * 5, P_W, NW));
  const w = f64(P_W, NW);
  for (let i = 0; i < NW; i++) bitsLine("S", t, i, w[i]);
}

// ---- E. the learning rates that are refused ------------------------------
const zero = 0.0;
const lrCase = (i) => [zero, -0.1, 2.0, zero / zero, 0.1][i];
for (let k = 0; k < 5; k++) {
  f64(P_S, NW).set(f64(P_W, NW));
  K.spinel_grad_sq_hinge_loss(P_DATA, NROW * 5, P_S, P_G, NW);
  const ok = K.spinel_sgd_step(P_S, P_G, NW, lrCase(k));
  say(`A ${k} ${ok}`);
  const s = f64(P_S, NW);
  for (let i = 0; i < NW; i++) bitsLine("W", k, i, s[i]);
}

// ---- F. phase 1 ----------------------------------------------------------
{
  const [v, c] = confusion(P_W);
  v.forEach((o, r) => say(`V1 ${r} ${o}`));
  say(`C1 ${c.join(" ")}`);
}
say("#final " + Array.from(f64(P_W, NW)).map(bitsOf).join(" "));
say("#done");
process.stdout.write(out.join("\n") + "\n");
