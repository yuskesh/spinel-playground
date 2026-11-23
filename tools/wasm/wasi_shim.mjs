// tools/wasm/wasi_shim.mjs -- the entire host surface a Spinel wasm32-wasip1
// module needs, as a small JS shim.  No WASI runtime, no node:wasi: this is
// what a Cloudflare Worker (or any bare V8 embedder) can supply.
//
// Adapted from docs/experiments/results/E009/worker/wasi_shim.mjs (E009 §8-3
// measured the import list: the same 15 functions for every Spinel program).
// E011 adds the reactor half: instantiateReactor() / handle.call().
// E012 adds the raise-policy fixes (filetype, clock_time_get, fd_readdir,
// host-supplied environ).  E013 adds the request/response lifecycle: args_get
// (ARGV), fd_read (stdin) and *byte-exact* capture of fd_write.
//
// stdout and stderr are captured, so one instance can serve many calls and each
// call gets its own output.
//
// E013: capture is a list of Uint8Array chunks, not a string.  fd_write used to
// TextDecoder-decode every chunk on its own, which corrupts any multi-byte
// character that Ruby's stdio happens to split across two writes (and destroys
// non-UTF-8 bytes outright).  A Worker hands the buffer straight to Response,
// so the bytes must survive.  `.out` / `.err` stay available as decoded strings
// for the node callers; `.outBytes()` / `.errBytes()` are the raw form.

const ENOSYS = 52, EBADF = 8, EINVAL = 28;

// WASI filetypes.  E012: stdout used to be declared CHARACTER_DEVICE, which is
// exactly what wasi-libc's isatty() looks for -- so `STDOUT.tty?` answered
// *true* on a target whose stdout is a string buffer, while the native build
// answers false (R003 §3-2).  UNKNOWN is the honest filetype here and makes
// isatty() return 0.  Side effect: stdio switches from line- to full-buffering,
// which changes nothing about the bytes as long as they are flushed (crt1 runs
// __wasm_call_dtors; reactor.c calls fflush(NULL)).
const FILETYPE_UNKNOWN = 0;

export class WasiExit extends Error {
  constructor(code) { super("wasi proc_exit(" + code + ")"); this.code = code; }
}

// ---- per-request garbage (feat/wasm-less-garbage) --------------------------
// A command module is instantiated for every request (an arena module built
// for reuse is instead written back from a copy of its memory: see "instance
// reuse" below), and everything the shim allocates for one request is garbage
// by the next.  Every request must start from a new instance's bytes -- that is
// the isolation model -- but the
// shim's own parts need not: the import functions, the byte buffers they write
// into and the encoder can live as long as the isolate.  So the shim keeps a
// pool of SLOTS.  A slot owns one set of import closures and its buffers; a
// request takes a free slot, resets it, runs, copies its output out, and gives
// it back cleared.  Concurrent requests in one isolate (workerd interleaves
// them at every JSPI suspension) each hold their own slot, so nothing is
// shared between two requests in flight.
//
// ISOLATION, the hard rule.  Nothing of one request may be observable in the
// next.  configure() overwrites every per-request field before the module can
// run: argv and environ are re-encoded from scratch, the output buffers'
// lengths go to 0 (and nothing ever reads past a buffer's length), stdin and
// its read position are replaced, the exit status is cleared, and the memory
// views are dropped.  release() clears them again and drops every reference, so
// a pooled slot holds nothing of the request that used it.  The per-request
// `state` object handed to callers is new each time and is detached from the
// slot when the request ends: afterwards it answers from its own copies.
// tests/edge/isolation.mjs holds this: two different requests in a row, the
// second's response must carry nothing of the first.

const ENC = new TextEncoder();
const DEC = new TextDecoder();

