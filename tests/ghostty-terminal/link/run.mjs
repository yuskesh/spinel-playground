// Runs a wasm command under the repository's shim and prints what it wrote.
import fs from "node:fs";
import { runModule } from "../../../tools/wasm/wasi_shim.mjs";
const mod = await WebAssembly.compile(fs.readFileSync(process.argv[2]));
const { code, stdout } = await runModule(mod, {});
process.stdout.write(typeof stdout === "string" ? stdout : new TextDecoder().decode(stdout));
process.exit(code);
