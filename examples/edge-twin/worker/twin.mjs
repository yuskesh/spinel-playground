// edge-twin -- the edge half of the twin, as a plain module.
//
// Everything in this file is about the AUDIT LOG: how to produce one, how to
// parse one, and how to re-derive it from the samples alone.  Not one line of
// it computes a mean, a variance, a verdict or a digest -- those come out of
// `kern.wasm`, which is the same kernel the microcontroller is running.  That
// separation is the point of the example: the logic that must be bit-identical
// on both sides lives in Ruby, once, and everything that is merely edge-shaped
// (parsing, HTTP, JSON, error policy) lives here in JavaScript where mutable
// data structures and strings are free.
//
// The same module backs three runners, which is why it takes an instantiated
// module rather than making one:
//
//   node   examples/edge-twin/run_node.mjs   (the reference producer)
//   workerd examples/edge-twin/worker/index.mjs
//   the test harness in docs/experiments/results/E067/
//
// TYPES AT THE BOUNDARY.  WebAssembly i64 is BigInt in JS and i32 is Number;
// the generated header (spinel_freestanding.h) is what says which is which, and
// build.sh turns it into sig.json so nothing here is transcribed.  mean_q and
// var_q are therefore BigInt everywhere below, and printing them with String()
// gives the same decimal digits `printk("%lld")` gives on the device.

export const LOG_MAGIC = "#edge-twin";
export const LOG_FORMAT = 1;

// A trap that came out of the kernel through the one import it has.  On the MCU
// this same call is `k_panic()`; here it is a JS exception that the caller
// turns into a 422.  P003 decision record D-2: the module decides that a fault
// happened, the platform decides what a fault means.
export class Trap extends Error {
  constructor(code, a, b, detail) {
    super(`trap code=${code} ${detail}`);
    this.name = "Trap";
    Object.assign(this, { code, a, b, detail });
  }
}

export class AuditError extends Error {
  constructor(status, message) {
    super(message);
    this.name = "AuditError";
    this.status = status;
  }
}

/** Instantiate kern.wasm and return its exports.  The only import in the whole
 *  module is `env.spinel_trap` (E063 §4), so this is the entire host surface. */
export function instantiate(module) {
  let memory = null;
  const inst = new WebAssembly.Instance(module, {
    env: {
      spinel_trap(code, a, b, detail) {
        // `detail` is a pointer into the module's linear memory: the generator
        // put a NUL-terminated string there naming the method and the operation.
        const u8 = new Uint8Array(memory.buffer);
        let end = detail;
        while (end < u8.length && u8[end] !== 0) end++;
        throw new Trap(code, a, b, new TextDecoder().decode(u8.subarray(detail, end)));
      },
    },
  });
  memory = inst.exports.memory;
  return inst.exports;
}

/** The run parameters a log is self-describing about.  A replay uses the ones
 *  in the log, never its own defaults -- otherwise "the edge agrees" would only
 *  mean "the edge was configured the same way today". */
export const DEFAULTS = { seed: 1, k: 3, mean0: 25000, n: 1024, nbound: 24 };

/** The state machine, shared by the producer and the replayer so that they
 *  cannot drift.  Every field is what the kernel returned; nothing is derived
 *  here. */
function step(K, st, x, k) {
  const v = K.spinel_verdict(st.mean_q, st.var_q, x, k);
  // Both digest halves read the OLD pair (kern.rb §4), so the order in which
  // they are called is not observable.
  const hi = K.spinel_digest_hi(st.hi, st.lo, x, v);
  const lo = K.spinel_digest_lo(st.hi, st.lo, x, v);
  // ewma_var reads the OLD mean (kern.rb §2), which is why it is computed
  // before mean_q is overwritten.
  const var_q = K.spinel_ewma_var(st.var_q, st.mean_q, x);
  const mean_q = K.spinel_ewma_mean(st.mean_q, x);
  st.hi = hi;
  st.lo = lo;
  st.mean_q = mean_q;
  st.var_q = var_q;
  return v;
}

function initialState(K, p) {
  return { mean_q: K.spinel_seed_mean(p.mean0), var_q: 0n, hi: 0, lo: 0 };
}

/** Produce an audit log: the PRNG stream followed by the boundary tail. */
export function produce(K, params = {}) {
  const p = { ...DEFAULTS, ...params };
  const st = initialState(K, p);
  const rows = [];
  let s = BigInt(p.seed);
  for (let i = 0; i < p.n; i++) {
    s = K.spinel_prng_next(s);
    const x = K.spinel_sample_of(s);
    rows.push(rowOf(K, st, i, x, p.k));
  }
  for (let j = 0; j < p.nbound; j++) {
    const x = K.spinel_bound_sample(j);
    rows.push(rowOf(K, st, p.n + j, x, p.k));
  }
  return { params: { ...p, kern_version: K.spinel_kern_version() }, rows, final: tally(rows) };
}

function rowOf(K, st, idx, x, k) {
  const v = step(K, st, x, k);
  return { idx, x, v, mean_q: st.mean_q, var_q: st.var_q, hi: st.hi, lo: st.lo };
}

function counts(rows) {
  const c = [0, 0, 0];
  for (const r of rows) c[r.v]++;
  return { ok: c[0], warn: c[1], alarm: c[2] };
}

