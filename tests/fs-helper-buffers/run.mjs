// tests/fs-helper-buffers/run.mjs -- the wasm32 module of k.rb (a 32-bit
// body) under node. Each row fills its buffers in the module's memory, calls
// one entry and prints what comes back, as drive.c does for the 64-bit build.
// The trap hook throws, which leaves the kernel; the row prints
// "trap CODE A B" (for code 4, the index and the length) and the next row runs.
import { readFileSync } from "node:fs";
class Trap extends Error {
  constructor(code, a, b) { super(`trap ${code}`); this.code = code; this.a = a; this.b = b; }
}
const env = { spinel_trap(code, a, b) { throw new Trap(code, a, b); } };
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), { env });
const k = instance.exports;
// A page of its own for the buffers, so nothing the module keeps is touched.
const base = k.memory.grow(1) * 65536;
const A = base, B = base + 1024;
const i32 = (at, n) => new Int32Array(k.memory.buffer, at, n);
const f32 = (at, n) => new Float32Array(k.memory.buffer, at, n);
const call = (f) => {
  try { return `${f()}`; } catch (e) {
    if (!(e instanceof Trap)) throw e;
    return `trap ${e.code} ${e.a} ${e.b}`;
  }
};
const show = (xs) => Array.from(xs).join(" ");
const out = [];

f32(A, 4).fill(9);
out.push(`fill_all ${call(() => k.spinel_fill_all(A, 4))} ${show(f32(A, 4))}`);

i32(A, 5).fill(-1);
out.push(`lend_on ${call(() => k.spinel_lend_on(A, 5))} ${show(i32(A, 5))}`);

i32(A, 3).set([10, 20, 30]); i32(B, 2).set([7, 8]);
out.push(`two ${call(() => k.spinel_two(A, 3, B, 2))} ${show(i32(A, 3))} ${show(i32(B, 2))}`);

for (const [i, j] of [[2, 1], [3, 0], [0, 2]]) {
  i32(A, 3).set([10, 20, 30]); i32(B, 2).set([7, 8]);
  out.push(`past ${i} ${j} ${call(() => k.spinel_past(A, 3, B, 2, i, j))} a ${show(i32(A, 3))} b ${show(i32(B, 2))}`);
}

i32(A, 3).set([3, 4, 5]);
out.push(`sum_in ${call(() => k.spinel_sum_in(A, 3))}`);

i32(A, 3).set([1, 1, 1]); i32(B, 3).fill(0);
out.push(`each_lent ${call(() => k.spinel_each_lent(A, B, 3))} ${show(i32(B, 3))}`);

for (const extra of [0, 1]) {
  i32(A, 3).fill(0);
  out.push(`via_entry ${extra} ${call(() => k.spinel_via_entry(A, 3, extra))} ${show(i32(A, 3))}`);
}

for (const i of [1, 3]) {
  i32(A, 3).fill(0);
  out.push(`checked_put ${i} ${call(() => k.spinel_checked_put(A, 3, i))} ${show(i32(A, 3))}`);
}
i32(A, 1).set([5]); i32(B, 1).set([0]); i32(B + 512, 1).set([9]);
out.push(`modes ${call(() => k.spinel_modes(A, B, B + 512, 1))} ${show(i32(B, 1))} ${show(i32(B + 512, 1))}`);

// A 3-element buffer with a canary after it: an unchecked store at index 3
// would overwrite the 91.
for (const i of [1, 3]) {
  i32(A, 4).set([0, 0, 0, 91]);
  out.push(`chain ${i} ${call(() => k.spinel_chain(A, 3, i))} ${show(i32(A, 4))}`);
}
for (const i of [1, 3]) {
  i32(A, 4).set([0, 0, 0, 91]);
  out.push(`chain2 ${i} ${call(() => k.spinel_chain2(A, 3, i))} ${show(i32(A, 4))}`);
}
console.log(out.join("\n"));
