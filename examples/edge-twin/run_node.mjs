#!/usr/bin/env node
// edge-twin -- the node runner.  It is the same kernel and the same twin.mjs
// the worker runs, driven from a shell instead of from HTTP.
//
//   node run_node.mjs produce [dist/kern.wasm]        > audit.log
//   node run_node.mjs audit   [dist/kern.wasm] < audit.log
//   node run_node.mjs probe   [dist/kern.wasm]        # the trap boundary
//
// `produce` is one of the five runners the differential oracle compares; the
// other four are bin/spinel's native C back end, workerd, QEMU/Cortex-M33 and
// QEMU/RV32.  All five have to print the same bytes.
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { audit, formatLog, instantiate, parseLog, produce } from "./worker/twin.mjs";

const HERE = dirname(fileURLToPath(import.meta.url));
const cmd = process.argv[2] || "produce";
const wasmPath = process.argv[3] || join(HERE, "dist", "kern.wasm");
const K = instantiate(new WebAssembly.Module(readFileSync(wasmPath)));

function readStdin() {
  return readFileSync(0, "utf8");
}

if (cmd === "produce") {
  const params = {};
  for (const a of process.argv.slice(4)) {
    const [k, v] = a.replace(/^--/, "").split("=");
    params[k] = Number(v);
  }
  process.stdout.write(formatLog(produce(K, params)));
} else if (cmd === "audit") {
  const res = audit(K, parseLog(readStdin()));
  console.log(JSON.stringify(res, null, 1));
  process.exitCode = res.verdict === "ACCEPT" ? 0 : 1;
} else if (cmd === "probe") {
  // The declared domain of kern.rb is |x| <= 100000; sq16 leaves the i64 body
  // at x = 11863284 from a zero state.  Both sides of that boundary, printed
  // the way the harness reads them.
  for (const x of [11863283, 11863284]) {
    try {
      console.log(`verdict(0,0,${x},3)\t${K.spinel_verdict(0n, 0n, x, 3)}`);
    } catch (e) {
      console.log(`verdict(0,0,${x})\ttrap:code=${e.code}\t${e.detail}`);
    }
  }
  // A trap must not leave the instance unusable -- one bad request may not take
  // the isolate with it.  (On the MCU the same hook calls k_panic() and the
  // opposite is true, on purpose: E067 §trap.)
  console.log(`after-trap kern_version()\t${K.spinel_kern_version()}`);
} else {
  console.error(`usage: run_node.mjs produce|audit|probe [kern.wasm]`);
  process.exitCode = 2;
}
