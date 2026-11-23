// tests/edge/snapshot.mjs -- the arena module's instance reuse (decision 0039),
// through tools/wasm/wasi_shim.mjs's runModule and worker.mjs's serveSpinel.
//
//   node --experimental-wasm-exnref tests/edge/snapshot.mjs DIR
//
// DIR holds what tests/edge/arena.sh builds:
//   hh.wasm     examples/hello-http/app.rb, --request-arena
//   hh-no.wasm  the same with --no-snapshot (the control)
//   big.wasm    `puts ("x" * ARGV[1].to_i).bytesize`, --request-arena
//   wait.wasm   one Edge::HTTP.get through the host API, --request-arena
//               --host-api (a suspending import, so the request waits on the
//               host with the shared instance in use)
// Every expected answer is written here by hand from the programs.
import fs from "node:fs";
import { runModule, prepareModule, snapshotStats } from "../../tools/wasm/wasi_shim.mjs";
import { serveSpinel } from "../../tools/wasm/worker.mjs";

const dir = process.argv[2];
const load = (n) => WebAssembly.compile(fs.readFileSync(`${dir}/${n}.wasm`));
let pass = 0, fail = 0;
const ok = (name, cond, detail = "") => {
  if (cond) { pass++; console.log(`PASS  ${name}`); }
  else { fail++; console.log(`FAIL  ${name}${detail ? "\n      " + detail : ""}`); }
};
const stats = () => ({ ...snapshotStats });
const delta = (a, b) => Object.fromEntries(Object.keys(a).map((k) => [k, b[k] - a[k]]));

// The mutable globals a module defines, from its global section (id 6).  The
// write-back resets __stack_pointer only, so it must be the only one.
function mutableGlobals(bytes) {
  let p = 8;
  const leb = () => { let r = 0, s = 0, b; do { b = bytes[p++]; r |= (b & 0x7f) << s; s += 7; } while (b & 0x80); return r >>> 0; };
  while (p < bytes.length) {
    const id = bytes[p++], size = leb(), end = p + size;
    if (id === 6) {
      let n = leb(), mut = 0;
      while (n--) {
        p++;                                // value type
        if (bytes[p++] === 1) mut++;        // mutability
        while (bytes[p++] !== 0x0b) {}      // the constant init expression
      }
      return mut;
    }
    p = end;
  }
  return 0;
}

const hh = await load("hh"), hhNo = await load("hh-no");
const info = (i) => ({ args: ["/info", `a=${i}&b=2`], env: { REQUEST_METHOD: "GET" } });
const infoWant = (i) => `path=/info\nquery=a=${i}&b=2\nparams=a:${i},b:2\nmethod=GET\ncontent_type=nil\nbody_bytes=0\n`;
const echoBody = new Uint8Array(1024).fill(0x78);
const echo = { args: ["/echo", ""], env: { REQUEST_METHOD: "POST" }, stdin: echoBody };

// ---- the contract in the module --------------------------------------------
{
  const names = (m) => WebAssembly.Module.exports(m).map((e) => e.name);
  ok("hh.wasm exports spinel_snapshot_abi and __stack_pointer",
     names(hh).includes("spinel_snapshot_abi") && names(hh).includes("__stack_pointer"), names(hh).join(","));
  ok("hh-no.wasm (--no-snapshot) exports neither", !names(hhNo).includes("spinel_snapshot_abi") &&
     !names(hhNo).includes("__stack_pointer"), names(hhNo).join(","));
  const m = mutableGlobals(fs.readFileSync(`${dir}/hh.wasm`));
  ok("hh.wasm defines one mutable global (the stack pointer the write-back resets)", m === 1, `got ${m}`);
}

// ---- one instance, many requests -------------------------------------------
{
  const s0 = stats();
  let wrong = 0;
  const calls = [];
  for (let i = 0; i < 200; i++) {
    const r = await runModule(hh, i % 2 ? info(i) : echo);
    const want = i % 2 ? infoWant(i) : "x".repeat(1024);
    if (r.code !== 0 || r.stdout !== want) wrong++;
    calls.push(r.instance.call);
  }
  const d = delta(s0, stats());
  ok("200 requests in a row: every answer exact", wrong === 0, `${wrong} wrong`);
  ok("200 requests in a row: one instance served them all, in order",
     d.instances === 1 && d.reused === 200 && calls.every((c, i) => c === i + 1), JSON.stringify(d));
}
{
  const s0 = stats();
  const rs = [await runModule(hhNo, info(1)), await runModule(hhNo, info(2))];
  ok("control: the --no-snapshot module gets a new instance per request, and answers",
     rs.every((r) => r.instance.reused === false) && rs[1].stdout === infoWant(2) &&
     JSON.stringify(delta(s0, stats())) === JSON.stringify({ instances: 0, reused: 0, fallbacks: 0 }));
  const r = await runModule(hh, { ...info(3), snapshot: false });
  ok("control: snapshot:false gives a new instance even for hh.wasm", r.instance.reused === false && r.stdout === infoWant(3));
}

