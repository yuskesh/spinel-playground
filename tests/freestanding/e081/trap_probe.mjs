// E081: the wasm trap semantics of an extern-ARGUMENT narrowing fault, the
// four E063 s7 questions asked again at the new trap site:
//   1. does the declared narrowing actually reach the hook (code 3, and the
//      detail names the argument and the extern)?
//   2. if the host's hook RETURNS instead of throwing, does execution resume?
//      (it must not: the generator puts llvm.unreachable after the call)
//   3. is the instance still usable after a trapped call? (per-request
//      isolation -- the Worker property)
//   4. control: the in-range call does not trap at all.
import { readFileSync } from "node:fs";

const [wasmPath] = process.argv.slice(2);
const mod = new WebAssembly.Module(readFileSync(wasmPath));

class SpinelTrap extends Error {
  constructor(code, detail) {
    super(detail);
    this.code = code;
  }
}

let memory = null;
const cstr = (p) => {
  const u8 = new Uint8Array(memory.buffer);
  let e = p;
  while (u8[e]) e++;
  return new TextDecoder().decode(u8.subarray(p, e));
};

const pins = new Int32Array(8);
const baseEnv = (trap) => ({
  spinel_trap: trap,
  spinel_zephyr_uptime_ms: () => 1000n,
  spinel_zephyr_sleep_ms: () => 0,
  spinel_zephyr_print_i64: () => 0,
  spinel_zephyr_gpio_set: (pin, val) =>
    pin < 0 || pin > 7 || val < 0 || val > 1 ? -1 : ((pins[pin] = val), val),
  spinel_zephyr_gpio_get: (pin) => (pin < 0 || pin > 7 ? -1 : pins[pin]),
  spinel_zephyr_sense_scale: (a, b) => a * 2.0 + b,
  spinel_zephyr_checksum32: (v) => ((v >>> 0) ^ 0xa5a5a5a5) | 0,
});

const rows = [];
const row = (name, ok, detail) =>
  rows.push(`${ok ? "PASS" : "FAIL"}\t${name}\t${detail}`);

// 1 + 3 + 4: a throwing hook.
{
  const inst = new WebAssembly.Instance(
    mod,
    { env: baseEnv((code, a, b, detail) => { throw new SpinelTrap(code, cstr(detail)); }) },
  );
  memory = inst.exports.memory;
  try {
    inst.exports.spinel_pin_probe(4294967301n);
    row("extern_narrow_traps", false, "no trap");
  } catch (e) {
    row("extern_narrow_traps",
        e instanceof SpinelTrap && e.code === 3 &&
          e.message.includes("argument 1 of gpio_set"),
        `code=${e.code} detail=${e.message}`);
  }
  const again = inst.exports.spinel_toggle_count(4);
  row("instance_usable_after_trap", again === 2, `toggle_count(4)=${again}`);
  const ok = inst.exports.spinel_pin_probe(3n);
  row("in_range_no_trap", ok === 1, `pin_probe(3)=${ok}`);
}

// 2: a hook that RETURNS.  The kernel must still not continue.
{
  const inst = new WebAssembly.Instance(
    mod, { env: baseEnv(() => {}) });
  memory = inst.exports.memory;
  try {
    const v = inst.exports.spinel_pin_probe(4294967301n);
    row("returning_hook_does_not_resume", false, `resumed with ${v}`);
  } catch (e) {
    row("returning_hook_does_not_resume",
        e instanceof WebAssembly.RuntimeError,
        `${e.constructor.name}: ${e.message}`);
  }
}

process.stdout.write(rows.join("\n") + "\n");
process.exit(rows.every((r) => r.startsWith("PASS")) ? 0 : 1);
