// tests/fiber/run.mjs -- run a wasm32-wasip1 command module once under
// node:wasi with stdin from /dev/null; the module's stdout and stderr pass
// through and the exit code is the module's.
//
//   node --experimental-wasm-exnref run.mjs app.wasm
import { WASI } from "node:wasi";
import fs from "node:fs";

const wasi = new WASI({ version: "preview1", args: ["app"], env: {}, returnOnExit: true,
                        stdin: fs.openSync("/dev/null", "r") });
const module = await WebAssembly.compile(fs.readFileSync(process.argv[2]));
const instance = await WebAssembly.instantiate(module, { wasi_snapshot_preview1: wasi.wasiImport });
process.exitCode = wasi.start(instance);
