// tests/edge/arena_run.mjs -- run a wasm32-wasip1 command module once under
// node:wasi and report its linear memory.
//
//   node --experimental-wasm-exnref arena_run.mjs app.wasm [ARG...]
//
// The program's stdout is passed through; stdin is /dev/null. The last line on
// stderr is `pages before=N after=M rc=R`. The environment the module sees is
// REQUEST_METHOD=GET plus SPINEL_GC_SLAB when this process has it, so a caller
// can check that an explicit setting still overrides the arena build's default.
import { WASI } from "node:wasi";
import fs from "node:fs";

const [file, ...args] = process.argv.slice(2);
const env = { REQUEST_METHOD: "GET" };
if (process.env.SPINEL_GC_SLAB !== undefined) env.SPINEL_GC_SLAB = process.env.SPINEL_GC_SLAB;
const wasi = new WASI({ version: "preview1", args: ["app", ...args], env, returnOnExit: true,
                        stdin: fs.openSync("/dev/null", "r") });
const module = await WebAssembly.compile(fs.readFileSync(file));
const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
const pages = () => instance.exports.memory.buffer.byteLength / 65536;
const before = pages();
const rc = wasi.start(instance);
console.error(`pages before=${before} after=${pages()} rc=${rc}`);