// A growable byte buffer.  `len` is the only valid extent: bytes past it are
// left over from an earlier request and are never read.
class ByteBuf {
  constructor(n) { this.b = new Uint8Array(n); this.len = 0; }
  reset() { this.len = 0; }
  reserve(extra) {
    const need = this.len + extra;
    if (need <= this.b.length) return;
    let n = this.b.length * 2;
    while (n < need) n *= 2;
    const nb = new Uint8Array(n);
    nb.set(this.b.subarray(0, this.len));
    this.b = nb;
  }
  push(src) { this.reserve(src.length); this.b.set(src, this.len); this.len += src.length; }
  pushByte(x) { this.reserve(1); this.b[this.len++] = x; }
  pushStr(str) {                      // UTF-8, worst case 3 bytes per UTF-16 unit
    this.reserve(str.length * 3);
    // ASCII, the usual case for argv and environ, is copied byte by byte:
    // encodeInto would allocate a view and a result object on every call.
    const b = this.b, n = str.length, start = this.len;
    let i = 0;
    for (; i < n; i++) {
      const c = str.charCodeAt(i);
      if (c > 0x7f) break;
      b[start + i] = c;
    }
    if (i === n) { this.len = start + n; return; }
    this.len = start + i + ENC.encodeInto(str.slice(i), b.subarray(start + i)).written;
  }
  bytes() { return this.b.slice(0, this.len); }   // an owned copy
}

// One NUL-terminated list (argv or environ): the bytes, and each entry's start.
class CStrList {
  constructor(n) { this.buf = new ByteBuf(n); this.off = []; }
  reset() { this.buf.reset(); this.off.length = 0; }
  begin() { this.off.push(this.buf.len); }
  end() { this.buf.pushByte(0); }
  add(str) { this.begin(); this.buf.pushStr(str); this.end(); }
}

// The per-request state a caller sees (state.mem, state.exited, state.host,
// .out/.err/.outBytes()/.errBytes()).  While the request runs it reads the
// slot's buffers; detach() copies them out, and from then on it answers from
// the copies, so a state kept after the slot is reused shows only its own
// request.
class RequestState {
  constructor(slot) { this._slot = slot; this._out = null; this._err = null; this.mem = null; this.exited = null; }
  outBytes() { return this._slot ? this._slot.out.bytes() : this._out; }
  errBytes() { return this._slot ? this._slot.err.bytes() : this._err; }
  get out() { return DEC.decode(this.outBytes()); }
  get err() { return DEC.decode(this.errBytes()); }
  // The pre-E013 string interface: `state.out = ""` is the reactor's per-call reset.
  set out(v) { const b = this._slot.out; b.reset(); if (v) b.pushStr(String(v)); }
  set err(v) { const b = this._slot.err; b.reset(); if (v) b.pushStr(String(v)); }
  get stdinRead() { return this._slot ? this._slot.stdinRead : 0; }
  detach() { if (!this._slot) return; this._out = this._slot.out.bytes(); this._err = this._slot.err.bytes(); this._slot = null; }
}

