// tools/wasm/spinel_host.mjs -- the JS half of the `spinel_host` import
// namespace (R003 §2-4 layer 1, implemented by E014).  The C half is
// tools/wasm/sp_wasm_host.c; the two files share one set of error codes and
// one protocol, and nothing else.
//
// THE PROTOCOL, from this side: stage-then-drain.
//
//   http_request / kv_get / kv_put   do the async work, park the result in
//   r2_* / d1_exec                   `staged`, and return a small integer
//                                    (an HTTP status, 1/0, a row count, or a
//                                    negative error code).  These are the ONLY
//                                    functions the caller wraps in
//                                    WebAssembly.Suspending.
//   res_body_len / res_body_read     synchronous accessors over `staged`.
//   res_headers_len / res_headers_read
//   tbl_* (E055)                     synchronous accessors over a staged
//                                    *table* -- see "THE TABLE SLOT" below.
//   d1_bind_* (E055)                 synchronous accumulators for the next
//                                    d1_exec's placeholder values.
//   last_error                       detail text for the last negative return.
//
// THE TABLE SLOT (E055).  E014 left exactly one question open for Phase iv:
// "list / delete / TTL have a different return shape (an array, a boolean), so
// the staging slot needs one representation".  Two operations here answer with
// a *grid* rather than a blob -- `d1_exec` (rows x columns) and `r2_list`
// (objects x attributes) -- and both use the same slot:
//
//     tbl_rows() / tbl_cols()            the shape
//     tbl_col_name(i, buf, cap)          column names
//     tbl_cell_type(row, col)            0 NULL / 1 INT / 2 REAL / 3 TEXT / 4 BLOB
//     tbl_cell_len(row, col)             byte length of the cell
//     tbl_cell_read(row, col, buf, cap)  the cell's bytes, verbatim
//
// It is addressed, not serialized.  A serialized frame (JSON, CSV, a header
// block) would have to answer three questions this target cannot afford to get
// wrong: how a BLOB carrying NUL survives, how SQL NULL stays distinct from the
// empty string, and how a TEXT cell containing the delimiter is escaped.  An
// (row, col) -> bytes accessor answers all three by construction: nothing is
// ever parsed, so nothing can ever be mis-parsed.  The cost is 3 synchronous
// import calls per cell, which do not suspend and cannot re-enter wasm.
//
// Why not "call with cap=0 to learn the length, then call again to copy"
// (R003 §2-4's sketch)?  Because for a fetch the length call *is* the request.
// Asking twice would send two requests -- for a POST, two side effects.  So
// the request happens once and the length question is asked of the staged
// bytes, which is free and cannot suspend.  Consequences worth stating:
//
//   * exactly one suspend per Ruby-visible operation;
//   * the accessors never suspend, so nothing can re-enter wasm while a
//     suspend is outstanding (R003 §2-5's re-entrancy rule holds by
//     construction, not by discipline);
//   * the host never calls back into wasm -- there is no host->wasm direction
//     in this API at all, so no malloc callback and no reentry point.
//
// Every function reads wasm memory through `state.mem.buffer` *at call time*:
// a memory.grow across a suspend detaches the old ArrayBuffer, and a cached
// view would be a use-after-detach.

export const HOST_NS = "spinel_host";

export const E_ARG = -1;    // malformed use: bad URL, unknown binding, ...
export const E_NET = -2;    // the network attempt itself failed
export const E_SPACE = -3;  // would not fit: cap too small / over the limit
export const E_STAGE = -4;  // nothing staged: an accessor called too early
export const E_HOST = -5;   // the host broke internally
export const E_NOSYS = -6;  // no host API configured
export const E_SQL = -7;    // the database refused the statement (E055)

// Cell type tags for the table slot.  Must match sp_wasm_host.c and the
// SP_D1_* / tag constants in spinel_host.rb.  A tag is what keeps SQL NULL
// ("no value") distinct from a zero-length TEXT ("") -- R003 §3-1's rule
// applied one level down, to a single cell.
export const T_NULL = 0, T_INT = 1, T_REAL = 2, T_TEXT = 3, T_BLOB = 4;

