// E084 wasm32 leg -- the EDGE.  node run_node.mjs kern.wasm [--trap N]
//
// Written independently of drv/e084_drv.c (E067 s1 / E079's discipline: the
// legs share e084_kern.rb and NOTHING else -- if this file must do the same
// things in the same order to produce the same stream, that is the finding).
//
// What is deliberately ABSENT here, compared with E083's run_node.mjs: even
// the SGD loop's step chunking is gone as a driver concern -- this file calls
// spinel_newton_calibrate and a whole second-order optimisation (outer Newton
// iterations, an inner CG solve through the Hessian-vector extern, a damped
// line search) runs inside the wasm module.  The module's import section
// still names env.spinel_trap and nothing else: BOTH adjoint products were
// linked next to the kernel by wasm-ld.
import { readFileSync } from "node:fs";

const NROW = 64, NW = 5, NITER = 12;
const W0 = [0.2, -0.1, 0.3, 0.0, 0.5];
const SYM_U = [1.0, 0.5, -0.25, 2.0, -1.0];
const SYM_V = [-0.5, 1.0, 0.75, -1.5, 0.25];

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
      P_W2 = alloc(NW), P_G = alloc(NW), P_GS = alloc(NW), P_HV = alloc(NW),
      P_P = alloc(NW), P_R = alloc(NW), P_D = alloc(NW), P_Y = alloc(NW),
      P_DIR = alloc(NW), P_S = alloc(NW);
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
say(`#iters ${NITER}`);
say(`#nw ${NW}`);

// ---- A. the samples ------------------------------------------------------
for (let r = 0; r < NROW; r++) {
  K.spinel_gen_row(P_ROW, 5, r);
  f64(P_DATA, NROW * 5).set(f64(P_ROW, 5), r * 5);
}
f64(P_W, NW).set(W0);

if (trapExtra !== null) {
  // The runtime half of D-10, against the NEW extern, on this leg.
  say(`#trapprobe ${trapExtra}`);
  f64(P_DIR, NW).set([1, 0, 0, 0, 0]);
  try {
    bitsLine("T", 0, -1,
             K.spinel_hvp_probe(P_DATA, NROW * 5, P_W, P_DIR, P_GS, P_HV,
                                NW, trapExtra));
    say("UNREACHED");
    flush();
    process.exit(1);
  } catch (e) {
    if (!(e instanceof SpinelTrap)) throw e;
    say(`E084\tTRAP\tcode=${e.code} a=${e.a} b=${e.b} detail=${e.detail ?? e.message}`);
    flush();
    process.exit(3);
  }
}

// ---- B. the HVP unit block at W0 -----------------------------------------
for (let j = 0; j < NW; j++) {
  f64(P_DIR, NW).set(W0.map((_, i) => (i === j ? 1.0 : 0.0)));
  bitsLine("Vr", j, -1,
           K.spinel_hvp_sq_hinge_loss(P_DATA, NROW * 5, P_W, P_DIR, P_GS, P_HV, NW));
  for (let i = 0; i < NW; i++) bitsLine("V", j, i, f64(P_HV, NW)[i]);
}
for (let i = 0; i < NW; i++) bitsLine("G0", i, -1, f64(P_GS, NW)[i]);
f64(P_DIR, NW).set(SYM_U);
K.spinel_hvp_sq_hinge_loss(P_DATA, NROW * 5, P_W, P_DIR, P_GS, P_HV, NW);
for (let i = 0; i < NW; i++) bitsLine("U", i, -1, f64(P_HV, NW)[i]);
f64(P_DIR, NW).set(SYM_V);
K.spinel_hvp_sq_hinge_loss(P_DATA, NROW * 5, P_W, P_DIR, P_GS, P_HV, NW);
for (let i = 0; i < NW; i++) bitsLine("Z", i, -1, f64(P_HV, NW)[i]);

// ---- C. chunked replay: twelve iters=1 calls -----------------------------
bitsLine("L", 0, -1, K.spinel_sq_hinge_loss(P_DATA, NROW * 5, P_W, NW));
bitsLine("N", 0, -1, K.spinel_grad_norm2(P_DATA, NROW * 5, P_W, P_GS, NW));
for (let t = 1; t <= NITER; t++) {
  const ok = K.spinel_newton_calibrate(P_DATA, NROW * 5, P_W, P_G, P_GS, P_HV,
                                       P_P, P_R, P_D, P_Y, NW, 1, 1.0e-14);
  say(`K ${t} ${ok}`);
  bitsLine("L", t, -1, K.spinel_sq_hinge_loss(P_DATA, NROW * 5, P_W, NW));
  bitsLine("N", t, -1, K.spinel_grad_norm2(P_DATA, NROW * 5, P_W, P_GS, NW));
  for (let i = 0; i < NW; i++) bitsLine("S", t, i, f64(P_W, NW)[i]);
}

// ---- D. the whole Newton run in ONE kernel call --------------------------
f64(P_W2, NW).set(W0);
{
  const ok = K.spinel_newton_calibrate(P_DATA, NROW * 5, P_W2, P_G, P_GS, P_HV,
                                       P_P, P_R, P_D, P_Y, NW, NITER, 1.0e-14);
  say(`B ${ok}`);
}
for (let i = 0; i < NW; i++) bitsLine("F", 0, i, f64(P_W2, NW)[i]);

// ---- E. the refused iters/gtol2 ------------------------------------------
for (let k = 0; k < 5; k++) {
  // refusals from the converged weights; the k=4 control from W0, so that
  // acceptance is observable (rc == B, W 4 rows == F rows)
  if (k === 4) f64(P_S, NW).set(W0); else f64(P_S, NW).set(f64(P_W, NW));
  const iters = k === 0 ? 0 : k === 1 ? -3 : NITER;
  const gtol2 = k === 2 ? -1.0 : k === 3 ? NaN : 1.0e-14;
  const ok = K.spinel_newton_calibrate(P_DATA, NROW * 5, P_S, P_G, P_GS, P_HV,
                                       P_P, P_R, P_D, P_Y, NW, iters, gtol2);
  say(`A ${k} ${ok}`);
  for (let i = 0; i < NW; i++) bitsLine("W", k, i, f64(P_S, NW)[i]);
}

// ---- F. the hvp length-check control -------------------------------------
f64(P_S, NW).set(f64(P_W, NW));
f64(P_DIR, NW).set([1, 0, 0, 0, 0]);
bitsLine("P", 0, -1,
         K.spinel_hvp_probe(P_DATA, NROW * 5, P_S, P_DIR, P_GS, P_HV, NW, 0));

say("#final " + [...f64(P_W, NW)].map(bitsOf).join(" "));
say("#done");
flush();