function createSlot() {
  const slot = {
    state: null, stdin: null, stdinRead: 0, onWrite: null,
    buf: null, dv: null, u8: null,              // views of the current memory
    out: new ByteBuf(4096), err: new ByteBuf(512),
    argv: new CStrList(256), env: new CStrList(1024),
  };
  // Views are rebuilt only when the memory's buffer changes (a memory.grow
  // detaches the old one), not on every import call.
  const views = () => {
    const b = slot.state.mem.buffer;
    if (b !== slot.buf) { slot.buf = b; slot.dv = new DataView(b); slot.u8 = new Uint8Array(b); }
  };
  const putList = (list, ptrs, buf) => {
    views();
    const { dv, u8 } = slot;
    const bytes = list.buf.b;
    for (let i = 0; i < list.off.length; i++) {
      const s = list.off[i], e = i + 1 < list.off.length ? list.off[i + 1] : list.buf.len;
      dv.setUint32(ptrs + i * 4, buf + s, true);
      u8.set(bytes.subarray(s, e), buf + s);
    }
    return 0;
  };
  const putSizes = (list, c, s) => {
    views();
    slot.dv.setUint32(c, list.off.length, true);
    slot.dv.setUint32(s, list.buf.len, true);
    return 0;
  };

  const fd_write = (fd, iovs, iovsLen, nwrittenPtr) => {
    if (fd !== 1 && fd !== 2) return EBADF;
    views();
    const { dv, u8 } = slot;
    const dst = fd === 1 ? slot.out : slot.err;
    const start = dst.len;
    let n = 0;
    for (let i = 0; i < iovsLen; i++) {
      const p = dv.getUint32(iovs + i * 8, true);
      const l = dv.getUint32(iovs + i * 8 + 4, true);
      // Copied into the slot's buffer: the capture must own its bytes (the
      // module keeps writing to its heap, and memory.grow detaches it).
      dst.push(u8.subarray(p, p + l));
      n += l;
    }
    // onWrite gets a VIEW of just these bytes, valid during the call only.
    if (slot.onWrite) slot.onWrite(fd, dst.b.subarray(start, dst.len));
    slot.dv.setUint32(nwrittenPtr, n, true);
    return 0;
  };

  // E013: the request body.  Ruby's $stdin.read loops until a short/zero read,
  // so a partial fill is fine and 0 means EOF.
  const fd_read = (fd, iovs, iovsLen, nreadPtr) => {
    if (fd !== 0) return EBADF;
    views();
    const { dv, u8 } = slot;
    const stdin = slot.stdin;
    let n = 0;
    if (stdin) {
      for (let i = 0; i < iovsLen && slot.stdinRead < stdin.length; i++) {
        const p = dv.getUint32(iovs + i * 8, true);
        const l = dv.getUint32(iovs + i * 8 + 4, true);
        const take = Math.min(l, stdin.length - slot.stdinRead);
        u8.set(stdin.subarray(slot.stdinRead, slot.stdinRead + take), p);
        slot.stdinRead += take;
        n += take;
      }
    }
    dv.setUint32(nreadPtr, n, true);
    return 0;
  };

  const wasi = {
    // E013: ARGV.  Spinel drops argv[0], so the first entry is the program
    // name and the Ruby program sees opts.args at ARGV[0..].
    args_get: (ptrs, buf) => putList(slot.argv, ptrs, buf),
    args_sizes_get: (c, s) => putSizes(slot.argv, c, s),
    environ_get: (ptrs, buf) => putList(slot.env, ptrs, buf),
    environ_sizes_get: (c, s) => putSizes(slot.env, c, s),
    fd_close: () => 0,
    fd_fdstat_get: (fd, ptr) => {
      views();
      const dv = slot.dv;
      dv.setUint8(ptr, FILETYPE_UNKNOWN);   // NOT character_device: see above
      dv.setUint16(ptr + 2, 0, true);
      dv.setBigUint64(ptr + 8, 0n, true);
      dv.setBigUint64(ptr + 16, 0n, true);
      return fd <= 2 ? 0 : EBADF;
    },
    fd_fdstat_set_flags: () => 0,
    fd_prestat_get: () => EBADF,          // no preopened dirs -> no filesystem
    fd_prestat_dir_name: () => EBADF,
    fd_read,
    // E012: Dir programs import fd_readdir, and a missing import is a
    // *LinkError at instantiate* -- the module never starts and the message
    // names a WASI function, not a Ruby construct (R003 §1-5).  It is present
    // so the module instantiates, and it reports ENOSYS rather than an empty
    // directory: "no directory" and "empty directory" must stay
    // distinguishable (R003 §3-1).  In practice path_open refuses first, so a
    // Dir program raises a plain Errno on the *open*.
    fd_readdir: () => ENOSYS,
    fd_seek: (fd, off, whence, ptr) => { views(); slot.dv.setBigUint64(ptr, 0n, true); return ENOSYS; },
    // Added in spinel-extended: the pinned runtime is newer than spinel-llvm's
    // and links fstat/pread/send, so the module imports these three, and a
    // missing import is a LinkError at instantiate for every program. They
    // report ENOSYS, as path_filestat_get and fd_seek do: fstat is reached only
    // by File#stat/#size/#mode-style accessors (sp_cold.c), which then answer
    // nil rather than an invented size; pread has no filesystem to read; and
    // this shim has no sockets (sp_net.c is not even linked).
    fd_filestat_get: () => ENOSYS,
    fd_pread: () => ENOSYS,
    sock_send: () => ENOSYS,
    // Upstream Spinel f8ff01939's runtime links recv as well, so the module
    // imports sock_recv; ENOSYS, as sock_send, for the same reason.
    sock_recv: () => ENOSYS,
    fd_write,
    // E012: without clock_time_get every program that touches Time.now failed
    // to instantiate (R003 §1-5).  The host has the real answer here, so the
    // policy says import, not raise (R003 §3-1 corollary (a)).
    clock_time_get: (id, precision, ptr) => {
      let ns;
      if (id === 0) ns = BigInt(Math.round(Date.now() * 1e6));        // realtime
      else if (id === 1) ns = BigInt(Math.round(perfNow() * 1e6));    // monotonic
      else return EINVAL;   // process/thread cputime: no honest answer here
      views();
      slot.dv.setBigUint64(ptr, ns, true);
      return 0;
    },
    clock_res_get: (id, ptr) => {
      if (id > 1) return EINVAL;
      views();
      slot.dv.setBigUint64(ptr, 1000n, true);   // 1 us: what Date.now/perf give
      return 0;
    },
    path_filestat_get: () => ENOSYS,
    path_open: () => ENOSYS,
    poll_oneoff: () => ENOSYS,
    random_get: (ptr, len) => { views(); crypto.getRandomValues(slot.u8.subarray(ptr, ptr + len)); return 0; },
    sched_yield: () => 0,
    proc_exit: (code) => { slot.state.exited = code; throw new WasiExit(code); },
  };
  slot.imports = { wasi_snapshot_preview1: wasi };

  // Every per-request field, overwritten before the module can run.
  slot.configure = (opts) => {
    slot.state = new RequestState(slot);
    slot.buf = slot.dv = slot.u8 = null;
    slot.out.reset();
    slot.err.reset();
    slot.argv.reset();
    slot.argv.add(String(opts.argv0 ?? "spinel"));
    for (const a of opts.args || []) slot.argv.add(String(a));
    slot.env.reset();
    const env = opts.env || {};
    for (const k in env) {
      if (!Object.prototype.hasOwnProperty.call(env, k)) continue;
      slot.env.begin(); slot.env.buf.pushStr(k); slot.env.buf.pushByte(0x3d);   // "="
      slot.env.buf.pushStr(String(env[k])); slot.env.end();
    }
    let stdin = opts.stdin ?? null;
    if (typeof stdin === "string") stdin = ENC.encode(stdin);
    else if (stdin instanceof ArrayBuffer) stdin = new Uint8Array(stdin);
    slot.stdin = stdin;
    slot.stdinRead = 0;
    slot.onWrite = opts.onWrite ?? null;
    return slot.state;
  };
  // Back to the pool: the state is detached (it keeps its own copies) and the
  // slot drops every reference it held for the request, so a pooled slot keeps
  // nothing alive.  The CONTENTS are reset in exactly one place, configure(),
  // before anything can read them -- one place, so that tests/edge/
  // isolation.mjs fails if any one of those resets is removed.
  slot.clear = () => {
    if (slot.state) slot.state.detach();
    slot.state = null; slot.stdin = null; slot.onWrite = null;
    slot.buf = slot.dv = slot.u8 = null;
  };
  return slot;
}

