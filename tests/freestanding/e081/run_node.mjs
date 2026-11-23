// E081: the wasm32 leg of the four-way differential.
//
//   node run_node.mjs kern.wasm cases.json          -> case TSV on stdout
//   node run_node.mjs kern.wasm cases.json --shape  -> import/export TSV only
//
// THE POINT OF THIS FILE is the `env` object below: it IS layer 3.  The same
// seven extern declarations that a Zephyr build satisfies with
// spinel_zephyr.c (k_uptime_get, the GPIO driver) are satisfied here by seven
// JS functions -- same symbols, same signatures, a different platform.  The
// module cannot tell; that is the "platform extern, Zephyr is one instance"
// claim, executed.
//
// The JS implementations follow the same documented contract mkcases.py's
// host stubs implement (fake 1000ms clock advanced by sleep, 8-pin register
// file, checksum xor).  i64 crosses the JS boundary as BigInt; u32 crosses as
// an i32 bit pattern, so the checksum import masks with >>> 0 on both sides.
import { readFileSync } from "node:fs";

const [wasmPath, casesPath, flag] = process.argv.slice(2);
if (!wasmPath || !casesPath) {
  console.error("usage: run_node.mjs <kern.wasm> <cases.json> [--shape]");
  process.exit(2);
}
const spec = JSON.parse(readFileSync(casesPath, "utf8"));
const mod = new WebAssembly.Module(readFileSync(wasmPath));

if (flag === "--shape") {
  for (const i of WebAssembly.Module.imports(mod)) {
    console.log(`import\t${i.module}\t${i.name}\t${i.kind}`);
  }
  for (const e of WebAssembly.Module.exports(mod)) {
    console.log(`export\t${e.name}\t${e.kind}`);
  }
  process.exit(0);
}

class SpinelTrap extends Error {
  constructor(code, detail) {
    super(detail);
    this.code = code;
  }
}

let memory = null;
const cstr = (p) => {
  if (!memory || !p) return "";
  const u8 = new Uint8Array(memory.buffer);
  let e = p;
  while (u8[e]) e++;
  return new TextDecoder().decode(u8.subarray(p, e));
};

// ---- the platform (layer 3), in JS --------------------------------------
let clock = 1000n;
const pins = new Int32Array(8);
let prints = 0;
const env = {
  spinel_trap: (code, a, b, detail) => {
    throw new SpinelTrap(code, cstr(detail));
  },
  spinel_zephyr_uptime_ms: () => clock,
  spinel_zephyr_sleep_ms: (d) => {
    clock += BigInt(d);
    return 0;
  },
  spinel_zephyr_print_i64: (v) => {
    prints += 1;
    return 0;
  },
  spinel_zephyr_gpio_set: (pin, val) => {
    if (pin < 0 || pin > 7 || val < 0 || val > 1) return -1;
    pins[pin] = val;
    return val;
  },
  spinel_zephyr_gpio_get: (pin) => (pin < 0 || pin > 7 ? -1 : pins[pin]),
  // `a` arrives already rounded through the kernel's :f32 narrowing (D-4);
  // wasm hands it to JS as the exact double that f32 denotes.
  spinel_zephyr_sense_scale: (a, b) => a * 2.0 + b,
  spinel_zephyr_checksum32: (v) => (((v >>> 0) ^ 0xa5a5a5a5) >>> 0) | 0,
};

const inst = new WebAssembly.Instance(mod, { env });
memory = inst.exports.memory;

const fmt = (v) => (Object.is(v, -0) ? "-0" : String(v));
const out = [];
for (const c of spec.cases) {
  const args = c.args.map((a) => (a.t === "i64" ? BigInt(a.v) : Number(a.v)));
  let cell;
  try {
    const v = inst.exports[c.sym](...args);
    cell = c.kind === "float" ? fmt(v) : String(v);
  } catch (e) {
    cell = e instanceof SpinelTrap ? `trap:${e.code}`
                                   : `wasmtrap:${e.constructor.name}`;
  }
  out.push(`E081\t${c.name}\t${cell}`);
}
out.push(`E081\tPROP\tprint_witness\t${prints}`);
process.stdout.write(out.join("\n") + "\n");
