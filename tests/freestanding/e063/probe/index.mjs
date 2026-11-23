// E063 workerd probe: a compute endpoint over a freestanding Spinel module.
//
//   GET /add?a=20&b=22        -> 42
//   GET /fib?a=30             -> 832040
//   GET /mulnarrow?a=46341&b=46341 -> 422, "trap code=3 ..."
//   GET /                     -> the list of exports
//
// WHAT THIS IS PROBING.  Every other Workers experiment in this repo
// (E013/E014/E055/E058) puts a CGI-shaped lifecycle layer between the request
// and the module, because a full Ruby program wants ARGV, stdin, ENV and
// stdout.  A freestanding module has NONE of those -- it has no I/O at all --
// so the lifecycle layer collapses to what you see here: parse the query,
// call an export, print the number.  There is no wasi_shim, no worker.mjs, no
// _initialize and no per-request instantiate of a runtime.
//
// THE ONE IMPORT is `env.spinel_trap`, and this file is where the P003 trap
// hook meets HTTP: a fault becomes a 422 with the generator's own detail
// string, and the isolate lives on to serve the next request.  On the MCU the
// same hook was `k_panic()`.  Neither policy is in the module.
//
// `kern.wasm` arrives as a compiled WebAssembly.Module (wrangler.toml's
// CompiledWasm rule), so compilation happens once per isolate; instantiation
// is ~2 KB of module and no runtime, which is the point of the experiment.
import kernModule from "./kern.wasm";
import sig from "./sig.json";

class Trap extends Error {
  constructor(code, a, b, detail) {
    super(`trap code=${code}`);
    Object.assign(this, { code, a, b, detail });
  }
}

// One instance per isolate.  A freestanding module has no mutable state that a
// request could dirty -- no heap, no GC, no globals other than the shadow
// stack pointer -- so reusing it across requests is sound in a way it is NOT
// for a full Ruby module (E011 s"reactor" had to reason about exactly this).
let inst = null;
function instance() {
  if (inst) return inst;
  let memory = null;
  inst = new WebAssembly.Instance(kernModule, {
    env: {
      spinel_trap(code, a, b, detail) {
        const u8 = new Uint8Array(memory.buffer);
        let end = detail;
        while (end < u8.length && u8[end] !== 0) end++;
        throw new Trap(code, a, b, new TextDecoder().decode(u8.subarray(detail, end)));
      },
    },
  });
  memory = inst.exports.memory;
  return inst;
}

const text = (body, status = 200) =>
  new Response(body + "\n", {
    status,
    headers: { "content-type": "text/plain; charset=utf-8" },
  });

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const name = url.pathname.replace(/^\/+/, "");
    if (!name) {
      return text(Object.keys(sig).map((k) =>
        `${k}(${sig[k].params.join(", ")}) -> ${sig[k].returns}`).join("\n"));
    }
    const s = sig[name] || sig["spinel_" + name];
    if (!s) return text(`no such export: ${name}`, 404);

    // The declared arity and widths come from the GENERATED header, so a query
    // cannot ask for a call the boundary does not have.  i64 parameters are
    // BigInt at the JS/wasm boundary; anything else is a Number.
    const argv = [];
    for (let i = 0; i < s.params.length; i++) {
      const raw = url.searchParams.get("abcd"[i] || `a${i}`);
      if (raw === null) {
        return text(`${s.export} needs ${s.params.length} argument(s): ` +
                    s.params.map((p, j) => `${"abcd"[j]}:${p}`).join(", "), 400);
      }
      if (!/^-?\d+$/.test(raw)) return text(`argument ${i} is not an integer`, 400);
      argv.push(s.big[i] ? BigInt(raw) : Number(raw));
    }
    try {
      return text(String(instance().exports[s.export](...argv)));
    } catch (e) {
      if (e instanceof Trap) {
        return text(`trap code=${e.code} ${e.detail} (a=${e.a} b=${e.b})`, 422);
      }
      // A wasm trap that did not come through the hook.  Kept separate because
      // P003 D-2 says the hook is the only fault path.
      return text(`wasm trap: ${String(e.message).split("\n")[0]}`, 500);
    }
  },
};