// Which imports do async work.  The caller (wasi_shim.mjs) wraps exactly these
// in WebAssembly.Suspending and enters the module through
// WebAssembly.promising.  Declared explicitly rather than sniffed from
// fn.constructor.name, which a bundler is free to change.
//
// E055: the R2 and D1 operations join the list; the d1_bind_* accumulators and
// every tbl_* accessor stay synchronous on purpose, so the "one suspend per
// Ruby-visible operation" property of E014 survives a query with 500 cells in
// it.
export const SUSPENDING = [
  "http_request", "kv_get", "kv_put",
  "r2_get", "r2_head", "r2_put", "r2_delete", "r2_list",
  "d1_exec",
];

const enc = new TextEncoder();
const dec = new TextDecoder();

// ---- header blocks -----------------------------------------------------------
// "Name: value\n" per line, blank-line-free, exactly the shape E013 already
// parses for SPINEL_CGI_HEADERS.  JSON would be the natural Workers vocabulary
// but there is no JSON on this target: `require "json"` pulls
// packages/json/sp_json.o, a *native* object with no wasm32 build, so a Ruby
// program on Workers cannot parse what it is handed.  Handing it a format it
// cannot read would be the "half-working API" R003 §3 exists to prevent.
export function formatHeaderBlock(headers) {
  let s = "";
  for (const [k, v] of headers) {
    // A value carrying CR/LF would forge extra header lines on the way back
    // into Ruby's parser.  Fold them to spaces rather than dropping the header.
    s += k.toLowerCase() + ": " + String(v).replace(/[\r\n]+/g, " ") + "\n";
  }
  return s;
}

