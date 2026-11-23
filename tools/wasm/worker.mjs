// tools/wasm/worker.mjs -- the Workers lifecycle layer (R003 §2-4 layer 0,
// implemented by E013).  Everything a `fetch` handler needs to turn an HTTP
// request into one run of a Spinel wasm32-wasip1 *command* module and back.
//
// The contract is deliberately CGI-shaped: the Ruby program reads ARGV, reads
// $stdin and writes $stdout.  There is no Spinel-side API to learn, no
// host->wasm callback, and no new import beyond the WASI functions the module
// already declares.  Layer 0 is "the request is the process".
//
//   ARGV[0]   URL path            ("/echo")
//   ARGV[1]   raw query string    ("a=1&b=2", "" when there is none)
//   $stdin    the request body, verbatim bytes (empty for a bodyless request)
//   ENV       the Worker's string bindings + CGI request variables (below)
//   $stdout   the response body, verbatim bytes
//   $stderr   console.error, and the 500 body when the program fails
//   exit(n)   n == 0 -> 200, n != 0 -> 500
//
// Per-request instantiate is the shipping shape (E011 §6): a fresh instance per
// request costs ~1.3-1.4 ms for a full Spinel module and removes every
// cross-request state question that the reactor shape raises (E011 §3/§4 lists
// them: sp_argv_array_cache, the regexp memo, GC roots).  Compilation is still
// amortized -- `import mod from "./app.wasm"` is a *compiled*
// WebAssembly.Module evaluated once per isolate, and only instantiate() is on
// the request path.

import { runModule, WasiExit, moduleNeedsHost } from "./wasi_shim.mjs";
import { makeHostApi } from "./spinel_host.mjs";

const DEFAULT_CONTENT_TYPE = "text/plain; charset=utf-8";

// ---- ENV ---------------------------------------------------------------------
// Workers `env` holds two very different kinds of thing: *values* (vars from
// wrangler.toml, secrets -- both plain JS strings) and *bindings* (KV, R2, D1,
// Durable Objects, Queues, service bindings -- JS objects with methods).  Only
// the first kind has a meaning as a POSIX environment string, so only the first
// kind is exported.  A binding is not "an empty variable": it is dropped, and
// the names dropped are reported once via opts.onNotice, because silently
// turning `env.MY_KV` into `ENV["MY_KV"] == ""` is exactly the "cannot tell
// absent from empty" failure R003 §3-1 forbids.
//
// Non-string primitives (a wrangler.toml `[vars]` entry written as a TOML
// number or boolean arrives as a JS number/boolean) are stringified, since
// String(v) is lossless for them and the author clearly meant a value.
//
// SPINEL_ENV_ALLOW, when set, is a comma-separated allowlist: only those names
// reach ENV.  Secrets are strings and would otherwise ALL be visible to the
// Ruby program, which is the CGI behaviour but deserves an opt-out.
//
// E014: a binding that IS reachable -- one the deployment listed in
// SPINEL_HOST_KV, so `SpinelHost::KV.get("MY_KV", …)` really works -- is still
// not an environment string, but it is no longer "unreachable", so it drops
// out of the warning.  The warning exists to point at a dead end; a binding
// with a live bridge is not one.
export function envToEnviron(env, opts = {}) {
  const out = {};
  const skipped = [];
  const reachable = opts.reachable ?? new Set();
  const allowRaw = typeof env?.SPINEL_ENV_ALLOW === "string" ? env.SPINEL_ENV_ALLOW : null;
  const allow = allowRaw === null
    ? null
    : new Set(allowRaw.split(",").map((s) => s.trim()).filter(Boolean));

  for (const [k, v] of Object.entries(env || {})) {
    // SPINEL_AUTH_TOKEN is the edge-auth secret (see authGate).  It gates the
    // request *before* the module runs and must never be readable from Ruby's
    // ENV -- a program that can read it can also print it into a response.
    if (k === "SPINEL_AUTH_TOKEN") continue;
    const t = typeof v;
    if (t === "object" || t === "function" || v === undefined || v === null) {
      if (!reachable.has(k)) skipped.push(k);
      continue;
    }
    if (allow && !allow.has(k)) continue;
    out[k] = String(v);
  }
  if (skipped.length && opts.onNotice) {
    opts.onNotice(
      "spinel: these bindings are not strings and are not visible in ENV: " +
      skipped.join(", ") + " (use an explicit host bridge -- R003 §2-4 layer 1)");
  }
  return out;
}

