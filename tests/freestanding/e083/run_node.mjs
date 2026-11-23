// E083 wasm32 leg -- the EDGE.  node run_node.mjs kern.wasm [--trap N]
//
// Written independently of drv/e083_drv.c (E067 s1 / E079's discipline: the
// legs share e083_kern.rb and NOTHING else -- if this file must do the same
// things in the same order to produce the same stream, that is the finding).
//
// What is deliberately ABSENT here, compared with E079's run_node.mjs: the
// SGD loop.  E079's JS walked grad -> sgd_step forty times; this file calls
// spinel_calibrate and the loop -- the extern call to the Enzyme adjoint
// included -- runs inside the wasm module.  The module's import section still
// names env.spinel_trap and nothing else: the adjoint was linked next to the
// kernel by wasm-ld, which is layer 3 supplying a declared extern the same
// way west does on the MCU legs.
import { readFileSync } from "node:fs";

const NROW = 64, NW = 5, NSTEP = 40;
const W0 = [0.2, -0.1, 0.3, 0.0, 0.5];

const wasmPath = process.argv[2];
if (!wasmPath) { console.error("usage: run_node.mjs <kern.wasm> [--trap N]"); process.exit(2); }
const trapIdx = process.argv.indexOf("--trap");
const trapExtra = trapIdx > 0 ? Number(process.argv[trapIdx + 1]) : null;

class SpinelTrap extends Error {
  constructor(code, a, b, detail) {
    super(detail); this.code = code; this.a = a; this.b = b;
  }
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
  { env: { spinel_trap: (c, a, b, d) => { throw new SpinelTrap(c, a, b, cstr(d)); } } });
memory = inst.exports.memory;
const K = inst.exports;

const align = (n, a) => (n + a - 1) & ~(a - 1);
let cursor = align(K.__heap_base?.value ?? 65536, 8);
const alloc = (n) => { const p = cursor; cursor = align(cursor + n * 8, 8); return p; };
const P_DATA = alloc(NROW * 5), P_ROW = alloc(NW), P_W = alloc(NW),
      P_W2 = alloc(NW), P_G = alloc(NW), P_G2 = alloc(NW), P_S = alloc(NW);
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
const flush = () => { process.stdout.write(out.join("\n") + "\n"); };

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

if (trapExtra !== null) {
  // The runtime half of D-10, on this leg: the same probe the C driver runs
  // under -DE083_TRAP.  The extern boundary's length check must fire BEFORE
  // the adjoint is entered, as a real env.spinel_trap call.
  say(`#trapprobe ${trapExtra}`);
  try {
    bitsLine("T", 0, -1,
             K.spinel_grad_probe(P_DATA, NROW * 5, P_W, P_G, NW, trapExtra));
    say("UNREACHED");
    flush();
    process.exit(1);
  } catch (e) {
    if (!(e instanceof SpinelTrap)) throw e;
    say(`E083\tTRAP\tcode=${e.code} a=${e.a} b=${e.b} detail=${e.detail ?? e.message}`);
    flush();
    process.exit(3);
  }
}

// ---- B. chunked replay: forty steps=1 calls ------------------------------
bitsLine("L", 0, -1, K.spinel_sq_hinge_loss(P_DATA, NROW * 5, P_W, NW));
for (let t = 1; t <= NSTEP; t++) {
  const ok = K.spinel_calibrate(P_DATA, NROW * 5, P_W, P_G, NW, 1, 0.1);
  say(`K ${t} ${ok}`);
  bitsLine("L", t, -1, K.spinel_sq_hinge_loss(P_DATA, NROW * 5, P_W, NW));
  for (let i = 0; i < NW; i++) bitsLine("S", t, i, f64(P_W, NW)[i]);
}

// ---- C. the whole loop in ONE kernel call --------------------------------
f64(P_W2, NW).set(W0);
{
  const ok = K.spinel_calibrate(P_DATA, NROW * 5, P_W2, P_G2, NW, NSTEP, 0.1);
  say(`B ${ok}`);
}
for (let i = 0; i < NW; i++) bitsLine("F", 0, i, f64(P_W2, NW)[i]);

// ---- D. the learning rates that are refused ------------------------------
const LR = [0.0, -0.1, 2.0, NaN, 0.1];
for (let k = 0; k < 5; k++) {
  f64(P_S, NW).set(f64(P_W, NW));
  const ok = K.spinel_calibrate(P_DATA, NROW * 5, P_S, P_G2, NW, NSTEP, LR[k]);
  say(`A ${k} ${ok}`);
  for (let i = 0; i < NW; i++) bitsLine("W", k, i, f64(P_S, NW)[i]);
}

// ---- E. the length-check control -----------------------------------------
f64(P_S, NW).set(f64(P_W, NW));
bitsLine("P", 0, -1,
         K.spinel_grad_probe(P_DATA, NROW * 5, P_S, P_G2, NW, 0));

say("#final " + [...f64(P_W, NW)].map(bitsOf).join(" "));
say("#done");
flush();