export function parseHeaderBlock(text) {
  const out = [];
  for (const raw of text.split("\n")) {
    const line = raw.replace(/\r$/, "");
    if (!line) continue;
    const i = line.indexOf(":");
    if (i <= 0) throw new Error(`malformed header line: ${JSON.stringify(raw)}`);
    const name = line.slice(0, i).trim();
    if (!name || /[^\w!#$%&'*+.^`|~-]/.test(name)) {
      throw new Error(`malformed header name: ${JSON.stringify(name)}`);
    }
    out.push([name, line.slice(i + 1).trim()]);
  }
  return out;
}

// ---- cells (E055) ------------------------------------------------------------
// One JS value -> one tagged, byte-exact cell.  The tag is what a serialized
// format would have had to encode and this does not: it travels beside the
// bytes rather than inside them.
//
// The bytes for INT and REAL are the value's decimal text.  That is not a
// "stringly typed" fallback -- it is the only representation that survives the
// trip without the Ruby side needing to know the host's number encoding, and
// the tag says which of Integer#to_i / Float#to_f to apply on the far end.
// String(n) for a JS double is the shortest round-tripping decimal, so
// `Float(String(v)) === v` holds and the Ruby `to_f` recovers the same double.
export function cell(v) {
  if (v === null || v === undefined) return { t: T_NULL, b: EMPTY };
  if (typeof v === "bigint") return { t: T_INT, b: enc.encode(v.toString()) };
  if (typeof v === "number") {
    return Number.isInteger(v)
      ? { t: T_INT, b: enc.encode(String(v)) }
      : { t: T_REAL, b: enc.encode(String(v)) };
  }
  // SQLite has no boolean; D1 hands back 0/1 for one.  A JS boolean can still
  // reach here from R2's `truncated`, so map it the same way SQLite would.
  if (typeof v === "boolean") return { t: T_INT, b: enc.encode(v ? "1" : "0") };
  if (typeof v === "string") return { t: T_TEXT, b: enc.encode(v) };
  if (v instanceof Uint8Array) return { t: T_BLOB, b: v };
  if (v instanceof ArrayBuffer) return { t: T_BLOB, b: new Uint8Array(v) };
  if (ArrayBuffer.isView(v)) return { t: T_BLOB, b: new Uint8Array(v.buffer, v.byteOffset, v.byteLength) };
  if (Array.isArray(v)) return { t: T_BLOB, b: Uint8Array.from(v) };
  // Anything else would have to be guessed at, and a guessed cell is exactly
  // the "plausible wrong answer" this target refuses to produce.
  throw new Error(`cannot represent a ${Object.prototype.toString.call(v)} as a cell`);
}

const EMPTY = new Uint8Array(0);
const errText = (e) => String((e && (e.cause?.message || e.message)) || e);
const isoOf = (d) => {
  if (!d) return null;
  try { return d instanceof Date ? d.toISOString() : String(d); } catch (_) { return null; }
};

// An R2 object's description, as the same "Name: value\n" block a fetch
// response's headers use.  `key` is echoed back rather than derived, so a key
// containing CR/LF is folded to spaces here -- harmless, because the caller
// passed the key in and already has the exact bytes.  A *listing* never uses
// this path: there the key comes back through the table, byte-exact.
export function r2Meta(key, obj) {
  const out = [["key", key], ["size", String(obj.size ?? 0)]];
  if (obj.etag || obj.httpEtag) out.push(["etag", String(obj.etag || obj.httpEtag)]);
  const up = isoOf(obj.uploaded);
  if (up) out.push(["uploaded", up]);
  const ct = obj.httpMetadata?.contentType;
  if (ct) out.push(["content-type", String(ct)]);
  return out;
}

// A "Name: value\n" block from the Ruby side -> R2 put options.  content-type
// is the one name with a defined meaning; everything else becomes custom
// metadata, which R2 stores and returns untouched.
export function r2PutOptions(pairs) {
  const opts = {};
  const custom = {};
  let any = false;
  for (const [k, v] of pairs) {
    if (k.toLowerCase() === "content-type") {
      opts.httpMetadata = { ...(opts.httpMetadata || {}), contentType: v };
    } else {
      custom[k] = v; any = true;
    }
  }
  if (any) opts.customMetadata = custom;
  return opts;
}

// ---- the host implementation -------------------------------------------------
// makeHostApi(state, cfg) -> { fns, suspending }
//
//   state       the wasi state object; state.mem is set after instantiate.
//   cfg.fetch   the fetch to use (default globalThis.fetch).  null disables
//               outbound HTTP: http_request then answers E_ARG with a reason,
//               which is a *refusal*, not a pretend success.
//   cfg.kv      (name) => KV-binding | null | undefined.  Only namespaces the
//               deployment explicitly opted in should resolve.
//   cfg.r2      (name) => R2-bucket  | null   (E055, same reachability rule)
//   cfg.d1      (name) => D1-database| null   (E055, same reachability rule)
//   cfg.maxBody response bytes the host will stage (default 8 MiB).  Over it,
//               E_SPACE -- the request is NOT silently truncated.
//   cfg.maxRows rows the host will stage from one query (default 10000).
//   cfg.onNotice(msg)   diagnostics.
export function makeHostApi(state, cfg = {}) {
  const fetchImpl = cfg.fetch === undefined ? globalThis.fetch : cfg.fetch;
  const kvLookup = cfg.kv || (() => null);
  const r2Lookup = cfg.r2 || (() => null);
  const d1Lookup = cfg.d1 || (() => null);
  const maxBody = cfg.maxBody ?? 8 * 1024 * 1024;
  const maxRows = cfg.maxRows ?? 10000;

  let stagedBody = new Uint8Array(0);
  let stagedHeaders = new Uint8Array(0);
  let haveStaged = false;
  let lastError = "";
  // The table slot.  null = nothing staged; otherwise { cols: [name…],
  // rows: [[{t, b}…]…] }.  Replaced wholesale by the next d1_exec / r2_list.
  let stagedTable = null;
  // Placeholder values for the next d1_exec, in bind order.  Host-global and
  // synchronous: a statement is bound and run in one go on the Ruby side.
  let binds = [];
  const counters = {
    fetches: 0, kvGets: 0, kvPuts: 0, suspends: 0,
    r2Gets: 0, r2Puts: 0, r2Deletes: 0, r2Lists: 0, d1Execs: 0,
  };

  const u8 = () => new Uint8Array(state.mem.buffer);
  const cstr = (p) => {
    const m = u8();
    let e = p >>> 0;
    while (m[e]) e++;
    return dec.decode(m.subarray(p >>> 0, e));
  };

  const fail = (code, msg) => { lastError = msg; return code; };

  const stage = (body, headers) => {
    stagedBody = body;
    stagedHeaders = headers;
    haveStaged = true;
  };
  const clear = () => {
    stagedBody = stagedHeaders = new Uint8Array(0);
    haveStaged = false; lastError = "";
    // A failed operation must not leave the previous result readable: E014's
    // unit run established "a failure leaves nothing staged", and a table is
    // staged state exactly like a body is.
    stagedTable = null;
  };

  const drain = (blob) => (ptr, cap) => {
    if (!haveStaged) return fail(E_STAGE, "nothing staged: no completed host call");
    const b = blob();
    if (cap < b.length) return fail(E_SPACE, `buffer too small: ${cap} < ${b.length}`);
    u8().set(b, ptr >>> 0);
    return b.length;
  };
  const lengthOf = (blob) => () =>
    haveStaged ? blob().length : fail(E_STAGE, "nothing staged: no completed host call");

  // ---- E055 helpers ------------------------------------------------------------
  const copyOut = (b, ptr, cap) => {
    if (cap < b.length) return fail(E_SPACE, `buffer too small: ${cap} < ${b.length}`);
    u8().set(b, ptr >>> 0);
    return b.length;
  };
  const noTable = () => "nothing staged: no completed query or listing";
  const noBucket = (n) => `no R2 bucket named ${JSON.stringify(n)} is available to this worker`;
  // Returns the cell, or a negative error code.  Cells are always objects, so
  // the two are never confusable.
  const cellAt = (r, c) => {
    if (!stagedTable) return fail(E_STAGE, noTable());
    const row = stagedTable.rows[r];
    if (r < 0 || !row) return fail(E_ARG, `row ${r} out of range (0..${stagedTable.rows.length - 1})`);
    if (c < 0 || c >= stagedTable.cols.length) return fail(E_ARG, `column ${c} out of range (0..${stagedTable.cols.length - 1})`);
    return row[c];
  };

  const fns = {
    // ---- the one suspending operation that matters ---------------------------
    async http_request(urlPtr, methodPtr, bodyPtr, bodyLen, headersPtr) {
      clear();
      let url, method, init;
      try {
        url = cstr(urlPtr);
        method = (cstr(methodPtr) || "GET").toUpperCase();
        const headers = parseHeaderBlock(cstr(headersPtr));
        // Copy the request body out of linear memory BEFORE any await: after a
        // suspend the module may have grown its memory and detached this
        // ArrayBuffer.
        const hasBody = bodyLen > 0 && method !== "GET" && method !== "HEAD";
        const body = hasBody ? u8().slice(bodyPtr >>> 0, (bodyPtr >>> 0) + bodyLen) : undefined;
        init = { method, headers, body };
      } catch (e) {
        return fail(E_ARG, String((e && e.message) || e));
      }
      if (!/^https?:\/\//i.test(url)) {
        return fail(E_ARG, `unsupported URL (need http:// or https://): ${JSON.stringify(url)}`);
      }
      if (!fetchImpl) {
        return fail(E_ARG, "outbound HTTP is not enabled for this worker");
      }

      counters.fetches++;
      counters.suspends++;
      let res;
      try {
        res = await fetchImpl(url, init);
      } catch (e) {
        // DNS failure, connection refused, TLS error, abort: the *attempt*
        // failed, so there is no status to report.  This is the only network
        // outcome that raises on the Ruby side.
        return fail(E_NET, `${method} ${url}: ${String((e && e.message) || e)}`);
      }
      let bytes;
      try {
        bytes = new Uint8Array(await res.arrayBuffer());
      } catch (e) {
        return fail(E_NET, `${method} ${url}: reading the body failed: ${String((e && e.message) || e)}`);
      }
      if (bytes.length > maxBody) {
        return fail(E_SPACE,
          `${method} ${url}: response is ${bytes.length} bytes, over the ${maxBody}-byte host limit`);
      }
      stage(bytes, enc.encode(formatHeaderBlock(res.headers)));
      // A non-2xx status is an ANSWER, not an error: it comes back as the
      // return value and the body/headers are staged exactly as for a 200.
      return res.status;
    },

    // ---- the binding exemplar -------------------------------------------------
    async kv_get(nsPtr, keyPtr) {
      clear();
      const ns = cstr(nsPtr), key = cstr(keyPtr);
      const b = kvLookup(ns);
      if (!b || typeof b.get !== "function") {
        return fail(E_ARG, `no KV namespace named ${JSON.stringify(ns)} is available to this worker`);
      }
      if (!key) return fail(E_ARG, "KV key must not be empty");
      counters.kvGets++;
      counters.suspends++;
      let v;
      try {
        v = await b.get(key, "arrayBuffer");
      } catch (e) {
        return fail(E_NET, `KV ${ns}.get(${JSON.stringify(key)}): ${String((e && e.message) || e)}`);
      }
      if (v === null || v === undefined) {
        // A miss is an answer.  Stage an empty result so the accessors stay
        // legal, and report 0 -- "absent" and "empty string" stay
        // distinguishable at the Ruby level (R003 §3-1).
        stage(new Uint8Array(0), new Uint8Array(0));
        return 0;
      }
      stage(new Uint8Array(v), new Uint8Array(0));
      return 1;
    },

    async kv_put(nsPtr, keyPtr, valPtr, valLen) {
      clear();
      const ns = cstr(nsPtr), key = cstr(keyPtr);
      const b = kvLookup(ns);
      if (!b || typeof b.put !== "function") {
        return fail(E_ARG, `no KV namespace named ${JSON.stringify(ns)} is available to this worker`);
      }
      if (!key) return fail(E_ARG, "KV key must not be empty");
      if (valLen < 0) return fail(E_ARG, `negative value length: ${valLen}`);
      const val = u8().slice(valPtr >>> 0, (valPtr >>> 0) + valLen);   // copy before await
      counters.kvPuts++;
      counters.suspends++;
      try {
        await b.put(key, val);
      } catch (e) {
        return fail(E_NET, `KV ${ns}.put(${JSON.stringify(key)}): ${String((e && e.message) || e)}`);
      }
      stage(new Uint8Array(0), new Uint8Array(0));
      return 0;
    },

    // ---- R2 (E055) -------------------------------------------------------------
    // The whole point of R2 in this bridge is that bytes go in and the same
    // bytes come out.  Nothing here decodes, re-encodes, or inspects a body:
    // get stages `await obj.arrayBuffer()` verbatim and put sends the slice of
    // linear memory it was handed.  The object's *metadata* travels separately,
    // in the header slot, so a body can never be confused with a description of
    // itself.
    async r2_get(bktPtr, keyPtr) {
      clear();
      const name = cstr(bktPtr), key = cstr(keyPtr);
      const b = r2Lookup(name);
      if (!b || typeof b.get !== "function") return fail(E_ARG, noBucket(name));
      if (!key) return fail(E_ARG, "R2 key must not be empty");
      counters.r2Gets++; counters.suspends++;
      let obj;
      try { obj = await b.get(key); }
      catch (e) { return fail(E_NET, `R2 ${name}.get(${JSON.stringify(key)}): ${errText(e)}`); }
      // A miss is an answer (R003 §3-1): stage an empty result so the
      // accessors stay legal and report 0.  "absent" and "a zero-byte object"
      // stay distinguishable -- the latter returns 1 with an empty body.
      if (obj === null || obj === undefined) { stage(new Uint8Array(0), new Uint8Array(0)); return 0; }
      let bytes;
      try { bytes = new Uint8Array(await obj.arrayBuffer()); }
      catch (e) { return fail(E_NET, `R2 ${name}.get(${JSON.stringify(key)}): reading the body failed: ${errText(e)}`); }
      if (bytes.length > maxBody) {
        return fail(E_SPACE,
          `R2 ${name}.get(${JSON.stringify(key)}): object is ${bytes.length} bytes, over the ${maxBody}-byte host limit`);
      }
      stage(bytes, enc.encode(formatHeaderBlock(r2Meta(key, obj))));
      return 1;
    },

    async r2_head(bktPtr, keyPtr) {
      clear();
      const name = cstr(bktPtr), key = cstr(keyPtr);
      const b = r2Lookup(name);
      if (!b || typeof b.head !== "function") return fail(E_ARG, noBucket(name));
      if (!key) return fail(E_ARG, "R2 key must not be empty");
      counters.r2Gets++; counters.suspends++;
      let obj;
      try { obj = await b.head(key); }
      catch (e) { return fail(E_NET, `R2 ${name}.head(${JSON.stringify(key)}): ${errText(e)}`); }
      if (obj === null || obj === undefined) { stage(new Uint8Array(0), new Uint8Array(0)); return 0; }
      stage(new Uint8Array(0), enc.encode(formatHeaderBlock(r2Meta(key, obj))));
      return 1;
    },

    // meta is a "Name: value\n" block; only `content-type` is understood today
    // and anything else is passed to R2 as a custom metadata field, so a future
    // Ruby side needs no host change to use one.
    async r2_put(bktPtr, keyPtr, valPtr, valLen, metaPtr) {
      clear();
      const name = cstr(bktPtr), key = cstr(keyPtr);
      const b = r2Lookup(name);
      if (!b || typeof b.put !== "function") return fail(E_ARG, noBucket(name));
      if (!key) return fail(E_ARG, "R2 key must not be empty");
      if (valLen < 0) return fail(E_ARG, `negative value length: ${valLen}`);
      if (valLen > maxBody) {
        return fail(E_SPACE, `R2 ${name}.put(${JSON.stringify(key)}): ${valLen} bytes, over the ${maxBody}-byte host limit`);
      }
      let opts;
      try { opts = r2PutOptions(parseHeaderBlock(cstr(metaPtr))); }
      catch (e) { return fail(E_ARG, errText(e)); }
      // Copy out of linear memory BEFORE the await: a memory.grow across the
      // suspend detaches the ArrayBuffer this view is over.
      const val = u8().slice(valPtr >>> 0, (valPtr >>> 0) + valLen);
      counters.r2Puts++; counters.suspends++;
      let obj;
      try { obj = await b.put(key, val, opts); }
      catch (e) { return fail(E_NET, `R2 ${name}.put(${JSON.stringify(key)}): ${errText(e)}`); }
      stage(new Uint8Array(0), enc.encode(formatHeaderBlock(r2Meta(key, obj || {}))));
      return 0;
    },

    // R2 delete is idempotent: deleting an absent key is not an error there and
    // is not one here.  `SpinelHost::R2.delete?` (head-then-delete) is the Ruby
    // side's business, not a second host round trip baked into this one.
    async r2_delete(bktPtr, keyPtr) {
      clear();
      const name = cstr(bktPtr), key = cstr(keyPtr);
      const b = r2Lookup(name);
      if (!b || typeof b.delete !== "function") return fail(E_ARG, noBucket(name));
      if (!key) return fail(E_ARG, "R2 key must not be empty");
      counters.r2Deletes++; counters.suspends++;
      try { await b.delete(key); }
      catch (e) { return fail(E_NET, `R2 ${name}.delete(${JSON.stringify(key)}): ${errText(e)}`); }
      stage(new Uint8Array(0), new Uint8Array(0));
      return 0;
    },

    // Answers with a TABLE, not a body: an R2 key is arbitrary UTF-8 and may
    // contain a newline, so a line-oriented listing would be forgeable.  The
    // columns are fixed (key, size, etag, uploaded, content_type) and the
    // truncation state travels in the header slot.
    async r2_list(bktPtr, prefixPtr, limit, cursorPtr) {
      clear();
      const name = cstr(bktPtr);
      const b = r2Lookup(name);
      if (!b || typeof b.list !== "function") return fail(E_ARG, noBucket(name));
      const prefix = cstr(prefixPtr), cursor = cstr(cursorPtr);
      // R2 omits httpMetadata from a listing unless it is asked for, and an
      // absent content type would be indistinguishable from "stored without
      // one".  Ask for it.
      const opts = { include: ["httpMetadata"] };
      if (prefix) opts.prefix = prefix;
      if (cursor) opts.cursor = cursor;
      if (limit > 0) opts.limit = Math.min(limit, maxRows);
      counters.r2Lists++; counters.suspends++;
      let res;
      try { res = await b.list(opts); }
      catch (e) { return fail(E_NET, `R2 ${name}.list(): ${errText(e)}`); }
      const objs = res?.objects || [];
      if (objs.length > maxRows) {
        return fail(E_SPACE, `R2 ${name}.list(): ${objs.length} objects, over the ${maxRows}-row host limit`);
      }
      stagedTable = {
        cols: ["key", "size", "etag", "uploaded", "content_type"],
        rows: objs.map((o) => [
          cell(o.key), cell(o.size ?? 0), cell(o.etag ?? o.httpEtag ?? null),
          cell(isoOf(o.uploaded)), cell(o.httpMetadata?.contentType ?? null),
        ]),
      };
      stage(new Uint8Array(0), enc.encode(formatHeaderBlock([
        ["count", String(objs.length)],
        ["truncated", res?.truncated ? "1" : "0"],
        ["cursor", res?.cursor ?? ""],
      ])));
      return objs.length;
    },

    // ---- D1 (E055) -------------------------------------------------------------
    // Placeholder values are accumulated one at a time, each through the import
    // named for its TYPE.  That is not ceremony: it is the only place where the
    // Ruby program's static type survives all the way to the database.  An
    // Integer arrives as an i64 and is bound as a number; a String arrives as
    // (ptr, len) and is bound as TEXT, byte-exact, whatever it contains -- there
    // is no path by which a value can be spliced into the SQL text.
    d1_bind_reset() { binds = []; return 0; },
    d1_bind_null() { binds.push(null); return 0; },
    d1_bind_int(v) {
      // The wasm side has a real 64-bit Integer (SP_INT64, E010); a JS number
      // does not.  Refuse rather than round: this is precisely the "silently
      // different answer" E010 removed for mrb_int in the first place.
      const n = typeof v === "bigint" ? v : BigInt(Math.trunc(Number(v)));
      if (n > 9007199254740991n || n < -9007199254740991n) {
        return fail(E_ARG,
          `D1 bind: ${n} does not fit a JS number without losing precision ` +
          `(|v| > 2^53-1).  Bind it as text if the column is TEXT.`);
      }
      binds.push(Number(n));
      return 0;
    },
    d1_bind_real(v) { binds.push(Number(v)); return 0; },
    d1_bind_text(ptr, len) {
      if (len < 0) return fail(E_ARG, `negative text length: ${len}`);
      binds.push(dec.decode(u8().subarray(ptr >>> 0, (ptr >>> 0) + len)));
      return 0;
    },
    d1_bind_blob(ptr, len) {
      if (len < 0) return fail(E_ARG, `negative blob length: ${len}`);
      // D1 takes a BLOB parameter as an Array of byte values.
      binds.push(Array.from(u8().subarray(ptr >>> 0, (ptr >>> 0) + len)));
      return 0;
    },

    // One statement, bound, run.  `prepare(...).bind(...).all()` and never
    // `db.exec()`: D1's prepare takes a SINGLE statement, so the classic
    // `'; DROP TABLE …` payload cannot become a second statement no matter what
    // a bound value contains.  Returns the number of rows staged (0 for a
    // write); the meta (changes / last_row_id / duration) goes to the header
    // slot, so a write is still fully described.
    async d1_exec(dbPtr, sqlPtr) {
      const sql = cstr(sqlPtr), name = cstr(dbPtr);
      const params = binds;
      binds = [];                       // consumed, whatever happens next
      clear();
      const db = d1Lookup(name);
      if (!db || typeof db.prepare !== "function") {
        return fail(E_ARG, `no D1 database named ${JSON.stringify(name)} is available to this worker`);
      }
      if (!sql.trim()) return fail(E_ARG, "D1 statement must not be empty");
      counters.d1Execs++; counters.suspends++;
      let res;
      try {
        let st = db.prepare(sql);
        if (params.length) st = st.bind(...params);
        res = await st.all();
      } catch (e) {
        // Syntax errors, constraint violations and "wrong number of parameter
        // bindings" all arrive here.  They are the program's fault, not the
        // world's, so they are E_SQL (-> ArgumentError) and not E_NET.
        return fail(E_SQL, `D1 ${name}: ${errText(e)}`);
      }
      const rows = res?.results || [];
      if (rows.length > maxRows) {
        return fail(E_SPACE, `D1 ${name}: ${rows.length} rows, over the ${maxRows}-row host limit`);
      }
      // Column order comes from the first row's key order, which is the
      // SELECT order D1 preserves.  A zero-row result has no columns to report
      // and says so (tbl_cols() == 0) rather than inventing them.
      const cols = rows.length ? Object.keys(rows[0]) : [];
      try {
        stagedTable = { cols, rows: rows.map((r) => cols.map((c) => cell(r[c]))) };
      } catch (e) {
        return fail(E_HOST, `D1 ${name}: ${errText(e)}`);
      }
      const meta = res?.meta || {};
      stage(new Uint8Array(0), enc.encode(formatHeaderBlock([
        ["rows", String(rows.length)],
        ["changes", String(meta.changes ?? 0)],
        ["last_row_id", String(meta.last_row_id ?? 0)],
        ["duration_ms", String(meta.duration ?? 0)],
      ])));
      return rows.length;
    },

    // ---- the table accessors (E055) --------------------------------------------
    // Synchronous, side-effect free, idempotent -- the same contract the body
    // and header accessors have, for the same reason: nothing that can be
    // called while a suspend is outstanding may itself suspend.
    tbl_rows: () => (stagedTable ? stagedTable.rows.length : fail(E_STAGE, noTable())),
    tbl_cols: () => (stagedTable ? stagedTable.cols.length : fail(E_STAGE, noTable())),
    tbl_col_name_len(i) {
      if (!stagedTable) return fail(E_STAGE, noTable());
      if (i < 0 || i >= stagedTable.cols.length) return fail(E_ARG, `column ${i} out of range (0..${stagedTable.cols.length - 1})`);
      return enc.encode(stagedTable.cols[i]).length;
    },
    tbl_col_name(i, ptr, cap) {
      if (!stagedTable) return fail(E_STAGE, noTable());
      if (i < 0 || i >= stagedTable.cols.length) return fail(E_ARG, `column ${i} out of range (0..${stagedTable.cols.length - 1})`);
      return copyOut(enc.encode(stagedTable.cols[i]), ptr, cap);
    },
    tbl_cell_type(r, c) {
      const v = cellAt(r, c); return typeof v === "number" ? v : v.t;
    },
    tbl_cell_len(r, c) {
      const v = cellAt(r, c); return typeof v === "number" ? v : v.b.length;
    },
    tbl_cell_read(r, c, ptr, cap) {
      const v = cellAt(r, c); return typeof v === "number" ? v : copyOut(v.b, ptr, cap);
    },

    // ---- synchronous accessors ------------------------------------------------
    res_body_len: lengthOf(() => stagedBody),
    res_body_read: drain(() => stagedBody),
    res_headers_len: lengthOf(() => stagedHeaders),
    res_headers_read: drain(() => stagedHeaders),

    last_error(ptr, cap) {
      if (!lastError) return 0;
      const b = enc.encode(lastError);
      const n = Math.min(b.length, Math.max(0, cap));
      u8().set(b.subarray(0, n), ptr >>> 0);
      return n;
    },
  };

  return { fns, suspending: SUSPENDING, counters };
}

// A host that answers "not here" to everything.  Used when a module built with
// --host-api runs somewhere that supplies no host API: every call returns
// E_NOSYS, the C thunk turns that into a catchable NotImplementedError, and
// the program can rescue it -- the same shape every other absent facility on
// this target has (E012).  No import is suspending, so no JSPI is engaged and
// the module runs on a plain node with no flags.
export function absentHostApi() {
  return { fns: new Proxy({}, { get: () => () => E_NOSYS, has: () => true }), suspending: [] };
}
