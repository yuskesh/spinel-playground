// E077: the wasm32 leg of the four-way differential.
//
//   node run_node.mjs kern.wasm cases.json   ->  TSV: E077<TAB>case<TAB>value[<TAB>buf]
//
// The interesting line in this file is the one that decides WHERE the buffers
// live:
//
//     const base = align(inst.exports.__heap_base.value, 8);
//
// That is the whole of E077's answer to R012's "40 lines of C".  The C driver
// existed to own three static arrays and to hand their addresses back across
// the boundary (`buf_in()` returning `(int32_t)(intptr_t)g_in`), because a
// freestanding kernel could not take an address and Ruby could not name one.
// With `params: [[:i32_buf, :in], :len]` the kernel does not need to: the
// CALLER owns the memory and passes the address, and the caller here is JS,
// which can put it anywhere it likes above `__heap_base` -- a symbol wasm-ld
// synthesises for exactly this purpose.  No allocator, no static array, no C.
//
// The other thing worth noting is what `spinel_trap` does: it throws.  E063 s7
// established that the platform decides what a fault means and that the isolate
// survives it; here a throw turns into a `trap:<code>` cell, which is what the
// MCU driver's longjmp arm prints too.  The two platforms disagree about what
// happens afterwards and agree about what happened.
import { readFileSync } from "node:fs";

const [wasmPath, casesPath] = process.argv.slice(2);
if (!wasmPath || !casesPath) {
  console.error("usage: run_node.mjs <kern.wasm> <cases.json>");
  process.exit(2);
}
const spec = JSON.parse(readFileSync(casesPath, "utf8"));

class SpinelTrap extends Error {
  constructor(code, detail) {
    super(detail);
    this.code = code;
  }
}

const mod = new WebAssembly.Module(readFileSync(wasmPath));
let memory = null;
const cstr = (p) => {
  if (!memory || !p) return "";
  const u8 = new Uint8Array(memory.buffer);
  let e = p;
  while (u8[e]) e++;
  return new TextDecoder().decode(u8.subarray(p, e));
};
const inst = new WebAssembly.Instance(mod, {
  env: {
    spinel_trap: (code, a, b, detail) => {
      throw new SpinelTrap(code, cstr(detail));
    },
  },
});
memory = inst.exports.memory;

// ---- the caller-owned region -------------------------------------------
// One contiguous arena above __heap_base, each fixture 8-aligned.  Nothing in
// the module knows this layout exists; the kernel only ever sees (ptr, len).
const align = (n, a) => (n + a - 1) & ~(a - 1);
let cursor = align(inst.exports.__heap_base?.value ?? 65536, 8);
const need = spec.fixtures.reduce(
  (n, f) => n + align(Math.max(1, f.init.length) * f.size, 8), 0);
const have = memory.buffer.byteLength;
if (cursor + need > have) memory.grow(Math.ceil((cursor + need - have) / 65536));

const CTOR = { Uint8Array, Int32Array, Float32Array, Float64Array };
const fx = {};
for (const f of spec.fixtures) {
  fx[f.name] = { ...f, addr: cursor };
  cursor = align(cursor + Math.max(1, f.init.length) * f.size, 8);
}
// `memory.buffer` is re-read on every view because memory.grow detaches the
// old ArrayBuffer (R012's shim learned the same lesson the hard way).
const view = (name) =>
  new CTOR[fx[name].ctor](memory.buffer, fx[name].addr,
                          Math.max(1, fx[name].init.length));
const reset = () => {
  for (const f of spec.fixtures) if (f.init.length) view(f.name).set(f.init);
};

// C's %.17g and Ruby's Float#to_s are different renderings of the same double;
// JS's Number#toString is a third.  The harness compares parsed doubles, so any
// round-tripping rendering will do -- JS's is shortest-round-trip like Ruby's.
const fmt = (v) => (Object.is(v, -0) ? "-0" : String(v));

const out = [];
for (const c of spec.cases) {
  reset();
  const args = c.args.map((a) =>
    "buf" in a ? fx[a.buf].addr : Number(a.lit));
  let cell;
  let trapped = false;
  try {
    const v = inst.exports[c.sym](...args);
    cell = c.kind === "float" ? fmt(v) : String(v);
  } catch (e) {
    if (!(e instanceof SpinelTrap)) {
      cell = `wasmtrap:${e.constructor.name}`;   // E063 s7's control column
    } else {
      cell = `trap:${e.code}`;
    }
    trapped = true;
  }
  let line = `E077\t${c.name}\t${cell}`;
  if (!trapped) {
    for (const s of c.setup) {
      const v = view(s);
      const isf = fx[s].elem[0] === "f";
      line += "\t" + Array.from(v).map((x) => (isf ? fmt(x) : String(x))).join(",") + ",";
    }
  }
  out.push(line);
}
process.stdout.write(out.join("\n") + "\n");
