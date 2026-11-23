// tests/edge/isolation.mjs -- two different requests in a row, in ONE isolate,
// through the pooled WASI shim: the second must carry nothing of the first.
//
//   node --experimental-wasm-exnref tests/edge/isolation.mjs APP.wasm [--reused]
//
// APP.wasm is tests/edge/isolation/app.rb built with tools/wasm/spinel-wasm
// (tests/edge/isolation.sh builds it and runs this). The first request has its
// own argv, env, stdin, a long stdout, some stderr and exit status 3; the second
// has different argv and env, no stdin, and exits 0. Its expected output is
// written below by hand from the program. The shim reuses one slot for both
// (asserted), so every per-request reset in tools/wasm/wasi_shim.mjs's
// configure() is exercised: remove any one of them and a check here fails.
// Both runModule (the shared path) and worker.mjs's serveSpinel are checked.
// With --reused, APP.wasm is the arena build, whose one instance serves every
// request after its memory is written back (decision 0039): the same checks
// then hold across the write-back, and the run asserts that the reused
// instance really served both requests. Without it, that a new instance did.
import fs from "node:fs";
import { runModule, acquireWasi, releaseWasi } from "../../tools/wasm/wasi_shim.mjs";
import { serveSpinel } from "../../tools/wasm/worker.mjs";

const mod = await WebAssembly.compile(fs.readFileSync(process.argv[2]));
const reused = process.argv[3] === "--reused";
let pass = 0, fail = 0;
const ok = (name, cond, detail = "") => {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${detail ? "\n      " + detail : ""}`); }
};
const FIRST_MARKS = ["first", "alpha", "FFFF", "ISO_A=\"", "q=one"];
const clean = (s) => !FIRST_MARKS.some((m) => s.includes(m));
const show = (s) => JSON.stringify(s.length > 300 ? s.slice(0, 300) + "..." : s);

// The pool really reuses a slot, or the checks below would prove nothing.
{ const a = acquireWasi({}); releaseWasi(a.slot); const b = acquireWasi({}); releaseWasi(b.slot);
  ok("the shim hands a released slot to the next request", a.slot === b.slot); }

// ---- runModule, twice ------------------------------------------------------
const r1 = await runModule(mod, { args: ["/first", "q=one"], env: { ISO_A: "alpha-first" }, stdin: "first-body" });
ok("first request: exit 3, its stdin, its env, its stderr",
   r1.code === 3 && r1.stdout.includes('stdin="first-body"') && r1.stdout.includes('env ISO_A="alpha-first"') &&
   r1.stderr === "first-stderr\n", show(r1.stdout + " | " + r1.stderr));

// The second body is SHORTER than what the first read, so a read position left
// over from the first would skip it.
const r2 = await runModule(mod, { args: ["/second", "q=two"], env: { ISO_B: "beta" }, stdin: "two" });
const want2 = 'argv=["/second", "q=two"]\nstdin="two"\nenv ISO_A=nil\nenv ISO_B="beta"\nenv_size=1\nseen=1 paths=1\n';
ok("second request: exactly its own stdout (argv, stdin, env, size)", r2.stdout === want2, show(r2.stdout));
ok("second request: exit 0 (no exit status carried over)", r2.code === 0 && r2.state.exited === null, `code ${r2.code}, exited ${r2.state.exited}`);
ok("second request: empty stderr (no error state carried over)", r2.stderr === "", show(r2.stderr));
ok("second request: no byte of the first", clean(r2.stdout) && clean(r2.stderr));
ok(reused ? "both requests ran on one reused instance, one after the other"
          : "each request ran on a new instance",
   reused ? r1.instance.reused && r2.instance.reused && r2.instance.call === r1.instance.call + 1
          : !r1.instance.reused && !r2.instance.reused,
   JSON.stringify([r1.instance, r2.instance]));
// The first result still answers from its own copy after its slot was reused.
ok("first result is unchanged after the slot served the second",
   r1.stdout.includes('stdin="first-body"') && r1.stdout.includes("F".repeat(6000)) && r1.state.out === r1.stdout);

// ---- worker.mjs's serveSpinel, twice ----------------------------------------
const quiet = { onNotice() {} };
// worker.mjs mirrors fd 2 to console.error while a request runs; capture it.
const mirrored = [];
const origError = console.error; console.error = (m) => mirrored.push(String(m));
const w1 = await serveSpinel(mod, new Request("http://x/first?q=one", { method: "POST", body: "first-body" }),
                             { ISO_A: "alpha-first" }, quiet);
const mirroredFirst = mirrored.splice(0);
const w2 = await serveSpinel(mod, new Request("http://x/second?q=two", { method: "POST", body: "two" }),
                             { ISO_B: "beta" }, quiet);
console.error = origError;
ok("serveSpinel: the stderr mirror saw the first request's stderr, and nothing during the second",
   mirroredFirst.join("") === "first-stderr\n" && mirrored.length === 0, JSON.stringify([mirroredFirst, mirrored]));
const b1 = await w1.text(), b2 = await w2.text();
ok("serveSpinel: first is a 500 carrying its stderr", w1.status === 500 && b1 === "first-stderr\n", `${w1.status} ${show(b1)}`);
ok("serveSpinel: second is a 200 with its own argv and stdin",
   w2.status === 200 && b2.includes('argv=["/second", "q=two"]') && b2.includes('stdin="two"') &&
   b2.includes('env ISO_B="beta"') && b2.includes("env ISO_A=nil"), `${w2.status} ${show(b2)}`);
ok("serveSpinel: second carries no byte of the first", clean(b2) && w2.headers.get("x-spinel-exit") === "0");
ok("serveSpinel: x-spinel-instance names the instance that served each request",
   reused ? /^reused call=\d+ made=(startup|request)$/.test(w1.headers.get("x-spinel-instance") ?? "") &&
            /^reused call=\d+ made=(startup|request)$/.test(w2.headers.get("x-spinel-instance") ?? "")
          : w1.headers.get("x-spinel-instance") === "new" && w2.headers.get("x-spinel-instance") === "new",
   JSON.stringify([w1.headers.get("x-spinel-instance"), w2.headers.get("x-spinel-instance")]));

console.log(`---- isolation: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