const POOL_MAX = 16;            // free slots kept; more concurrency just allocates
const pool = [];

// Take a slot configured for one request.  Pair every call with releaseWasi.
export function acquireWasi(opts = {}) {
  const slot = pool.pop() ?? createSlot();
  const state = slot.configure(opts);
  return { slot, state, imports: slot.imports };
}
export function releaseWasi(slot) {
  slot.clear();
  if (pool.length < POOL_MAX) pool.push(slot);
}

// opts.env    plain object written into environ_get / environ_sizes_get.
//             Default {} -- a Worker has no ambient environment, it has
//             bindings, and the caller is the only one who knows which of them
//             to expose (R003 §2-4 layer 0).
// opts.args   Ruby-visible ARGV, as an array of strings.  argv[0] is supplied
//             by the shim (opts.argv0, default "spinel") because Spinel drops
//             it, exactly like reactor.c does for the reactor path.
// opts.stdin  Uint8Array | ArrayBuffer | string.  What fd_read hands out; EOF
//             once exhausted.  Default: immediate EOF.
// opts.onWrite(fd, bytes)  called for every fd_write, before capture.  The
//             Worker uses it to mirror fd 2 to console.error while the request
//             is still running.  `bytes` is a view valid during the call only.
//
// makeWasi gives an UNPOOLED slot, for a caller that keeps it (the reactor):
// the same code as the pool, never handed to another request.
export function makeWasi(opts = {}) {
  const slot = createSlot();
  const state = slot.configure(opts);
  return { state, imports: slot.imports };
}

