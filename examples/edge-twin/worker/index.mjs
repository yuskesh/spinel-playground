// edge-twin -- the edge worker.
//
//   GET  /                    what this worker is, and the kernel it runs
//   GET  /stream?n=&seed=&k=  produce an audit log HERE (the edge as a twin
//                             of the device, not just as its verifier)
//   POST /audit               replay a device's audit log and rule on it
//   GET  /probe?x=            one reading straight into the kernel
//
// The interesting endpoint is /audit.  A device signed a log with a rolling
// digest it computed itself; this worker recomputes every verdict and every
// digest from the SAMPLES alone, using a wasm build of the same kern.rb the
// device is running, and reports the first row on which the two disagree.  That
// only means something because the two builds answer with the same bits, which
// is what docs/experiments/E067_edge_twin.md measures across five runners.
//
// HTTP STATUS IS THE POLICY LAYER, and it is worth reading as such:
//
//   200  the log replays exactly           (ACCEPT)
//   409  the log and the replay disagree   (REJECT -- tampering, corruption, or
//        a kernel version that is not this one)
//   422  the kernel trapped: a reading outside the declared domain.  The device
//        that produced such a reading called k_panic(); here the isolate lives
//        and answers.  SAME contract, different manifestation -- P003 D-2 puts
//        that decision in the platform on purpose.
//   400  it is not an audit log at all
//
// There is no lifecycle layer in this file, and that absence is the freestanding
// story: no CGI contract, no wasi shim, no per-request instantiate of a runtime
// (E063 §8).  The module is ~2 KB with a single import, so one instance per
// isolate is sound -- it has no heap and no mutable state a request could dirty.
import kernModule from "./kern.wasm";
import sig from "./sig.json";
import { AuditError, Trap, audit, formatLog, instantiate, parseLog, produce }
  from "./twin.mjs";

let K = null;
const kernel = () => (K ??= instantiate(kernModule));

const text = (body, status = 200) =>
  new Response(body.endsWith("\n") ? body : body + "\n",
               { status, headers: { "content-type": "text/plain; charset=utf-8" } });
const json = (obj, status = 200) =>
  new Response(JSON.stringify(obj, null, 1) + "\n",
               { status, headers: { "content-type": "application/json; charset=utf-8" } });

function numParams(url, keys) {
  const p = {};
  for (const k of keys) {
    const raw = url.searchParams.get(k);
    if (raw === null) continue;
    if (!/^-?\d+$/.test(raw)) throw new AuditError(400, `${k} is not an integer`);
    p[k] = Number(raw);
  }
  return p;
}

export default {
  async fetch(request) {
    const url = new URL(request.url);
    const path = url.pathname.replace(/\/+$/, "") || "/";
    try {
      const K = kernel();

      if (path === "/") {
        return text([
          `edge-twin worker -- kern_version=${K.spinel_kern_version()}`,
          "",
          "the boundaries this kernel exports (from the generated header):",
          ...Object.keys(sig).map((k) =>
            `  ${k}(${sig[k].params.join(", ")}) -> ${sig[k].returns}`),
          "",
          "GET  /stream?n=1024&seed=1&k=3   produce an audit log",
          "POST /audit                      replay one and rule on it",
          "GET  /probe?x=25000              one reading into the kernel",
        ].join("\n"));
      }

      if (path === "/stream") {
        const p = numParams(url, ["n", "seed", "k", "mean0", "nbound"]);
        return text(formatLog(produce(K, p)));
      }

      if (path === "/audit") {
        if (request.method !== "POST") return text("POST an audit log here", 405);
        const res = audit(K, parseLog(await request.text()));
        return json(res, res.verdict === "ACCEPT" ? 200 : 409);
      }

      if (path === "/probe") {
        const p = numParams(url, ["x", "k"]);
        if (p.x === undefined) return text("probe needs ?x=<reading>", 400);
        return text(String(K.spinel_verdict(0n, 0n, p.x, p.k ?? 3)));
      }

      return text(`no such endpoint: ${path}`, 404);
    } catch (e) {
      if (e instanceof Trap) {
        // The one import the module has, surfacing as an HTTP status.  The
        // generator's own detail string names the method and the operation, so
        // the answer says WHICH reading the kernel refused and why.
        return json({ verdict: "TRAP", code: e.code, detail: e.detail,
                      a: String(e.a), b: String(e.b),
                      note: "a reading outside the kernel's declared domain " +
                            "(|x| <= 100000); the device that produced it panicked" },
                    422);
      }
      if (e instanceof AuditError) return json({ verdict: "REJECT", error: e.message }, e.status);
      return json({ verdict: "ERROR", error: String(e && e.message || e) }, 500);
    }
  },
};
