// tests/core-bitwise/status/words.mjs -- decision 0042 stage 4: the 32-bit
// status kernels of status/src/words.rb, built for wasm32 and linked into one
// module. argv[3] is `words` or `checksums`, as for status/words.c.
//
//   words      reads rows "op A B" on stdin and prints "op A B R": R is the
//              result, `fail` for ARITHMETIC (2) with the result word
//              untouched, and anything else is printed as it is so that it
//              differs.
//   checksums  prints "name input R" for FNV-1a 32 and CRC-32 over the
//              published check strings, iterating the kernels' steps.
import { readFileSync } from "node:fs";
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), {});
const k = instance.exports;
// The result word: the start of the heap, which nothing else in the module
// uses. The link gives the memory room past it.
const at = k.__heap_base.value;
const word = new Int32Array(k.memory.buffer, at, 1);
const SENTINEL = -123456789;
const bytes = (s) => [...Buffer.from(s, "latin1")];
// A step that does not answer OK ends the run: the checksum would be wrong.
const step = (name, a, b) => {
  const st = k[`spinel_core_${name}`](a, b, at);
  if (st !== 0) { console.log(`status ${st}`); process.exit(1); }
  return word[0];
};
if (process.argv[3] === "checksums") {
  for (const s of ["a", "foobar"]) {
    let h = step("fnv32_seed", 0, 0);
    for (const b of bytes(s)) h = step("fnv32_step", h, b);
    console.log(`fnv32 ${s} ${h}`);
  }
  let c = -1;
  for (const b of bytes("123456789")) c = step("crc32_step", c, b);
  console.log(`crc32 123456789 ${~c}`);
} else {
  for (const line of readFileSync(0, "utf8").split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f.length !== 3) continue;
    const fn = k[`spinel_core_w_${f[0]}`];
    let r;
    if (typeof fn !== "function") {
      r = "unknown";
    } else {
      word[0] = SENTINEL;
      const st = fn(Number(f[1]), Number(f[2]), at);
      if (st === 0) r = `${word[0]}`;
      else if (st === 2 && word[0] === SENTINEL) r = "fail";
      else r = `status ${st} ${word[0] === SENTINEL ? "untouched" : "TOUCHED"}`;
    }
    console.log(`${f[0]} ${f[1]} ${f[2]} ${r}`);
  }
}
