// E063: the wasm side of the differential oracle, run under node (V8).
//
//   node run_node.mjs kern.wasm cases.json   ->  TSV: case<TAB>result
//
// A result is either the number the export returned, printed the way Ruby's
// Integer#to_s prints it (so that it can be compared CHARACTER BY CHARACTER
// against the host oracle's stdout), or `trap:code=<n>` when the module called
// its one import.
//
// THE TRAP IMPORT IS THE WHOLE PLATFORM LAYER.  `spinel_trap(code, a, b,
// detail)` is undefined in the object; wasm-ld made it an import in module
// `env`; here it throws a JS exception, which unwinds the wasm frames and
// returns control to the caller.  On the MCU the same hook was a k_panic().
// Both are "the platform decides what a fault is" (P003 s"trap hook"), and
// neither is a policy the generated module contains.
//
// The `detail` argument is a pointer into the module's linear memory -- the
// string constants the generator emitted -- so the message is read back out of
// the exported memory here.  That is the only reason this driver touches memory
// at all; the kernel itself never loads or stores.
import { readFileSync } from "node:fs";

const [wasmPath, casesPath] = process.argv.slice(2);
const cases = JSON.parse(readFileSync(casesPath, "utf8"));

class SpinelTrap extends Error {
  constructor(code, a, b, detail) {
    super(`trap:code=${code}`);
    Object.assign(this, { code, a, b, detail });
  }
}

let memory = null;
function cstr(ptr) {
  if (!memory || !ptr) return "";
  const u8 = new Uint8Array(memory.buffer);
  let end = ptr;
  while (end < u8.length && u8[end] !== 0) end++;
  return new TextDecoder().decode(u8.subarray(ptr, end));
}

const mod = await WebAssembly.compile(readFileSync(wasmPath));
const inst = await WebAssembly.instantiate(mod, {
  env: {
    spinel_trap(code, a, b, detail) {
      throw new SpinelTrap(code, a, b, cstr(detail));
    },
  },
});
memory = inst.exports.memory;
// A wasip1 reactor exports _initialize and it must be called before anything
// else.  The bare module has nothing to initialise and does not export it --
// which is one of the things this experiment set out to find out -- so the call
// is conditional rather than assumed.
if (typeof inst.exports._initialize === "function") inst.exports._initialize();

console.log(["case", "result", "detail"].join("\t"));
for (const c of cases) {
  const fn = inst.exports[c.export];
  let result, detail = "";
  if (typeof fn !== "function") {
    result = `missing-export:${c.export}`;
  } else {
    const args = c.args.map((a, i) => (c.argbig[i] ? BigInt(a) : Number(a)));
    try {
      const v = fn(...args);
      // BigInt and Number both stringify to the decimal digits Ruby prints;
      // BigInt's toString does NOT add the `n` suffix.
      result = String(v);
    } catch (e) {
      if (e instanceof SpinelTrap) {
        result = `trap:code=${e.code}`;
        detail = `${e.detail} a=${e.a} b=${e.b}`;
      } else {
        // A wasm trap that is NOT ours: `unreachable`, a division the module
        // did not guard, a stack overflow.  Kept distinguishable on purpose --
        // P003 decision record D-2 says the hook is the ONLY fault path, and a
        // row saying `wasmtrap:` would be evidence against that.
        result = `wasmtrap:${e.constructor.name}`;
        detail = String(e.message).split("\n")[0];
      }
    }
  }
  console.log([c.case, result, detail].join("\t"));
}