// performance.now() where it exists (node, workerd), Date.now() otherwise.
const perfNow = (typeof performance !== "undefined" && performance.now)
  ? () => performance.now()
  : () => Date.now();

// ---- the second import namespace: `spinel_host` (E014) ----------------------
// R003 §2-4 layer 1.  A module built with `spinel-wasm --host-api` and using
// any host function imports from "spinel_host" as well as from WASI.  This
// layer stays generic: it knows the namespace name, how to wrap a suspending
// import, and how to enter a module that has one.  What the functions *do* is
// tools/wasm/spinel_host.mjs.
export const HOST_NS = "spinel_host";

// -6 == E_NOSYS in sp_wasm_host.c / spinel_host.mjs.  Keep the three in step.
const HOST_E_NOSYS = -6;

// Does this module want a host API at all?  Asked of the compiled module, not
// of a build flag: a program that declares no ffi_func imports nothing here
// even when built with --host-api (--gc-sections drops the unreferenced thunk
// and its import with it), so the module is the only honest source of truth.
// The names this module imports from `spinel_host`, asked of the module once
// and remembered: WebAssembly.Module.imports() builds a fresh array of
// descriptors on every call, and the answer never changes for a module.
const hostNamesOf = new WeakMap();
function hostNames(mod) {
  let names = hostNamesOf.get(mod);
  if (!names) {
    names = WebAssembly.Module.imports(mod).filter((i) => i.module === HOST_NS).map((i) => i.name);
    hostNamesOf.set(mod, names);
  }
  return names;
}
export function moduleNeedsHost(mod) {
  return hostNames(mod).length > 0;
}

// Build the `spinel_host` namespace for exactly the names this module imports.
// A name the host does not implement gets the same "not here" answer as no
// host at all, so a newer module against an older host degrades to a catchable
// NotImplementedError rather than a LinkError with a C symbol in it.
function bindHostApi(mod, api) {
  const want = hostNames(mod);
  const suspending = new Set(api?.suspending || []);
  const table = {};
  let anySuspending = false;
  for (const name of want) {
    const fn = api?.fns?.[name];
    if (typeof fn !== "function") { table[name] = () => HOST_E_NOSYS; continue; }
    if (!suspending.has(name)) { table[name] = fn; continue; }
    if (typeof WebAssembly.Suspending !== "function") {
      throw new Error(
        "spinel: this host API needs JSPI (WebAssembly.Suspending), which this " +
        "runtime does not have.  workerd has it by default; node needs " +
        "--experimental-wasm-jspi.  (R003 §2-3)");
    }
    // The C side calls this synchronously and does not change at all; JSPI
    // suspends the whole wasm stack across the await and resumes it with the
    // i32 the promise settles to (R003 §2-3, probes B/C).
    table[name] = new WebAssembly.Suspending(fn);
    anySuspending = true;
  }
  return { table, anySuspending };
}