// CGI request variables.  Same names CGI/1.1 uses, so the Ruby side reads like
// any other CGI script.  Headers become HTTP_<NAME> with `-` -> `_` and upper
// case, again per CGI.  These are written *after* the bindings, so a binding
// named e.g. REQUEST_METHOD loses -- the per-request truth wins, and the
// collision is reported.
export function requestToEnviron(request, url, bodyLen, base = {}, opts = {}) {
  const out = { ...base };
  const cgi = {
    REQUEST_METHOD: request.method,
    PATH_INFO: url.pathname,
    QUERY_STRING: url.search.startsWith("?") ? url.search.slice(1) : url.search,
    REQUEST_URI: url.pathname + url.search,
    SERVER_NAME: url.hostname,
    SERVER_PORT: url.port || (url.protocol === "https:" ? "443" : "80"),
    SERVER_PROTOCOL: "HTTP/1.1",
    SERVER_SOFTWARE: "spinel-wasm/workers",
    CONTENT_LENGTH: String(bodyLen),
    GATEWAY_INTERFACE: "CGI/1.1",
  };
  const ct = request.headers.get("content-type");
  if (ct) cgi.CONTENT_TYPE = ct;
  const ip = request.headers.get("cf-connecting-ip");
  if (ip) cgi.REMOTE_ADDR = ip;
  for (const [k, v] of request.headers) {
    cgi["HTTP_" + k.toUpperCase().replace(/-/g, "_")] = v;
  }
  const clash = Object.keys(cgi).filter((k) => k in out && out[k] !== cgi[k]);
  if (clash.length && opts.onNotice) {
    opts.onNotice("spinel: request variables override same-named bindings in ENV: " +
      clash.join(", "));
  }
  return { ...out, ...cgi };
}

// ---- optional CGI header block ----------------------------------------------
// Off by default: a program that writes binary bytes must not have them
// reinterpreted as headers.  With SPINEL_CGI_HEADERS=1 the program may emit a
// CGI header block ("Content-Type: application/json", "Status: 404", blank
// line) before the body, which is how a CGI-shaped program controls status and
// content type.  Parsing stops at the first line that is not `Name: value`, and
// the whole output is then treated as a body -- a program that forgets the
// blank line gets its text back, not a 500.
function splitCgiHeaders(bytes) {
  const limit = Math.min(bytes.length, 8192);
  let i = 0;
  const headers = [];
  const dec = new TextDecoder();
  while (i < limit) {
    let j = i;
    while (j < limit && bytes[j] !== 0x0a) j++;
    if (j >= limit) return null;                       // no terminator in range
    let end = j;
    if (end > i && bytes[end - 1] === 0x0d) end--;     // CRLF
    if (end === i) return { headers, body: bytes.subarray(j + 1) };  // blank line
    const line = dec.decode(bytes.subarray(i, end));
    const c = line.indexOf(":");
    if (c <= 0) return null;                           // not a header block
    headers.push([line.slice(0, c).trim(), line.slice(c + 1).trim()]);
    i = j + 1;
  }
  return null;
}

// ---- the host API (E014, R003 §2-4 layer 1) ---------------------------------
// Installed only for a module that actually imports `spinel_host` -- i.e. one
// built with `--host-api` that uses it.  Everything else runs exactly as
// before, JSPI included: no Suspending import is created, so no `promising`
// entry, so no cost (see the E014 measurements).
//
// Two deployment knobs, both read from `env`:
//
//   SPINEL_HOST_KV     comma-separated binding names the program may reach
//                      through SpinelHost::KV.  A binding NOT listed here is
//                      invisible to the bridge even though the isolate holds
//                      it: reachability is a deployment decision, not an
//                      accident of what wrangler.toml happens to bind.
//   SPINEL_HOST_FETCH  "0" turns outbound HTTP off; SpinelHost.fetch then
//                      raises ArgumentError with a reason instead of quietly
//                      failing.
//   SPINEL_HOST_MAX_BODY  cap on a staged response body (default 8 MiB).
//   SPINEL_HOST_R2     the same, for SpinelHost::R2 (E055).
//   SPINEL_HOST_D1     the same, for SpinelHost::D1 (E055).
//   SPINEL_HOST_MAX_ROWS  cap on rows staged from one query/listing
//                      (default 10000).
export function hostBindingNames(env, key) {
  const raw = typeof env?.[key] === "string" ? env[key] : "";
  return new Set(raw.split(",").map((s) => s.trim()).filter(Boolean));
}

export function hostKvNames(env) {
  return hostBindingNames(env, "SPINEL_HOST_KV");
}

// Every binding name the bridge can reach, in one place: this is what the ENV
// warning consults (a binding with a live bridge is not a dead end) and what
// the reachability rule is enforced against.  One list, so the two can never
// disagree.
export function hostReachableNames(env) {
  const out = new Set();
  for (const k of ["SPINEL_HOST_KV", "SPINEL_HOST_R2", "SPINEL_HOST_D1"]) {
    for (const n of hostBindingNames(env, k)) out.add(n);
  }
  return out;
}

