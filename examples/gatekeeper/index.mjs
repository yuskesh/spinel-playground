// examples/gatekeeper/index.mjs -- THE ROUTER.
//
// Two Spinel artifacts, deployed as one Worker, deliberately asymmetric:
//
//   kern.wasm   ~2 KB.  Ruby compiled through the FREESTANDING profile
//               (P003 / E063).  No GC, no allocator, no wasi, no libc; its
//               entire contract with the platform is one import,
//               `env.spinel_trap`.  Every request goes through it.
//   app.wasm    ~245 KB.  The same compiler's ordinary wasm32-wasip1 output:
//               classes, strings, hashes, JSON, exceptions.  Only an ADMITTED
//               request reaches it.
//
// The point of the shape is what does NOT happen: a request the gatekeeper
// sheds is answered without instantiating the full Ruby runtime at all.  The
// 429 costs one instantiate of a 2 KB module (or zero, see RESIDENT below) and
// a few dozen wasm instructions.
//
// ---- STAGE ORDER, AND WHY IT IS NOT E013's ---------------------------------
//
//   0  input validation        pure JS, no wasm
//   1  bot score               kernel      -> 403
//   2  token bucket            kernel      -> 429 + Retry-After
//   3  auth                    JS          -> 401
//   4  A/B bucket              kernel      -> a header
//   5  the body                app.wasm    -> the actual response
//
// worker.mjs's own `serveSpinel` runs authGate FIRST, because there the only
// thing after it is a 245 KB instantiate and nothing cheaper exists to put in
// front.  Here something cheaper does exist, so the order flips: the rate
// limiter protects the token comparison itself against brute forcing, and an
// unauthenticated flood is shed for the price of a 2 KB module.  The cost of
// the flip is that a 401 consumes a token, which is intended.
//
// ---- STATE LIVES OUT HERE ---------------------------------------------------
//
// The kernel is a pure function; the bucket levels are the ROUTER's problem.
// In this example they are an in-isolate Map, which is honest for a demo and
// wrong for production -- Workers gives you one isolate per PoP per while, so
// the limit is per-isolate, not global.  The production spelling is a Durable
// Object or KV read/write around exactly the same two numbers, and NOTHING in
// the kernel changes when you switch, because what crosses the boundary is
// already plain old data: (prev_mt, prev_ts) in, (allow, new_mt) out.
// That is P003 Phase 8's litmus test being applied rather than asserted.

import kernModule from "./kern.wasm";
import kernSig from "./kern_sig.json";
import appModule from "./app.wasm";
import { serveSpinel, authGate } from "./worker.mjs";

const KERN_ABI = 1;

// ---- the one import --------------------------------------------------------
class GateTrap extends Error {
  constructor(code, a, b, detail) {
    super(`trap code=${code}`);
    Object.assign(this, { code, a, b, detail });
  }
}

// P003's trap hook meets HTTP.  A trap here means the DEPLOYMENT is wrong (a
// refill rate of zero, a corrupted timestamp in the state store), not that the
// client sent something odd -- the router validated that in stage 0 -- so it is
// a 422 carrying the generator's own detail string, and the isolate lives on
// to serve the next request (E063 §7 measured that it does).
function newKernInstance(stats) {
  let memory = null;
  const inst = new WebAssembly.Instance(kernModule, {
    env: {
      spinel_trap(code, a, b, detail) {
        const u8 = new Uint8Array(memory.buffer);
        let end = detail;
        while (end < u8.length && u8[end] !== 0) end++;
        throw new GateTrap(code, a, b,
          new TextDecoder().decode(u8.subarray(detail, end)));
      },
    },
  });
  memory = inst.exports.memory;
  stats.kern_instantiations++;
  return inst;
}

// RESIDENT vs PER-REQUEST.  Resident is the default and is SOUND here for the
// reason E063 §8 gives: a freestanding module has no mutable state a request
// could dirty -- no heap, no GC, no globals but the shadow stack pointer -- so
// one instance per isolate cannot leak anything between requests.  That is not
// true of app.wasm, which worker.mjs instantiates per request precisely because
// it does have such state.
//
// The knob exists because "2 KB is cheap enough to instantiate every time" is a
// claim, and a claim in this repo has to be runnable.  GATE_KERN_RESIDENT=0
// makes every request build a fresh kernel instance; the answers must be
// identical, which is what the experiment checks.
let resident = null;
function kern(env, stats) {
  if (String(env?.GATE_KERN_RESIDENT ?? "1") === "0") return newKernInstance(stats);
  if (!resident) resident = newKernInstance(stats);
  return resident;
}