// ---- instance reuse for arena modules (decision 0039) ------------------------
// Making an instance is most of a small request's CPU time on Cloudflare (a
// median of 2 ms even for a 168 B module; docs/edge/workers-limits.md).  An
// arena module built by spinel-wasm carries the contract in
// tools/wasm/snapshot.c: it exports `spinel_snapshot_abi` and
// `__stack_pointer`, and its sbrk keeps the heap break in linear memory.  For
// such a module this shim keeps ONE instance per module per isolate.  Right
// after instantiation, before `_start` has run, it copies the linear memory;
// before every request it writes the copy back, zeroes the rest and resets the
// stack pointer.  Each request therefore starts from the bytes a new instance
// would have: no Ruby state, no heap and no output of an earlier request
// survives.  The WASI and host imports are bound when the instance is made, so
// they forward to whichever request is running.
//
// The fallbacks, each to a new instance for the request, as before 0039:
//   - the shared instance is running another request.  One request runs to
//     completion at a time on an isolate unless the module waits on the host
//     (a suspending host import under JSPI); then a second request gets its
//     own instance instead of the shared memory;
//   - the request's host API suspends on a different set of imports than the
//     one the instance was made with;
//   - opts.snapshot === false, or the module lacks the contract.
// The shared instance is dropped, and made again for the next request, after a
// trap (anything but proc_exit) and after a request that left its memory
// larger than SNAPSHOT_MAX_BYTES, because every later write-back would have to
// zero all of it.
const SNAPSHOT_ABI = 1;
const SNAPSHOT_MAX_BYTES = 16 * 1024 * 1024;

// Per isolate: instances made for reuse, requests they served, and requests
// that took a new instance although the module could have been reused.
export const snapshotStats = { instances: 0, reused: 0, fallbacks: 0 };

const WASI_NAMES = Object.keys(createSlot().imports.wasi_snapshot_preview1);

const capableOf = new WeakMap();
function snapshotCapable(mod) {
  let c = capableOf.get(mod);
  if (c === undefined) {
    const ex = WebAssembly.Module.exports(mod);
    const has = (name, kind) => ex.some((e) => e.name === name && e.kind === kind);
    c = has("spinel_snapshot_abi", "function") && has("__stack_pointer", "global") &&
        has("memory", "memory") && has("_start", "function");
    capableOf.set(mod, c);
  }
  return c;
}

// The host imports this request's API suspends on (and implements), as one key.
function suspendKey(mod, api) {
  const s = new Set(api?.suspending || []);
  return hostNames(mod).filter((n) => s.has(n) && typeof api?.fns?.[n] === "function").sort().join(",");
}

// One shared entry per module, or the promise of it while it is being made, so
// that requests arriving together on a new isolate share one instance.
const entryOf = new WeakMap();
function snapshotEntry(mod, api) {
  let e = entryOf.get(mod);
  if (!e) {
    // The entry remembers the promise it is stored under, so that dropping it
    // (dropEntry) removes this entry and never a newer one.
    e = makeEntry(mod, api).then((x) => { if (x) x.promise = e; return x; },
                                 (err) => { entryOf.delete(mod); throw err; });
    entryOf.set(mod, e);
  }
  return e;
}
function dropEntry(mod, entry) {
  if (entryOf.get(mod) === entry.promise) entryOf.delete(mod);
}

// The imports of a shared instance.  Each forwards to the request that is
// running; `key` names the host imports wrapped as Suspending.
function entryImports(mod, key) {
  const fwd = { slot: null, host: null };
  const wasi = {};
  for (const n of WASI_NAMES) wasi[n] = (...a) => fwd.slot.imports.wasi_snapshot_preview1[n](...a);
  const imports = { wasi_snapshot_preview1: wasi };
  const names = hostNames(mod);
  if (names.length) {
    const susp = new Set(key ? key.split(",") : []);
    if (susp.size && typeof WebAssembly.Suspending !== "function") {
      throw new Error("spinel: this host API needs JSPI (WebAssembly.Suspending), which this " +
                      "runtime does not have.  workerd has it by default; node needs " +
                      "--experimental-wasm-jspi.  (R003 §2-3)");
    }
    const table = {};
    for (const n of names) {
      const f = (...a) => fwd.host[n](...a);
      table[n] = susp.has(n) ? new WebAssembly.Suspending(f) : f;
    }
    imports[HOST_NS] = table;
  }
  return { imports, fwd };
}

