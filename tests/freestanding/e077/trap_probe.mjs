// E077: the RUN-TIME half of "what a buffer boundary refuses".
//
// The compile-time half is run_reject.sh: a write to an `:in` buffer, a `:len`
// that does not follow a buffer, a reassigned length -- shapes the generator
// can see in the text and refuses before anything is built.  The shapes here
// only exist once a CALLER exists, so they are checked by calling.
//
// Each row is `verdict<TAB>id<TAB>want<TAB>got<TAB>note`.  The `want` column is
// a contract written before the run, exactly as expect.tsv is (E040's rule: an
// unexpected PASS is as much a failure as an unexpected FAIL).
//
// Why the Worker and not the MCU for these: the caller is the thing being
// broken, and on the MCU the caller is C, where "pass a NULL where the header
// says `const uint8_t *`" is a thing the C compiler will happily do but that a
// generated driver would have to be written to do on purpose.  In JS the caller
// is data (cases.json), so a broken caller is a broken row.  The MCU side gets
// the same treatment for the one shape a compiled driver reaches naturally --
// the off-by-one -- through the panic build.
import { readFileSync } from "node:fs";

const wasmPath = process.argv[2];
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
const inst = new WebAssembly.Instance(new WebAssembly.Module(readFileSync(wasmPath)), {
  env: { spinel_trap: (c, a, b, d) => { throw new SpinelTrap(c, cstr(d)); } },
});
memory = inst.exports.memory;
const K = inst.exports;

const align = (n, a) => (n + a - 1) & ~(a - 1);
const base = align(K.__heap_base.value, 8);
const i32 = new Int32Array(memory.buffer, base, 64);
i32.set([1, 2, 3, 4, 5, 6, 7, 8]);
// A second i32 fixture whose values do NOT fit a u8 element, for narrow_elem.
const bigbase = base + 1536;
new Int32Array(memory.buffer, bigbase, 8).set([1, 2, 300, 4, 5, 6, 7, 8]);
const u8base = base + 512;
new Uint8Array(memory.buffer, u8base, 8).set([1, 2, 3, 4, 5, 6, 7, 8]);
const f32base = base + 1024;
new Float32Array(memory.buffer, f32base, 8).set([1, 2, 3, 4, 5, 6, 7, 8]);

// id, want, thunk
const PROBES = [
  ["null_in_nonzero", "trap:5", () => K.spinel_adler32(0, 5),
   "a NULL :in buffer with a non-zero length"],
  ["null_out_nonzero", "trap:5", () => K.spinel_fill(0, 4, 0),
   "a NULL :out buffer with a non-zero length"],
  ["null_len_zero", "ok", () => K.spinel_adler32(0, 0),
   "(NULL, 0) is an empty range, not a fault: refusing it would make every " +
   "caller invent a dummy address"],
  ["neg_len", "trap:6", () => K.spinel_adler32(u8base, -1),
   "a negative :len"],
  ["neg_len_out", "trap:6", () => K.spinel_fill(base, -3, 0),
   "a negative :len on an :out buffer"],
  ["min_len", "trap:6", () => K.spinel_adler32(u8base, -2147483648),
   "INT32_MIN as a length -- the sign check, not a magnitude heuristic"],
  ["offby1", "trap:4", () => K.spinel_sum_offby1(base, 8),
   "the kernel indexes one past the length it was given"],
  ["bad_field", "trap:4", () => K.spinel_recsum(base, 9, 3),
   "a record field the layout does not have (the runtime-index check, the one " +
   "the optimiser cannot fold)"],
  ["narrow_elem", "trap:3", () => K.spinel_pack8(bigbase, u8base, 8),
   "a value that does not fit the :u8 element (the return boundary's rule, " +
   "reused at the element)"],
  ["zero_len_ok", "ok", () => K.spinel_adler32(u8base, 0),
   "a zero length on a real buffer is not a fault"],
  ["unchecked_inbounds", "ok", () => K.spinel_sum_unchecked(base, 8),
   "bounds: :unchecked still honours the CALL contract (this one is in bounds)"],
  ["unchecked_neg_len", "trap:6", () => K.spinel_sum_unchecked(base, -1),
   "bounds: :unchecked removes the per-INDEX check only -- the entry-side " +
   "checks are about the call, not the index (E077 D-5)"],
  ["float_no_trap", "ok", () => K.spinel_fmix(1e38, 1e308),
   "float overflow is +inf, not a trap (D-4: IEEE is Ruby's answer too)"],
  ["float_div0_no_trap", "ok", () => K.spinel_fmean(f32base, 0),
   "0.0/0 is NaN, not a divide-by-zero trap"],
];

const rows = [];
let bad = 0;
for (const [id, want, fn, note] of PROBES) {
  let got;
  try {
    const v = fn();
    got = "ok";
    if (typeof v === "number" && !Number.isFinite(v)) got = "ok";
  } catch (e) {
    got = e instanceof SpinelTrap ? `trap:${e.code}` : `wasmtrap:${e.constructor.name}`;
  }
  const verdict = got === want ? "PASS" : "FAIL";
  if (verdict === "FAIL") bad++;
  rows.push([verdict, id, want, got, note].join("\t"));
}
process.stdout.write("verdict\tid\twant\tgot\tnote\n" + rows.join("\n") + "\n");
if (bad) process.exitCode = 1;