// ---- configuration ---------------------------------------------------------
const num = (v, d) => {
  const n = Number(v);
  return Number.isFinite(n) ? n : d;
};

function config(env) {
  return {
    rate_mt_s: BigInt(num(env?.GATE_RATE_MT_S, 5000)),   // 5 requests/s
    burst_mt: BigInt(num(env?.GATE_BURST_MT, 20000)),    // 20 requests of headroom
    cost_mt: BigInt(num(env?.GATE_COST_MT, 1000)),       // 1 request = 1 token
    buckets: num(env?.GATE_BUCKETS, 4),
    bot_threshold: num(env?.GATE_BOT_THRESHOLD, 60),
    // The operator surface (/__gate/…) is exempt from the rate limiter so that
    // an operator can still read stats while the limiter is shedding.  It is
    // NOT exempt from auth.  In a real deployment this belongs on a separate
    // route with its own credential.
    exempt: String(env?.GATE_EXEMPT_PREFIX ?? "/__gate/"),
  };
}

// ---- identity --------------------------------------------------------------
// The kernel takes a key that is ALREADY hashed, as two i64 halves, because
// hashing a string needs a string and a string needs a heap.  FNV-1a lives on
// this side of the boundary for exactly that reason -- and it is the only piece
// of the gate whose answer JS is responsible for, so it is 12 lines and has no
// options.
function fnv1a64(s, seed) {
  let h = seed;
  const M = 0x100000001b3n;
  const bytes = new TextEncoder().encode(s);
  for (const b of bytes) {
    h = BigInt.asUintN(64, (h ^ BigInt(b)) * M);
  }
  return BigInt.asIntN(64, h);
}

function identity(request) {
  const uid = request.headers.get("x-user-id");
  if (uid) return { uid, kind: "header" };
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) return { uid: ip, kind: "ip" };
  return { uid: "anonymous", kind: "fallback" };
}

// ---- per-identity state (see the header comment: this is the demo spelling) --
const buckets = new Map();
function state(uid, now) {
  let s = buckets.get(uid);
  if (!s) {
    s = { mt: null, ts: now, last: -1 };
    buckets.set(uid, s);
    // Simple bound so a demo cannot grow without limit.  Real deployments put
    // this in a Durable Object and the eviction question goes away.
    if (buckets.size > 4096) {
      for (const k of buckets.keys()) { buckets.delete(k); if (buckets.size <= 2048) break; }
    }
  }
  return s;
}

// ---- feature extraction ----------------------------------------------------
// The router has the parsed Request, so it is the side that can count headers
// and measure a User-Agent.  What crosses the boundary is six i32s.
function features(request, url, gapMs) {
  let hdrs = 0;
  for (const _ of request.headers) hdrs++;
  const ua = request.headers.get("user-agent") || "";
  const method = request.method;
  return [
    hdrs,
    new TextEncoder().encode(ua).length,
    gapMs,
    url.pathname.length,
    url.search.length > 0 ? url.search.length - 1 : 0,
    method === "GET" || method === "HEAD" ? 0 : 1,
  ];
}

const text = (body, status, headers = {}) =>
  new Response(typeof body === "string" ? body + "\n" : body, {
    status,
    headers: { "content-type": "text/plain; charset=utf-8", ...headers },
  });

const json = (obj, status, headers = {}) =>
  new Response(JSON.stringify(obj) + "\n", {
    status,
    headers: { "content-type": "application/json; charset=utf-8", ...headers },
  });

// ---- the operator surface --------------------------------------------------
// /__gate/kern/<export>?a=…&b=…  calls one boundary directly.  The arity and
// the widths come from kern_sig.json, which build.sh generates FROM THE
// GENERATED HEADER -- a transcribed signature list is a bug generator (E063).
// This is also the endpoint the differential oracle drives over HTTP, which is
// why it exists at all; a deployment that does not want it can delete the four
// lines that route to it.
function callKern(inst, name, url) {
  const s = kernSig[name] || kernSig["spinel_" + name];
  if (!s) return { err: text(`no such kernel export: ${name}`, 404) };
  const argv = [];
  for (let i = 0; i < s.params.length; i++) {
    const raw = url.searchParams.get(`a${i}`);
    if (raw === null) {
      return { err: text(
        `${s.export} needs ${s.params.length} argument(s): ` +
        s.params.map((p, j) => `a${j}:${p}`).join(", "), 400) };
    }
    if (!/^-?\d+$/.test(raw)) {
      return { err: text(`argument a${i} is not an integer: ${JSON.stringify(raw)}`, 400) };
    }
    let v;
    try {
      v = s.big[i] ? BigInt(raw) : Number(raw);
    } catch (_) {
      return { err: text(`argument a${i} does not fit`, 400) };
    }
    if (!s.big[i] && !Number.isSafeInteger(v)) {
      return { err: text(`argument a${i} does not fit a ${s.params[i]}`, 400) };
    }
    argv.push(v);
  }
  return { value: inst.exports[s.export](...argv) };
}