// `made` is "startup" for an instance prepareModule made, "request" for one a
// request made.
function finishEntry(inst, fwd, key, made) {
  const ex = inst.exports;
  if (ex.spinel_snapshot_abi() !== SNAPSHOT_ABI) return null;
  snapshotStats.instances++;
  return {
    inst, fwd, key, made, busy: false, calls: 0,
    image: new Uint8Array(ex.memory.buffer).slice(),
    sp: ex.__stack_pointer.value,
    start: key ? WebAssembly.promising(ex._start) : null,
  };
}

async function makeEntry(mod, api) {
  const key = suspendKey(mod, api);
  const { imports, fwd } = entryImports(mod, key);
  return finishEntry(await WebAssembly.instantiate(mod, imports), fwd, key, "request");
}

// Makes the shared instance now, synchronously, so that a Worker can make it
// at global scope: the instantiation then counts in the isolate's startup (1 s
// allowed on Workers) and not in its first request.  Only for a module that
// allows reuse and imports no host function, since which host imports suspend
// is known only from a request's env.  Returns true if it made the instance;
// false if the module is not eligible or already has one.
export function prepareModule(mod) {
  if (!snapshotCapable(mod) || hostNames(mod).length || entryOf.has(mod)) return false;
  const { imports, fwd } = entryImports(mod, "");
  const x = finishEntry(new WebAssembly.Instance(mod, imports), fwd, "", "startup");
  if (!x) return false;
  x.promise = Promise.resolve(x);
  entryOf.set(mod, x.promise);
  return true;
}

// One request on the shared instance.  Everything up to the first await runs
// synchronously, so `busy` is set before another request can look at it.
async function runReused(mod, entry, slot, state, api) {
  const ex = entry.inst.exports;
  entry.busy = true;
  try {
    const mem = new Uint8Array(ex.memory.buffer);
    mem.set(entry.image);
    if (mem.length > entry.image.length) mem.fill(0, entry.image.length);
    ex.__stack_pointer.value = entry.sp;
    entry.fwd.slot = slot;
    if (hostNames(mod).length) {
      const raw = {};
      for (const n of hostNames(mod)) {
        const f = api?.fns?.[n];
        raw[n] = typeof f === "function" ? f : () => HOST_E_NOSYS;
      }
      entry.fwd.host = raw;
    }
    state.mem = ex.memory;
    let code = 0;
    try {
      if (entry.start) await entry.start();
      else ex._start();
    } catch (e) {
      if (e instanceof WasiExit) code = e.code;
      else { dropEntry(mod, entry); throw e; }
    }
    entry.calls++;
    snapshotStats.reused++;
    if (ex.memory.buffer.byteLength > SNAPSHOT_MAX_BYTES) dropEntry(mod, entry);
    return { code, instance: { reused: true, call: entry.calls, made: entry.made } };
  } finally {
    entry.fwd.slot = null;
    entry.fwd.host = null;
    entry.busy = false;
  }
}