// ---- requests arriving together on a new isolate ---------------------------
{
  const fresh = await load("hh");           // a new Module: no instance yet
  const s0 = stats();
  const rs = await Promise.all(Array.from({ length: 50 }, (_, i) => runModule(fresh, info(i))));
  const d = delta(s0, stats());
  ok("50 requests at once on a module with no instance yet: one instance for all",
     d.instances === 1 && d.reused === 50 && d.fallbacks === 0, JSON.stringify(d));
  ok("50 requests at once: every answer exact", rs.every((r, i) => r.stdout === infoWant(i)));
}

// ---- the instance made at startup (prepareModule) --------------------------
{
  const fresh = await load("hh");
  const s0 = stats();
  const made = prepareModule(fresh);
  const d0 = delta(s0, stats());              // before any await: synchronous
  ok("prepareModule makes the instance synchronously", made === true && d0.instances === 1, JSON.stringify([made, d0]));
  ok("prepareModule a second time makes nothing", prepareModule(fresh) === false && stats().instances === s0.instances + 1);
  const r1 = await runModule(fresh, info(7)), r2 = await runModule(fresh, echo);
  const d = delta(s0, stats());
  ok("the first request runs on the instance made at startup",
     r1.stdout === infoWant(7) && r1.instance.call === 1 && r1.instance.made === "startup" &&
     r2.stdout === "x".repeat(1024) && r2.instance.call === 2 && d.instances === 1 && d.fallbacks === 0,
     JSON.stringify([r1.instance, r2.instance, d]));
  ok("control: prepareModule leaves the --no-snapshot module and the host-API module alone",
     prepareModule(await load("hh-no")) === false && prepareModule(await load("wait")) === false);
  const big = await load("big");
  prepareModule(big);
  const huge = await runModule(big, { args: ["/", "20000000"] });
  const next = await runModule(big, { args: ["/", "1000"] });
  ok("after the startup instance is let go, a request makes the next one",
     huge.instance.made === "startup" && next.instance.made === "request" && next.instance.call === 1 && next.stdout === "1000\n",
     JSON.stringify([huge.instance, next.instance]));
}

// ---- memory: the grown pages are zeroed, and a large one is let go ---------
{
  const big = await load("big");
  const s0 = stats();
  const small = await runModule(big, { args: ["/", "1000"] });
  const huge = await runModule(big, { args: ["/", "20000000"] });
  const after = await runModule(big, { args: ["/", "1000"] });
  const d = delta(s0, stats());
  ok("big: answers 1000, 20000000, 1000", small.stdout === "1000\n" && huge.stdout === "20000000\n" && after.stdout === "1000\n",
     JSON.stringify([small.stdout, huge.stdout, after.stdout]));
  ok("big: a request that grows the memory past 16 MiB leaves a new instance for the next one",
     huge.instance.call === 2 && after.instance.call === 1 && d.instances === 2, JSON.stringify([small.instance, huge.instance, after.instance, d]));
  const again = await runModule(big, { args: ["/", "1000"] });
  ok("control: a request that stays small keeps the instance", again.instance.call === 2, JSON.stringify(again.instance));
}

// ---- a request that waits on the host --------------------------------------
{
  const wait = await load("wait");
  let release;
  const gate = new Promise((r) => { release = r; });
  const fetch = async (url) => { await gate; return new Response(`body for ${new URL(url).pathname}`); };
  const req = (p) => serveSpinel(wait, new Request(`http://x${p}`), { FETCH_URL: `http://h${p}` }, { onNotice() {}, fetch });
  const s0 = stats();
  const first = req("/one");                // waits on the gate with the shared instance in use
  await new Promise((r) => setTimeout(r, 50));
  const second = req("/two");
  await new Promise((r) => setTimeout(r, 50));
  release();
  const [a, b] = await Promise.all([first, second]);
  const [ta, tb] = [await a.text(), await b.text()];
  const d = delta(s0, stats());
  ok("waiting on the host: both answers exact", ta === "/one 200 body for /one\n" && tb === "/two 200 body for /two\n",
     JSON.stringify([a.status, ta, b.status, tb]));
  ok("waiting on the host: the first kept the shared instance, the second got a new one",
     a.headers.get("x-spinel-instance") === "reused call=1 made=request" && b.headers.get("x-spinel-instance") === "new" && d.fallbacks === 1,
     JSON.stringify([a.headers.get("x-spinel-instance"), b.headers.get("x-spinel-instance"), d]));
  const c = await req("/three");
  ok("waiting on the host: the next request is back on the shared instance",
     c.headers.get("x-spinel-instance") === "reused call=2 made=request" && (await c.text()) === "/three 200 body for /three\n");
}

console.log(`---- snapshot: ${pass} passed, ${fail} failed`);
process.exit(fail ? 1 : 0);