// ---- counters --------------------------------------------------------------
// Independent of, and cross-checked against, two other witnesses that the full
// Ruby module ran: worker.mjs's own `x-spinel-exit` response header (it is set
// only after the module has run to completion) and the `gatekeeper-app-ran`
// line app.rb writes to stderr, which workerd puts in the log.
const stats = {
  requests: 0, rejected_input: 0, blocked_bot: 0, limited_rate: 0,
  unauthorized: 0, trapped: 0, app_served: 0, operator: 0,
  kern_instantiations: 0, app_dispatches: 0,
};

export default {
  async fetch(request, env, ctx) {
    stats.requests++;
    const url = new URL(request.url);
    const cfg = config(env);
    const now = BigInt(Date.now());
    let inst;
    try {
      inst = kern(env, stats);
    } catch (e) {
      return text("gatekeeper: the kernel would not instantiate: " + e.message, 500);
    }

    // Stage -1: the artifact has to be whole.  The router and the kernel ship
    // together; a mismatch means somebody deployed half of it.
    const abi = Number(inst.exports.spinel_gate_abi_version());
    if (abi !== KERN_ABI) {
      return text(`gatekeeper: kernel ABI ${abi}, router wants ${KERN_ABI}`, 500,
                  { "x-gate-stage": "abi" });
    }

    const id = identity(request);

    // ---- stage 0: input validation (pure JS, before any wasm) --------------
    if (id.uid.length > 128) {
      stats.rejected_input++;
      return text("x-user-id is too long (max 128 bytes)", 400,
                  { "x-gate-stage": "input", "x-gate-app-run": "0" });
    }
    if (url.pathname.length > 1024) {
      stats.rejected_input++;
      return text("path is too long", 414,
                  { "x-gate-stage": "input", "x-gate-app-run": "0" });
    }

    const st = state(id.uid, now);
    const gapMs = st.last < 0 ? -1 : Number(now - BigInt(st.last));
    const isOperator = url.pathname.startsWith(cfg.exempt);

    let score = 0, blocked = 0, bucket = 0, tokensLeft = 0n, retry = 0;
    try {
      const f = features(request, url, Math.min(gapMs, 2147483647));

      // ---- stage 1: bot score ---------------------------------------------
      score = Number(inst.exports.spinel_bot_score(...f));
      blocked = Number(inst.exports.spinel_bot_block(...f, cfg.bot_threshold));
      if (blocked === 1 && !isOperator) {
        stats.blocked_bot++;
        st.last = Number(now);
        return json({ error: "forbidden", reason: "bot score", score,
                      threshold: cfg.bot_threshold }, 403,
                    { "x-gate-stage": "bot", "x-gate-score": String(score),
                      "x-gate-app-run": "0" });
      }

      // ---- stage 2: token bucket -------------------------------------------
      // Six i64s in, one answer out, three times.  The state the kernel reads
      // is the state this router wrote last time; the kernel remembers nothing.
      const prev_mt = st.mt === null ? cfg.burst_mt : st.mt;
      const prev_ts = BigInt(st.ts);
      const args = [prev_mt, prev_ts, now, cfg.rate_mt_s, cfg.burst_mt, cfg.cost_mt];
      const allow = Number(inst.exports.spinel_tb_allow(...args));
      tokensLeft = inst.exports.spinel_tb_tokens(...args);

      if (!isOperator) {
        st.mt = tokensLeft;
        st.ts = Number(now);
      }
      st.last = Number(now);

      if (allow === 0 && !isOperator) {
        retry = Number(inst.exports.spinel_tb_retry_after(...args));
        stats.limited_rate++;
        return json({ error: "too many requests", tokens_left_mt: String(tokensLeft),
                      retry_after_s: retry }, 429,
                    { "retry-after": String(retry), "x-gate-stage": "rate",
                      "x-gate-tokens": String(tokensLeft), "x-gate-app-run": "0" });
      }

      // ---- stage 4 (computed here, used below): the A/B bucket -------------
      const hi = fnv1a64(id.uid, 0xcbf29ce484222325n);
      // The second half is a DOMAIN-SEPARATED hash of the same identity, and
      // the separator is an explicit NUL so that "ab" + "c" and "a" + "bc"
      // cannot collide into one key.  Spelled \u0000 rather than written as a
      // raw byte: an invisible character in a hash input is a bug waiting to
      // happen, and it was one here first -- the router and the test computed
      // different keys for a whole afternoon because one of them had a space.
      const lo = fnv1a64(id.uid + "\u0000ab", 0x84222325cbf29ce4n);
      bucket = Number(inst.exports.spinel_bucket_hrw(hi, lo, cfg.buckets));
      if (bucket < 0) {
        return text(`gatekeeper: GATE_BUCKETS=${cfg.buckets} is out of range`, 500,
                    { "x-gate-stage": "bucket", "x-gate-app-run": "0" });
      }
    } catch (e) {
      if (e instanceof GateTrap) {
        // The kernel refused to answer.  This is a deployment fault, and it is
        // LOUD: the alternative -- a refill computation that wrapped -- would
        // be the rate limiter failing open, silently.
        stats.trapped++;
        return json({ error: "gatekeeper trap", code: e.code, detail: e.detail,
                      a: String(e.a), b: String(e.b) }, 422,
                    { "x-gate-stage": "trap", "x-gate-app-run": "0" });
      }
      throw e;
    }

    // ---- stage 3: authentication ------------------------------------------
    const denied = authGate(request, env);
    if (denied) {
      stats.unauthorized++;
      const h = new Headers(denied.headers);
      h.set("x-gate-stage", "auth");
      h.set("x-gate-app-run", "0");
      return new Response(denied.body, { status: denied.status, headers: h });
    }

    // ---- the operator surface ---------------------------------------------
    if (isOperator) {
      stats.operator++;
      const rest = url.pathname.slice(cfg.exempt.length);
      if (rest === "stats") {
        return json({ ok: true, kern_abi: abi, config: {
          rate_mt_s: String(cfg.rate_mt_s), burst_mt: String(cfg.burst_mt),
          cost_mt: String(cfg.cost_mt), buckets: cfg.buckets,
          bot_threshold: cfg.bot_threshold,
          kern_resident: String(env?.GATE_KERN_RESIDENT ?? "1") !== "0",
        }, stats, tracked_identities: buckets.size }, 200,
        { "x-gate-stage": "operator", "x-gate-app-run": "0" });
      }
      if (rest === "sig") {
        return json(kernSig, 200, { "x-gate-stage": "operator", "x-gate-app-run": "0" });
      }
      if (rest.startsWith("kern/")) {
        try {
          const r = callKern(inst, rest.slice(5), url);
          if (r.err) return r.err;
          return text(String(r.value), 200,
                      { "x-gate-stage": "operator", "x-gate-app-run": "0" });
        } catch (e) {
          if (e instanceof GateTrap) {
            stats.trapped++;
            return text(`trap code=${e.code} ${e.detail} (a=${e.a} b=${e.b})`, 422,
                        { "x-gate-stage": "trap", "x-gate-app-run": "0" });
          }
          throw e;
        }
      }
      return text(`no such operator endpoint: ${rest} (stats, sig, kern/<export>)`, 404,
                  { "x-gate-stage": "operator", "x-gate-app-run": "0" });
    }

    // ---- stage 5: the body -------------------------------------------------
    // The gate's verdicts ride along as request headers, which the CGI contract
    // turns into HTTP_X_GATE_* in the Ruby program's ENV.  No new mechanism:
    // this is the same layer 0 every other example in this repo uses.
    const h = new Headers(request.headers);
    h.set("x-gate-uid", id.uid);
    h.set("x-gate-variant", String(bucket));
    h.set("x-gate-score", String(score));
    h.set("x-gate-tokens", String(tokensLeft));
    h.set("x-gate-kern", String(abi));
    const inner = new Request(request, { headers: h });

    stats.app_dispatches++;
    const res = await serveSpinel(appModule, inner, env);
    stats.app_served++;

    const out = new Headers(res.headers);
    out.set("x-gate-stage", "app");
    out.set("x-gate-app-run", "1");
    out.set("x-gate-bucket", String(bucket));
    out.set("x-gate-score", String(score));
    out.set("x-gate-tokens", String(tokensLeft));
    return new Response(res.body, { status: res.status, headers: out });
  },
};