export function hostConfig(env, opts = {}) {
  const kvNames = hostBindingNames(env, "SPINEL_HOST_KV");
  const r2Names = hostBindingNames(env, "SPINEL_HOST_R2");
  const d1Names = hostBindingNames(env, "SPINEL_HOST_D1");
  const maxBody = parseInt(env?.SPINEL_HOST_MAX_BODY ?? "", 10);
  const maxRows = parseInt(env?.SPINEL_HOST_MAX_ROWS ?? "", 10);
  return {
    fetch: String(env?.SPINEL_HOST_FETCH ?? "1") === "0"
      ? null
      : (opts.fetch ?? ((u, i) => globalThis.fetch(u, i))),
    kv: (name) => (kvNames.has(name) ? env?.[name] : null),
    // Listing a name here is what makes the binding visible to Ruby.  A bucket
    // or database that wrangler.toml binds but this does not name is invisible
    // to the bridge: reachability is a deployment decision, never an accident
    // of what happens to be bound (E014's rule, unchanged).
    r2: (name) => (r2Names.has(name) ? env?.[name] : null),
    d1: (name) => (d1Names.has(name) ? env?.[name] : null),
    maxBody: Number.isFinite(maxBody) && maxBody > 0 ? maxBody : undefined,
    maxRows: Number.isFinite(maxRows) && maxRows > 0 ? maxRows : undefined,
    onNotice: opts.onNotice,
  };
}


// ---- edge auth ---------------------------------------------------------------
// Opt-in pre-shared-token gate, checked BEFORE any wasm work (an unauthorized
// request never instantiates the module).  Enable by setting the secret:
//
//   npx wrangler secret put SPINEL_AUTH_TOKEN        (or .dev.vars locally)
//
// and call with `Authorization: Bearer <token>`.  When the secret is absent the
// worker is open (local dev default); a one-time notice says so, so an
// accidentally-open deployment is visible in `wrangler tail`.
// The token is excluded from Ruby's ENV (see envToEnviron).
function timingSafeEqualStr(a, b) {
  const enc = new TextEncoder();
  const ab = enc.encode(a), bb = enc.encode(b);
  if (ab.length !== bb.length) {
    // burn comparable time on length mismatch, then refuse
    let x = 0;
    for (let i = 0; i < Math.max(ab.length, bb.length, 1); i++) {
      x |= (ab[i % (ab.length || 1)] ?? 0) ^ (bb[i % (bb.length || 1)] ?? 0);
    }
    return false && x === -1;
  }
  try {
    if (globalThis.crypto?.subtle?.timingSafeEqual) {
      return crypto.subtle.timingSafeEqual(ab, bb);
    }
  } catch (_) { /* fall through to the manual loop */ }
  let diff = 0;
  for (let i = 0; i < ab.length; i++) diff |= ab[i] ^ bb[i];
  return diff === 0;
}

let authNoticeShown = false;
export function authGate(request, env, opts = {}) {
  const token = typeof env?.SPINEL_AUTH_TOKEN === "string" ? env.SPINEL_AUTH_TOKEN : "";
  if (!token) {
    if (!authNoticeShown) {
      authNoticeShown = true;
      (opts.onNotice ?? ((m) => console.warn(m)))(
        "spinel: SPINEL_AUTH_TOKEN is not set -- this worker answers " +
        "unauthenticated requests (fine for local dev; set the secret before " +
        "exposing it: npx wrangler secret put SPINEL_AUTH_TOKEN)");
    }
    return null;
  }
  const h = request.headers.get("Authorization") || "";
  const ok = h.startsWith("Bearer ") && timingSafeEqualStr(h.slice(7), token);
  if (ok) return null;
  return new Response("401 Unauthorized\n", {
    status: 401,
    headers: {
      "Content-Type": "text/plain; charset=utf-8",
      "WWW-Authenticate": 'Bearer realm="spinel"',
    },
  });
}

// ---- the handler -------------------------------------------------------------
// mod    a compiled WebAssembly.Module (the CompiledWasm import).
// opts   .args(url, request) -> string[]     override the ARGV convention
//        .contentType                        default response content type
//        .onNotice(msg)                      where the ENV notices go
//        .host(state) -> host API            override the host implementation
//        .fetch(url, init)                   override the outbound fetch
//        .snapshot                           false: a new instance for every
//                                            request even for an arena module
//                                            built for reuse (decision 0039)
// One function and one decoder for every request (feat/wasm-less-garbage).
// `bytes` is the shim's view of this write, valid during the call: it is
// decoded here and not kept.
const STDERR_DEC = new TextDecoder();
function mirrorStderr(fd, bytes) {
  if (fd === 2) console.error(STDERR_DEC.decode(bytes));
}

