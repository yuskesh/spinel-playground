// E063: what a trap IS on wasm.
//
// On the MCU (E040) `spinel_trap` was a k_panic() and the whole question was
// "does the run really stop".  On wasm the hook is an IMPORT, so the answer is
// the host's to give -- which is more useful (a worker wants a 500, not a dead
// isolate) and more dangerous, because a host that simply RETURNS from the hook
// would be resuming a computation whose result is known to be wrong.
//
// So there are four questions, and each is a row of trap.tsv:
//
//   1. is the hook the only import?          (the module asks for nothing else)
//   2. do all three codes actually occur?    (1 overflow, 2 /0, 3 boundary)
//   3. is `detail` readable?                 (it is a pointer into exported memory)
//   4. what if the host RETURNS?             (must be a wasm trap, never a value)
//
// (4) is the design question this file exists for.  The generator emits
// `llvm.unreachable` after the call (the same shape E022 gave the raise arm),
// so the answer should be an unconditional wasm trap; if instead a number came
// back, the trap contract would be advisory and the whole `overflow: trap`
// decision (P003 D-2) would be unenforceable on this target.
import { readFileSync } from "node:fs";

const wasmPath = process.argv[2];
const bytes = readFileSync(wasmPath);
const mod = await WebAssembly.compile(bytes);

const rows = [];
const row = (check, result, detail = "") => rows.push([check, result, detail]);

// --- 1. the import surface -------------------------------------------------
const imports = WebAssembly.Module.imports(mod);
row("only_import_is_the_hook",
    imports.length === 1 && imports[0].module === "env" &&
    imports[0].name === "spinel_trap" && imports[0].kind === "function"
      ? "PASS" : "FAIL",
    imports.map((i) => `${i.module}.${i.name}:${i.kind}`).join(",") || "(none)");

// --- 2 and 3. the three codes, and the detail string -----------------------
function instantiate(onTrap) {
  let memory = null;
  const inst = new WebAssembly.Instance(mod, {
    env: {
      spinel_trap: (code, a, b, detail) => onTrap(code, a, b, detail, () => {
        const u8 = new Uint8Array(memory.buffer);
        let end = detail;
        while (end < u8.length && u8[end] !== 0) end++;
        return new TextDecoder().decode(u8.subarray(detail, end));
      }),
    },
  });
  memory = inst.exports.memory;
  return inst;
}

const seen = new Map();
const throwing = instantiate((code, a, b, _p, read) => {
  const e = new Error(`trap:${code}`);
  e.code = code; e.a = a; e.b = b; e.detail = read();
  throw e;
});
function fault(fn, ...args) {
  try { return { value: throwing.exports[fn](...args) }; }
  catch (e) { return { code: e.code, detail: e.detail, a: e.a, b: e.b }; }
}

const probes = [
  // code 1: the 32-bit BODY overflows (46341 * 46341 > 2**31 - 1) before the
  // i32 boundary sees the product (decision 0019, revised 2026-10-21).
  [1, "mulnarrow(46341,46341)", () => fault("spinel_mulnarrow", 46341, 46341)],
  [2, "qdiv(1,0)",      () => fault("spinel_qdiv", 1, 0)],
  // code 3: a value the body holds and the :u8 boundary does not (256).
  [3, "u8clamp(200,56)", () => fault("spinel_u8clamp", 200, 56)],
];
for (const [want, what, run] of probes) {
  const r = run();
  seen.set(want, r);
  row(`trap_code_${want}_reached`, r.code === want ? "PASS" : "FAIL",
      `${what} -> ${r.code === undefined ? `returned ${r.value}` : `code=${r.code}`}`);
}
const withDetail = [...seen.values()].filter((r) => r.detail && r.detail.length > 0);
row("detail_string_readable", withDetail.length === seen.size ? "PASS" : "FAIL",
    withDetail.map((r) => JSON.stringify(r.detail)).join(" | "));

// --- 4. a host that returns from the hook ---------------------------------
// The hook is declared `void`, so returning is a legal thing for a JS function
// to do and the module cannot prevent it.  What it CAN do -- and what the
// generator does -- is make the instruction after the call unreachable.
let resumed = null, trapped = null;
const returning = instantiate(() => undefined);
try {
  resumed = returning.exports.spinel_mulnarrow(46341, 46341);
} catch (e) {
  trapped = e;
}
row("returning_hook_does_not_resume",
    resumed === null && trapped ? "PASS" : "FAIL",
    trapped ? `${trapped.constructor.name}: ${String(trapped.message).split("\n")[0]}`
            : `resumed and returned ${resumed}`);
// And the instance must stay usable afterwards -- a wasm trap unwinds, it does
// not poison the instance the way a Cortex-M panic ends the world.  This is the
// property a per-request worker needs: one bad request must not take the
// isolate with it.
let after = null, afterErr = null;
try { after = returning.exports.spinel_add(20, 22); } catch (e) { afterErr = e; }
row("instance_usable_after_trap", after === 42 ? "PASS" : "FAIL",
    afterErr ? String(afterErr.message).split("\n")[0] : `spinel_add(20,22)=${after}`);

console.log(["check", "result", "detail"].join("\t"));
for (const r of rows) console.log(r.join("\t"));
if (rows.some((r) => r[1] === "FAIL")) process.exitCode = 1;
