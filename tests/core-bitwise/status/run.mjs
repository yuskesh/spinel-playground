// tests/core-bitwise/status/run.mjs -- the 32-bit status kernels of
// status/src/shifts.rb, built for wasm32 and linked into one module. Reads
// rows "shl A N" or "shr A N" on stdin and prints "op A N R" as status/drive.c
// does: R is the result, `fail` for ARITHMETIC (2) with the result word
// untouched, and anything else is printed as it is so that it differs.
import { readFileSync } from "node:fs";
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const k = instance.exports;
// The result word: the start of the heap, which nothing else in the module
// uses. The link gives the memory room past it.
const at = k.__heap_base.value;
const word = new Int32Array(k.memory.buffer, at, 1);
const SENTINEL = -123456789;
for (const line of readFileSync(0, "utf8").split("\n")) {
  const f = line.trim().split(/\s+/);
  if (f.length !== 3) continue;
  const [op, a, n] = [f[0], Number(f[1]), Number(f[2])];
  word[0] = SENTINEL;
  const st = (op === "shl" ? k.spinel_core_shl : k.spinel_core_shr)(a, n, at);
  let r;
  if (st === 0) r = `${word[0]}`;
  else if (st === 2 && word[0] === SENTINEL) r = "fail";
  else r = `status ${st} ${word[0] === SENTINEL ? "untouched" : "TOUCHED"}`;
  console.log(`${op} ${f[1]} ${f[2]} ${r}`);
}
