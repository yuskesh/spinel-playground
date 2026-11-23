// tests/core-bitwise/fs32/powers.mjs -- `abs` and `**` of fs32/k.rb at 32
// bits, as fs/powers.c does them at 64. argv[3] is `trap` or `wrap`. Reads
// rows "abs A N", "pow A N" or "powk A E" on stdin and prints "op A N R": R is
// the result, `fail` when the trap hook is called with the overflow code 1,
// or `negative` when it is called with code 7. The hook throws, which leaves
// the kernel, and the next row runs.
import { readFileSync } from "node:fs";
class Trap extends Error {
  constructor(code) { super(`trap ${code}`); this.code = code; }
}
const env = { spinel_trap(code) { throw new Trap(code); } };
const { instance } = await WebAssembly.instantiate(readFileSync(process.argv[2]), { env });
const k = instance.exports;
const suffix = process.argv[3] === "wrap" ? "_w" : "";
const name = (op, n) =>
  op === "abs" ? "ab" : op === "pow" ? "pw" : op === "powk" ? `pk${n}` : "";
for (const line of readFileSync(0, "utf8").split("\n")) {
  const f = line.trim().split(/\s+/);
  if (f.length !== 3) continue;
  const fn = k[`spinel_${name(f[0], f[2])}${suffix}`];
  let r;
  if (typeof fn !== "function") {
    r = "unknown";
  } else {
    try {
      r = `${fn(Number(f[1]), Number(f[2]))}`;
    } catch (e) {
      if (!(e instanceof Trap)) throw e;
      r = e.code === 1 ? "fail" : e.code === 7 ? "negative" : `trap ${e.code}`;
    }
  }
  console.log(`${f[0]} ${f[1]} ${f[2]} ${r}`);
}
