// tests/core-bitwise/fs32/shifts.mjs -- the shifts of fs32/k.rb at 32 bits,
// as fs/shifts.c does them at 64. argv[3] is `trap` or `wrap`. Reads rows
// "shl A N" or "shr A N" on stdin and prints "op A N R": R is the result, or
// `fail` when the trap hook is called with the overflow code 1. The hook
// throws, which leaves the kernel, and the next row runs.
import { readFileSync } from "node:fs";
class Trap extends Error {
  constructor(code) { super(`trap ${code}`); this.code = code; }
}
const env = { spinel_trap(code) { throw new Trap(code); } };
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), { env });
const k = instance.exports;
const wrap = process.argv[3] === "wrap";
for (const line of readFileSync(0, "utf8").split("\n")) {
  const f = line.trim().split(/\s+/);
  if (f.length !== 3) continue;
  const shl = f[0] === "shl";
  const fn = wrap ? (shl ? k.spinel_shl_w : k.spinel_shr_w)
                  : (shl ? k.spinel_shl : k.spinel_shr);
  let r;
  try {
    r = `${fn(Number(f[1]), Number(f[2]))}`;
  } catch (e) {
    if (!(e instanceof Trap)) throw e;
    r = e.code === 1 ? "fail" : `trap ${e.code}`;
  }
  console.log(`${f[0]} ${f[1]} ${f[2]} ${r}`);
}