export async function serveSpinel(mod, request, env = {}, opts = {}) {
  const t0 = Date.now();
  const url = new URL(request.url);
  const notice = opts.onNotice ?? ((m) => console.warn(m));
  const denied = authGate(request, env, { onNotice: notice });
  if (denied) return denied;
  const wantsHost = moduleNeedsHost(mod);
  const cfg = hostConfig(env, { fetch: opts.fetch, onNotice: notice });
  const host = wantsHost
    ? (opts.host ?? ((state) => makeHostApi(state, cfg)))
    : undefined;

  // Buffered, not streamed: the module is a *command* -- it runs to completion
  // and then the response exists.  See "Honest boundary" in the E013 write-up.
  const body = request.method === "GET" || request.method === "HEAD"
    ? new Uint8Array(0)
    : new Uint8Array(await request.arrayBuffer());

  const environ = requestToEnviron(
    request, url, body.length,
    envToEnviron(env, {
      onNotice: notice,
      reachable: wantsHost ? hostReachableNames(env) : new Set(),
    }),
    { onNotice: notice });

  const args = opts.args
    ? opts.args(url, request)
    : [url.pathname, environ.QUERY_STRING];

  let r;
  try {
    r = await runModule(mod, {
      args, env: environ, stdin: body, host, snapshot: opts.snapshot,
      // Mirror stderr while the request is still running: if the module traps
      // afterwards, the diagnostics are already out.
      onWrite: mirrorStderr,
    });
  } catch (e) {
    // A wasm trap, a LinkError, or an out-of-memory.  Not an exit status: the
    // module never got to say anything, so say so plainly rather than
    // returning an empty 200.
    if (!(e instanceof WasiExit)) {
      return new Response("spinel: the module failed to run: " + (e && e.message) + "\n", {
        status: 500,
        headers: {
          "content-type": DEFAULT_CONTENT_TYPE,
          "x-spinel-exit": "trap",
          "x-spinel-ms": String(Date.now() - t0),
        },
      });
    }
    throw e;
  }

  const ms = String(Date.now() - t0);
  const headers = new Headers({
    "x-spinel-exit": String(r.code),
    "x-spinel-ms": ms,
    "x-spinel-stdout-bytes": String(r.stdoutBytes.length),
    // Which instance served the request: a reused arena instance, its
    // request count on this isolate and whether the isolate's startup or a
    // request made it, or a new one (decision 0039).
    "x-spinel-instance": r.instance?.reused
      ? `reused call=${r.instance.call} made=${r.instance.made}` : "new",
  });
  // What the program actually did through the bridge, so a host call is never
  // invisible from the outside (and so the concurrency test has something to
  // assert on).
  const c = r.state?.host?.counters;
  if (c) {
    headers.set("x-spinel-host",
      `fetch=${c.fetches} kv_get=${c.kvGets} kv_put=${c.kvPuts} ` +
      `r2_get=${c.r2Gets ?? 0} r2_put=${c.r2Puts ?? 0} r2_del=${c.r2Deletes ?? 0} ` +
      `r2_list=${c.r2Lists ?? 0} d1=${c.d1Execs ?? 0} suspends=${c.suspends}`);
  }

  // exit != 0 -> 500 carrying stderr.  stderr is where an uncaught Ruby
  // exception ends up (Spinel prints it and exits 1), so a NotImplementedError
  // from the raise policy (E012) arrives at the client as its Ruby message
  // instead of a blank 500.  Any stdout the program managed to write first is
  // NOT concatenated into the body -- a half-written response body is worse
  // than none -- but its size is reported so it is not invisible.
  if (r.code !== 0) {
    const msg = r.stderrBytes.length
      ? r.stderrBytes
      : new TextEncoder().encode(`spinel: program exited with status ${r.code}\n`);
    headers.set("content-type", DEFAULT_CONTENT_TYPE);
    return new Response(msg, { status: 500, headers });
  }

  let status = 200;
  let out = r.stdoutBytes;
  headers.set("content-type", opts.contentType ?? env?.SPINEL_CONTENT_TYPE ?? DEFAULT_CONTENT_TYPE);

  if (String(env?.SPINEL_CGI_HEADERS ?? "") === "1") {
    const parsed = splitCgiHeaders(out);
    if (parsed) {
      out = parsed.body;
      for (const [k, v] of parsed.headers) {
        if (k.toLowerCase() === "status") status = parseInt(v, 10) || 200;
        else headers.set(k, v);
      }
    }
  }
  return new Response(out, { status, headers });
}