function tally(rows) {
  const last = rows[rows.length - 1];
  return { hi: last ? last.hi : 0, lo: last ? last.lo : 0, ...counts(rows) };
}

/** The wire format.  Tab-separated, one row per sample, so that a
 *  microcontroller can emit it with printk and a shell can diff it. */
export function formatLog(log) {
  const p = log.params;
  const out = [
    [LOG_MAGIC, LOG_FORMAT, p.kern_version, p.seed, p.k, p.mean0, p.n, p.nbound].join("\t"),
  ];
  for (const r of log.rows) {
    out.push([r.idx, r.x, r.v, r.mean_q, r.var_q, r.hi, r.lo].join("\t"));
  }
  const f = log.final;
  out.push(["#final", f.hi, f.lo, f.ok, f.warn, f.alarm].join("\t"));
  return out.join("\n") + "\n";
}

export function parseLog(text) {
  const lines = text.split("\n").map((l) => l.replace(/\r$/, "")).filter((l) => l !== "");
  if (!lines.length || !lines[0].startsWith(LOG_MAGIC)) {
    throw new AuditError(400, "not an edge-twin audit log (no #edge-twin header)");
  }
  const h = lines[0].split("\t");
  if (Number(h[1]) !== LOG_FORMAT) {
    throw new AuditError(400, `unknown log format ${h[1]}`);
  }
  const params = {
    kern_version: Number(h[2]), seed: Number(h[3]), k: Number(h[4]),
    mean0: Number(h[5]), n: Number(h[6]), nbound: Number(h[7]),
  };
  const rows = [];
  let final = null;
  for (const line of lines.slice(1)) {
    if (line.startsWith("#final")) {
      const f = line.split("\t");
      final = { hi: Number(f[1]), lo: Number(f[2]), ok: Number(f[3]), warn: Number(f[4]),
                alarm: Number(f[5]) };
      continue;
    }
    if (line.startsWith("#")) continue;
    const c = line.split("\t");
    if (c.length !== 7) throw new AuditError(400, `row ${rows.length}: expected 7 columns`);
    if (!c.every((f) => /^-?\d+$/.test(f))) {
      throw new AuditError(400, `row ${rows.length}: every column has to be an integer`);
    }
    rows.push({ idx: Number(c[0]), x: Number(c[1]), v: Number(c[2]),
                mean_q: BigInt(c[3]), var_q: BigInt(c[4]), hi: Number(c[5]), lo: Number(c[6]) });
  }
  if (!final) throw new AuditError(400, "the log has no #final trailer (truncated?)");
  return { params, rows, final };
}

/** THE PRODUCT.  Re-derive every verdict and every digest from the SAMPLES in
 *  the log, using the same kernel the device used, and report the first row on
 *  which the device's claim and the edge's recomputation disagree.
 *
 *  Note what is and is not trusted.  Trusted: the sample column, because that is
 *  the measurement and an audit cannot invent it.  Recomputed: everything else.
 *  So a rewritten sample is caught not by the sample itself but by the digest
 *  chain, whose value at row i depends on every row before it -- which is also
 *  what catches a deleted or reordered row. */
export function audit(K, log) {
  const p = log.params;
  if (p.kern_version !== K.spinel_kern_version()) {
    throw new AuditError(409,
      `kernel version mismatch: the log was written by ${p.kern_version}, ` +
      `this worker runs ${K.spinel_kern_version()}`);
  }
  const st = initialState(K, p);
  const findings = [];
  // The replay always runs to the END even once enough findings have been
  // collected: `computed_final` has to be the digest of the whole log, not of
  // the prefix that happened to fit on one screen.  Only the REPORTING stops.
  const note = (f) => { if (findings.length < 8) findings.push(f); };
  for (let i = 0; i < log.rows.length; i++) {
    const r = log.rows[i];
    const v = step(K, st, r.x, p.k);
    if (r.idx !== i) note({ row: i, field: "idx", claimed: r.idx, computed: i });
    if (r.v !== v) note({ row: i, field: "verdict", claimed: r.v, computed: v });
    if (r.mean_q !== st.mean_q) {
      note({ row: i, field: "mean_q", claimed: String(r.mean_q), computed: String(st.mean_q) });
    }
    if (r.var_q !== st.var_q) {
      note({ row: i, field: "var_q", claimed: String(r.var_q), computed: String(st.var_q) });
    }
    if (r.hi !== st.hi) note({ row: i, field: "digest_hi", claimed: r.hi, computed: st.hi });
    if (r.lo !== st.lo) note({ row: i, field: "digest_lo", claimed: r.lo, computed: st.lo });
  }
  const c = counts(log.rows);
  const rowsExpected = p.n + p.nbound;
  if (log.rows.length !== rowsExpected) {
    note({ row: -1, field: "row_count", claimed: log.rows.length, computed: rowsExpected });
  }
  if (log.final.hi !== st.hi || log.final.lo !== st.lo) {
    note({ row: -1, field: "final_digest",
                    claimed: `${log.final.hi}:${log.final.lo}`,
                    computed: `${st.hi}:${st.lo}` });
  }
  return {
    verdict: findings.length === 0 ? "ACCEPT" : "REJECT",
    rows: log.rows.length,
    kern_version: p.kern_version,
    claimed_final: `${log.final.hi}:${log.final.lo}`,
    computed_final: `${st.hi}:${st.lo}`,
    counts: c,
    findings,
  };
}