// ---- command modules (crt1.o, `_start`) -------------------------------------
// `stdout` / `stderr` are decoded strings (what the node callers want);
// `stdoutBytes` / `stderrBytes` are the exact bytes the module wrote, which is
// what a Worker puts in the Response.  `instance` says which instance served
// the request: { reused: true, call: N, made } on a reused arena instance (N
// counts its requests; made is "startup" or "request"), { reused: false } on a
// new one.
//
// opts.host   (state) => { fns, suspending } | { fns, suspending } | undefined.
//             Consulted only when the module actually imports from
//             `spinel_host`.  Undefined means "no host API here": every host
//             import answers E_NOSYS, the C thunk raises a catchable
//             NotImplementedError, and -- because nothing is suspending -- the
//             module still runs on a runtime with no JSPI at all.
// opts.snapshot  false: never reuse an instance, even for a module that
//             allows it (decision 0039).
export async function runModule(mod, opts = {}) {
  const { slot, state, imports: wasiImports } = acquireWasi(opts);
  const done = (code, instance) => {
    state.detach();                     // the output is copied out of the slot
    state.mem = null;                   // nothing keeps the instance's memory
    const stdoutBytes = state.outBytes(), stderrBytes = state.errBytes();
    return {
      code, state, stdoutBytes, stderrBytes, instance,
      // decoded only when asked: a Worker uses the bytes
      get stdout() { return DEC.decode(stdoutBytes); },
      get stderr() { return DEC.decode(stderrBytes); },
    };
  };
  try {
    const needsHost = moduleNeedsHost(mod);
    const api = needsHost ? (typeof opts.host === "function" ? opts.host(state) : opts.host) : undefined;
    if (needsHost) state.host = api;
    if (opts.snapshot !== false && snapshotCapable(mod)) {
      const entry = await snapshotEntry(mod, api);
      if (entry && !entry.busy && entry.key === suspendKey(mod, api)) {
        const r = await runReused(mod, entry, slot, state, api);
        return done(r.code, r.instance);
      }
      snapshotStats.fallbacks++;
    }
    let imports = wasiImports;
    let promising = false;
    if (needsHost) {
      const bound = bindHostApi(mod, api);
      // A fresh outer object for this request only: the slot's own imports
      // never carry a host table, so no request's host API outlives it there.
      imports = { ...wasiImports, [HOST_NS]: bound.table };
      promising = bound.anySuspending;
    }
    const inst = await WebAssembly.instantiate(mod, imports);
    state.mem = inst.exports.memory;
    let code = 0;
    try {
      // With a suspending import in the table, _start must be entered through
      // WebAssembly.promising: a Suspending import called from a plain (non
      // -promising) stack traps.  Without one, the synchronous call is kept
      // byte-for-byte as it was -- JSPI is engaged only when a real host is
      // attached (R003 §2-5: opt-in, never the default).
      if (promising) await WebAssembly.promising(inst.exports._start)();
      else inst.exports._start();
    }
    catch (e) { if (e instanceof WasiExit) code = e.code; else throw e; }
    return done(code, { reused: false });
  } finally {
    releaseWasi(slot);
  }
}

// ---- reactor modules (crt1-reactor.o, `_initialize` + sp_reactor_run) -------
// instantiateReactor() runs libc setup + C constructors exactly once.  The
// returned handle can then serve any number of calls; each call() builds a
// fresh argv inside the module's memory and enters main() through the wrapper
// in tools/wasm/reactor.c.
export async function instantiateReactor(mod, opts = {}) {
  const { state, imports } = makeWasi(opts);
  const inst = await WebAssembly.instantiate(mod, imports);
  const ex = inst.exports;
  state.mem = ex.memory;
  ex._initialize();
  const enc = new TextEncoder();

  return {
    instance: inst,
    exports: ex,
    state,
    pages: () => ex.memory.buffer.byteLength / 65536,
    calls: () => ex.sp_reactor_calls(),
    gcBytes: () => ex.sp_reactor_gc_bytes(),
    strBytes: () => ex.sp_reactor_str_bytes(),
    roots: () => ex.sp_reactor_gc_roots(),
    gc: () => ex.sp_reactor_gc(),
    call(args = []) {
      state.out = ""; state.err = ""; state.exited = null;
      const parts = args.map((a) => enc.encode(String(a)));
      const size = parts.reduce((n, p) => n + p.length + 1, 1);
      const ptr = ex.sp_reactor_alloc(size);
      if (!ptr) throw new Error("sp_reactor_alloc failed");
      // NB: read .buffer *after* the allocation -- malloc can grow the memory.
      const mem = new Uint8Array(ex.memory.buffer);
      let o = ptr;
      for (const p of parts) { mem.set(p, o); o += p.length; mem[o++] = 0; }
      let code = 0;
      try { code = ex.sp_reactor_run(ptr, parts.length); }
      catch (e) {
        if (e instanceof WasiExit) code = e.code;   // instance is now poisoned
        else throw e;
      }
      ex.sp_reactor_free(ptr);
      return {
        code, stdout: state.out, stderr: state.err,
        stdoutBytes: state.outBytes(), stderrBytes: state.errBytes(),
      };
    },
  };
}
