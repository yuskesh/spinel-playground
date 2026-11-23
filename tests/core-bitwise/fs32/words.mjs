// tests/core-bitwise/fs32/words.mjs -- decision 0042 stage 4: the intrinsics
// of fs32/k.rb at 32 bits, as fs/words.c does them at 64. argv[3] is `words`
// or `checksums`.
//
//   words      reads rows "op A B" on stdin and prints "op A B R": R is the
//              result, or `fail` when the trap hook is called with the
//              intrinsic code 8. The hook throws, which leaves the kernel,
//              and the next row runs.
//   checksums  prints "name input R" for FNV-1a 32 and CRC-32 over the
//              published check strings, iterating the kernels' steps.
import { readFileSync } from "node:fs";
class Trap extends Error {
  constructor(code) { super(`trap ${code}`); this.code = code; }
}
const env = { spinel_trap(code) { throw new Trap(code); } };
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), { env });
const k = instance.exports;
const bytes = (s) => [...Buffer.from(s, "latin1")];
if (process.argv[3] === "checksums") {
  for (const s of ["a", "foobar"]) {
    let h = k.spinel_fnv32_seed();
    for (const b of bytes(s)) h = k.spinel_fnv32_step(h, b);
    console.log(`fnv32 ${s} ${h}`);
  }
  let c = -1;
  for (const b of bytes("123456789")) c = k.spinel_crc32_step(c, b);
  console.log(`crc32 123456789 ${~c}`);
} else {
  for (const line of readFileSync(0, "utf8").split("\n")) {
    const f = line.trim().split(/\s+/);
    if (f.length !== 3) continue;
    const fn = k[`spinel_w_${f[0]}`];
    let r;
    if (typeof fn !== "function") {
      r = "unknown";
    } else {
      try {
        r = `${fn(Number(f[1]), Number(f[2]))}`;
      } catch (e) {
        if (!(e instanceof Trap)) throw e;
        r = e.code === 8 ? "fail" : `trap ${e.code}`;
      }
    }
    console.log(`${f[0]} ${f[1]} ${f[2]} ${r}`);
  }
}
