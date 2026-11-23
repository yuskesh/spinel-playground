/* tools/wasm/sp_wasm_host.c -- the whole C side of the host-import bridge
   (R003 §2-4 layer 1, implemented by E014).  Linked only with --host-api.
   vendor/spinel is untouched: Spinel's own FFI declares the symbols, this TU
   defines them, and each definition is a thunk over a wasm import.

     ffi_func :sp_host_fetch, [...], :int    (Ruby side, plain Spinel FFI)
       -> extern int sp_host_fetch(...);     (emitted into the generated TU)
       -> this file's definition               (the only thing the driver adds)
       -> import "spinel_host"."http_request" (the JS side, JSPI-suspending)

   WHY A THUNK LAYER AT ALL (three reasons, none of them ceremony):

     1. clang records an import only for a symbol the TU actually *references*.
        A bare declaration links to nothing -- R003 probe F hit exactly this.
     2. The thunk is the only place an error code can become a Ruby exception:
        sp_raise_cls lives in the generated TU (R001 §1.5), so this file needs
        one declaration and the link closes on the program's own definition.
     3. The two-call length protocol needs somewhere to own the buffer.  The
        host must never call back into wasm (no malloc callback), because a
        host->wasm call during a JSPI suspend is exactly the re-entrancy R003
        §2-5 rules out.  So wasm asks the length, allocates, and asks again.

   THE PROTOCOL: stage-then-drain.  The plain "call with cap=0 to learn the
   length, then call again to copy" shape (R003 §2-4) is right for a *pure*
   lookup and wrong for a fetch: the length call would have to perform the
   request, and the copy call would perform it a second time.  For a POST that
   is not a repeated read, it is a repeated side effect.  So the operation
   (http_request / kv_get) runs once, suspends once, and stages its result on
   the host side; the length and copy calls are synchronous accessors over that
   staged result.  One suspend per operation, no duplicated side effects, and
   the accessors cannot suspend -- so nothing re-enters wasm while suspended.

   Everything crosses as (pointer into linear memory, explicit length):
   NUL-terminated C strings in, (buf, cap) -> bytes-written out, negative
   return = error code.  Bodies are BYTE-EXACT in both directions; header
   blocks are the CGI-shaped "Name: value\n" text E013 already uses (there is
   no JSON on this target -- packages/json is a native .o).  */

/* ---- the import namespace --------------------------------------------------
   "spinel_host" is deliberately NOT wasi_snapshot_preview1: the WASI namespace
   is a standard and this is not.  A module that references none of the thunks
   below imports none of these (--gc-sections drops the unreferenced thunk and
   its import with it), so --host-api on a program that does no host I/O adds
   nothing to the module.  */
#define SP_HOST_IMPORT(n) \
  __attribute__((import_module("spinel_host"), import_name(n)))

/* The operations.  These three are the only ones the JS side wraps in
   WebAssembly.Suspending; from C they are ordinary synchronous calls (R003
   §2-3: the C does not change at all under JSPI).  */
SP_HOST_IMPORT("http_request")
int sp_imp_http_request(const char *url, const char *method,
                        const char *body, int body_len, const char *headers);
SP_HOST_IMPORT("kv_get") int sp_imp_kv_get(const char *ns, const char *key);
SP_HOST_IMPORT("kv_put") int sp_imp_kv_put(const char *ns, const char *key,
                                           const char *val, int val_len);

/* The accessors over the staged result.  Synchronous, side-effect free, and
   idempotent -- they may be called any number of times until the next
   operation replaces what is staged.  */
SP_HOST_IMPORT("res_body_len")     int sp_imp_res_body_len(void);
SP_HOST_IMPORT("res_body_read")    int sp_imp_res_body_read(char *buf, int cap);
SP_HOST_IMPORT("res_headers_len")  int sp_imp_res_headers_len(void);
SP_HOST_IMPORT("res_headers_read") int sp_imp_res_headers_read(char *buf, int cap);
/* Detail text for the last negative return (never negative itself; 0 = none).
   Without it "the fetch failed" is all a Ruby program could ever say.  */
SP_HOST_IMPORT("last_error")       int sp_imp_last_error(char *buf, int cap);

/* ---- R2 (E055) -------------------------------------------------------------
   The same stage-then-drain shape as kv_get: the operation suspends once and
   parks its result, and the bytes come back through res_body_*.  An object's
   metadata is parked separately, in the header slot, so a body is never mixed
   with a description of itself.  r2_list answers with a TABLE (below) because
   an R2 key is arbitrary UTF-8 and a line-oriented listing would be forgeable
   by a key containing a newline.  */
SP_HOST_IMPORT("r2_get")    int sp_imp_r2_get(const char *bkt, const char *key);
SP_HOST_IMPORT("r2_head")   int sp_imp_r2_head(const char *bkt, const char *key);
SP_HOST_IMPORT("r2_put")    int sp_imp_r2_put(const char *bkt, const char *key,
                                              const char *val, int val_len,
                                              const char *meta);
SP_HOST_IMPORT("r2_delete") int sp_imp_r2_delete(const char *bkt, const char *key);
SP_HOST_IMPORT("r2_list")   int sp_imp_r2_list(const char *bkt, const char *prefix,
                                               int limit, const char *cursor);

/* ---- D1 (E055) -------------------------------------------------------------
   Placeholder values are pushed one at a time through the import named for
   their TYPE, then one suspending d1_exec runs the statement.  Two properties
   follow from that shape, and both are the reason for it:

     1. A value NEVER touches the SQL text.  There is no import that takes a
        statement and a value together, so there is no path -- not even a
        mistaken one -- by which a bound string could become syntax.  D1's
        prepare() takes a single statement, so `'; DROP TABLE t --` stays a
        five-word string in a TEXT column.
     2. The Ruby program's static type reaches the database.  `st.int(id)`
        crosses as an i64 and binds as a number; `st.text(s)` crosses as
        (ptr, len) and binds as TEXT, byte-exact, NUL included.  Nothing is
        stringified on the way and nothing is guessed at on arrival.

   The binds are host-global and are consumed by the next d1_exec.  A statement
   is bound and run in one Ruby expression, so there is nothing to interleave
   with (see spinel_host.rb's D1Stmt).  */
SP_HOST_IMPORT("d1_bind_reset") int sp_imp_d1_bind_reset(void);
SP_HOST_IMPORT("d1_bind_null")  int sp_imp_d1_bind_null(void);
SP_HOST_IMPORT("d1_bind_int")   int sp_imp_d1_bind_int(long long v);
SP_HOST_IMPORT("d1_bind_real")  int sp_imp_d1_bind_real(double v);
SP_HOST_IMPORT("d1_bind_text")  int sp_imp_d1_bind_text(const char *s, int len);
SP_HOST_IMPORT("d1_bind_blob")  int sp_imp_d1_bind_blob(const char *s, int len);
SP_HOST_IMPORT("d1_exec")       int sp_imp_d1_exec(const char *db, const char *sql);

/* ---- the table slot (E055) --------------------------------------------------
   E014 closed with one open question for this phase: `list` and a query answer
   with a *shape* (an array, a grid) and not with a blob, so the staging slot
   needs a representation for one.  This is it, and it is ADDRESSED rather than
   serialized: (row, col) -> tag + bytes.

   A serialized frame -- JSON, CSV, a header block -- would have had to answer
   three questions correctly, every time, on both sides:

     * how does a BLOB containing NUL survive the delimiter?
     * how does SQL NULL stay distinct from a zero-length TEXT?  (R003 §3-1,
       one level down: "absent" and "empty" must not collapse)
     * how is a TEXT cell containing the delimiter escaped, and un-escaped?

   An accessor answers all three by construction: nothing is ever parsed, so
   nothing can ever be mis-parsed.  There is no JSON on this target anyway
   (E014 §2 -- packages/json is a native .o), so the alternative was a
   hand-rolled framing in Ruby, which is a parser with the same three questions
   and none of the tests.

   Cost: three synchronous import calls per cell.  None of them suspends, so
   the E014 invariant ("nothing can re-enter wasm while a suspend is
   outstanding") holds for a 10,000-cell result exactly as it does for a
   fetch.  */
SP_HOST_IMPORT("tbl_rows")      int sp_imp_tbl_rows(void);
SP_HOST_IMPORT("tbl_cols")      int sp_imp_tbl_cols(void);
SP_HOST_IMPORT("tbl_col_name_len") int sp_imp_tbl_col_name_len(int i);
SP_HOST_IMPORT("tbl_col_name")  int sp_imp_tbl_col_name(int i, char *buf, int cap);
SP_HOST_IMPORT("tbl_cell_type") int sp_imp_tbl_cell_type(int row, int col);
SP_HOST_IMPORT("tbl_cell_len")  int sp_imp_tbl_cell_len(int row, int col);
SP_HOST_IMPORT("tbl_cell_read") int sp_imp_tbl_cell_read(int row, int col, char *buf, int cap);

/* ---- error codes (must match tools/wasm/spinel_host.mjs) ------------------ */
#define SP_HOST_E_ARG   (-1)   /* malformed use: bad URL, unknown binding, ... */
#define SP_HOST_E_NET   (-2)   /* the network attempt itself failed             */
#define SP_HOST_E_SPACE (-3)   /* would not fit: cap too small / over the limit */
#define SP_HOST_E_STAGE (-4)   /* nothing staged: an accessor called too early  */
#define SP_HOST_E_HOST  (-5)   /* the host broke internally                     */
#define SP_HOST_E_NOSYS (-6)   /* no host API here (built with --host-api, run
                                  by a host that supplies no spinel_host)       */
#define SP_HOST_E_SQL   (-7)   /* the database refused the statement (E055)     */

/* Defined by the generated TU (R001 §1.5 -- one of the 29 symbols every Spinel
   program defines).  One declaration is all a driver-side TU ever needs.  */
__attribute__((noreturn)) void sp_raise_cls(const char *cls, const char *msg);

/* Defined by lib/sp_alloc.c.  The :binstr return mode reads this to build a
   Ruby String of exactly N bytes instead of strlen()ing it -- which is the
   whole point, since a response body may contain NUL.  */
extern int sp_ffi_bin_len;

/* ---- tiny local libc (this TU deliberately pulls in no headers) ----------- */
void *malloc(unsigned long);
void  free(void *);
unsigned long strlen(const char *);

static char sp_host_msg[512];

static char *sp_host_cat(char *p, const char *s) {
  char *end = sp_host_msg + sizeof sp_host_msg - 1;
  while (s && *s && p < end) *p++ = *s++;
  *p = 0;
  return p;
}

/* One place where a host error code becomes a Ruby exception.  The class is
   chosen so that the *kind* of failure is what a rescue clause can see:

     ArgumentError        the program asked for something malformed
     IOError              the world said no (unreachable host, too large)
     RuntimeError         the program used the API out of order
     NotImplementedError  this build has no host API at all -- same class and
                          the same catchability as every other absent facility
                          on this target (E012 policy)

   A non-2xx HTTP status is NOT any of these: it is an answer, and it comes
   back as the return value of sp_host_fetch.  Nor is an R2 miss, nor a query
   that matched no rows: both are answers too (nil / an empty result).

   E055 adds E_SQL, and puts it with ArgumentError rather than IOError on
   purpose.  A syntax error, a UNIQUE violation and "wrong number of parameter
   bindings" are all statements about what the program asked for; IOError is
   reserved for "the other end could not be reached".  Both are StandardError,
   so a blanket `rescue => e` catches either, but the two can be told apart
   when it matters.  */
__attribute__((noreturn))
static void sp_host_fail(int code, const char *what) {
  char *p = sp_host_cat(sp_host_msg, what);
  int n = sp_imp_last_error(p, (int)(sizeof sp_host_msg - (unsigned long)(p - sp_host_msg) - 8));
  if (n > 0) p[n] = 0; else *p = 0;

  switch (code) {
    case SP_HOST_E_NOSYS:
      sp_raise_cls("NotImplementedError",
                   "the host API is not available here: this module was built "
                   "with --host-api but the host supplied no `spinel_host` "
                   "imports (tools/wasm/README.md, R003 §2-4 layer 1)");
    case SP_HOST_E_ARG:   sp_raise_cls("ArgumentError", sp_host_msg);
    case SP_HOST_E_SQL:   sp_raise_cls("ArgumentError", sp_host_msg);
    case SP_HOST_E_STAGE: sp_raise_cls("RuntimeError", sp_host_msg);
    case SP_HOST_E_SPACE: sp_raise_cls("IOError", sp_host_msg);
    case SP_HOST_E_NET:   sp_raise_cls("IOError", sp_host_msg);
    default:              sp_raise_cls("IOError", sp_host_msg);
  }
}

/* ---- the drain buffers ------------------------------------------------------
   Growable, per module instance, reused across calls.  The :binstr return mode
   copies out of one immediately (sp_str_from_bytes at the call site), so a
   buffer only has to stay valid until the next call that uses THAT slot.  */
typedef struct { char *p; int cap; } SpHostBuf;

/* TWO buffers, not one.  The body and the headers of a single response are
   read by two separate FFI calls, and Ruby code naturally writes them as two
   arguments of one expression:

     Response.new(status, SpinelHost.sp_host_res_body,
                          parse_headers(SpinelHost.sp_host_res_headers))

   C leaves the evaluation of those two arguments unsequenced (C11 6.5.2.2p10),
   so with a single shared buffer the headers call could realloc the storage
   the body call is still holding a pointer into.  A rare, silent
   use-after-free -- exactly the failure shape this target keeps designing out.
   Two slots make it impossible rather than unlikely.  (The Ruby prelude also
   sequences the two calls into locals; belt and braces.)  */
static SpHostBuf sp_host_body_buf;
static SpHostBuf sp_host_head_buf;
static const char sp_host_empty[1] = { 0 };

static char *sp_host_reserve(SpHostBuf *b, int n) {
  if (n < 0) n = 0;
  if (n + 1 > b->cap) {
    int want = n + 1;
    char *nb = (char *)malloc((unsigned long)want);
    if (!nb) sp_raise_cls("NoMemoryError",
                          "spinel_host: cannot allocate the response buffer");
    free(b->p);
    b->p = nb;
    b->cap = want;
  }
  return b->p;
}

/* Drain a staged blob: ask the length, reserve, copy.  `len` and `read` are
   the matching accessor pair; neither of them suspends, so this whole sequence
   runs with no re-entrancy window.  */
static const char *sp_host_drain(SpHostBuf *slot,
                                 int (*len)(void), int (*read)(char *, int),
                                 const char *what) {
  int n = len();
  if (n < 0) sp_host_fail(n, what);
  if (n == 0) { sp_ffi_bin_len = 0; return sp_host_empty; }
  char *b = sp_host_reserve(slot, n);
  int w = read(b, n);
  if (w < 0) sp_host_fail(w, what);
  b[w] = 0;                 /* :str callers need the terminator; :binstr does not */
  sp_ffi_bin_len = w;
  return b;
}

/* ---- the Ruby-visible surface (v0) -----------------------------------------
   Six functions.  The Ruby declarations that reach them are in
   tools/wasm/spinel_host.rb; a program may also declare them by hand.  */

/* sp_host_fetch(url, method, body, body_len, headers, backend) -> HTTP status
   body_len <= 0 means "no request body" (byte-exact otherwise: body may
   contain NUL, which is why the length is explicit rather than strlen).
   headers is a CGI-shaped block, "Name: value\n" per line, "" for none.
   Returns the status -- 404 and 500 are answers, not exceptions.

   `backend` (E058, R008 D-3) is IGNORED HERE and that is the decision, not an
   oversight.  On Fastly every outbound request must name a backend from the
   service configuration and a URL alone reaches nothing, so the shared prelude
   carries the keyword and tools/wasm/fastly/sp_fastly_host.c refuses without
   it.  On Workers the URL IS the destination, so a backend name has nothing to
   select and silently ignoring it is what makes one .rb build for both
   platforms.  It is not diagnosed either: a program that names a backend is
   correct here, merely more specific than this platform needs.  */
int sp_host_fetch(const char *url, const char *method,
                  const char *body, int body_len, const char *headers,
                  const char *backend) {
  (void)backend;
  int st = sp_imp_http_request(url ? url : "", method ? method : "GET",
                               body ? body : "", body_len,
                               headers ? headers : "");
  if (st < 0) sp_host_fail(st, "SpinelHost.fetch: ");
  return st;
}

/* The staged response body, byte-exact (:binstr -- sp_ffi_bin_len carries the
   count, so an embedded NUL survives).  */
const char *sp_host_res_body(void) {
  return sp_host_drain(&sp_host_body_buf, sp_imp_res_body_len,
                       sp_imp_res_body_read, "SpinelHost response body: ");
}

/* The staged response headers as a "Name: value\n" block (:str).  */
const char *sp_host_res_headers(void) {
  const char *s = sp_host_drain(&sp_host_head_buf, sp_imp_res_headers_len,
                                sp_imp_res_headers_read,
                                "SpinelHost response headers: ");
  sp_ffi_bin_len = 0;
  return s;
}

/* kv_get(ns, key) -> 1 found (value staged) / 0 miss.  A miss is an answer,
   not an error: R003 §3-1 forbids collapsing "absent" onto "empty", so the
   Ruby wrapper returns nil for 0 and a String (possibly "") for 1.  */
int sp_host_kv_get(const char *ns, const char *key) {
  int r = sp_imp_kv_get(ns ? ns : "", key ? key : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::KV.get: ");
  return r;
}

/* kv_put(ns, key, value, value_len) -> 0.  value_len < 0 means strlen. */
int sp_host_kv_put(const char *ns, const char *key,
                   const char *val, int val_len) {
  if (val_len < 0) val_len = val ? (int)strlen(val) : 0;
  int r = sp_imp_kv_put(ns ? ns : "", key ? key : "", val ? val : "", val_len);
  if (r < 0) sp_host_fail(r, "SpinelHost::KV.put: ");
  return r;
}

/* Config Store (E058).  Fastly-specific: it is where a Fastly service keeps
   what wrangler.toml keeps in `vars`, and Workers has no counterpart -- the
   vars are already visible as ENV here, which is the platform's own answer to
   the same question.  R003 §3-1: something with no observable answer raises
   rather than inventing one, so this is NotImplementedError and not "".  */
int sp_host_config_get(const char *store, const char *key) {
  (void)store; (void)key;
  sp_raise_cls("NotImplementedError",
               "SpinelHost::Config is not available on the Cloudflare Workers "
               "target (wasm32-wasip1): there is no Config Store here.  A "
               "worker's `vars` are already in ENV (E013), and a binding "
               "namespace is deliberately not flattened into ENV (R003 §3-1)");
}

/* Feature probe that never raises.  It needs no import of its own: with a real
   host and nothing staged, res_body_len answers E_STAGE; with no host at all,
   every spinel_host function answers E_NOSYS.  */
int sp_host_available(void) {
  return sp_imp_res_body_len() == SP_HOST_E_NOSYS ? 0 : 1;
}

/* ---- R2 (E055) -------------------------------------------------------------
   Byte transparency is the whole contract.  get stages the object's bytes and
   the Ruby side drains them through sp_host_res_body, which is :binstr -- the
   same path a fetch body takes, so a PNG round-trips for exactly the reason a
   NUL-carrying HTTP response already did (E014 §9).  put hands (ptr, len)
   straight down; there is no strlen anywhere on this path.  */

/* 1 = the object exists and its bytes are staged; 0 = no such key.  A miss is
   an answer, not an error (R003 §3-1): the Ruby wrapper returns nil for 0 and
   a String -- possibly "" for a zero-byte object -- for 1.  */
int sp_host_r2_get(const char *bkt, const char *key) {
  int r = sp_imp_r2_get(bkt ? bkt : "", key ? key : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::R2.get: ");
  return r;
}

/* 1 / 0 as above, but only the metadata is staged (header slot).  */
int sp_host_r2_head(const char *bkt, const char *key) {
  int r = sp_imp_r2_head(bkt ? bkt : "", key ? key : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::R2.head: ");
  return r;
}

/* val_len < 0 means strlen; pass the real bytesize for anything binary.  meta
   is a "Name: value\n" block ("" for none); `content-type` is understood and
   any other name becomes R2 custom metadata.  */
int sp_host_r2_put(const char *bkt, const char *key,
                   const char *val, int val_len, const char *meta) {
  if (val_len < 0) val_len = val ? (int)strlen(val) : 0;
  int r = sp_imp_r2_put(bkt ? bkt : "", key ? key : "", val ? val : "", val_len,
                        meta ? meta : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::R2.put: ");
  return r;
}

/* Idempotent, exactly as R2's own delete is: removing an absent key succeeds. */
int sp_host_r2_delete(const char *bkt, const char *key) {
  int r = sp_imp_r2_delete(bkt ? bkt : "", key ? key : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::R2.delete: ");
  return r;
}

/* Stages a table (key, size, etag, uploaded, content_type) and returns the
   number of objects in it.  limit <= 0 means "the host's default page".  The
   truncation flag and the continuation cursor are in the header slot.  */
int sp_host_r2_list(const char *bkt, const char *prefix, int limit, const char *cursor) {
  int r = sp_imp_r2_list(bkt ? bkt : "", prefix ? prefix : "", limit, cursor ? cursor : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::R2.list: ");
  return r;
}

/* ---- D1 (E055) ------------------------------------------------------------ */

int sp_host_d1_bind_reset(void) {
  int r = sp_imp_d1_bind_reset();
  if (r < 0) sp_host_fail(r, "SpinelHost::D1 bind: ");
  return r;
}
int sp_host_d1_bind_null(void) {
  int r = sp_imp_d1_bind_null();
  if (r < 0) sp_host_fail(r, "SpinelHost::D1 bind: ");
  return r;
}
/* long long, not int: Ruby's Integer is 64-bit here (SP_INT64, E010) and
   narrowing it at the boundary would be the same silent truncation E010
   removed.  The host refuses a value that a JS number cannot hold exactly
   rather than rounding it.  */
int sp_host_d1_bind_int(long long v) {
  int r = sp_imp_d1_bind_int(v);
  if (r < 0) sp_host_fail(r, "SpinelHost::D1 bind: ");
  return r;
}
int sp_host_d1_bind_real(double v) {
  int r = sp_imp_d1_bind_real(v);
  if (r < 0) sp_host_fail(r, "SpinelHost::D1 bind: ");
  return r;
}
/* TEXT and BLOB both cross as (ptr, len), so both are byte-exact and both may
   contain NUL.  The tag decides which one SQLite stores.  */
int sp_host_d1_bind_text(const char *s, int len) {
  if (len < 0) len = s ? (int)strlen(s) : 0;
  int r = sp_imp_d1_bind_text(s ? s : "", len);
  if (r < 0) sp_host_fail(r, "SpinelHost::D1 bind: ");
  return r;
}
int sp_host_d1_bind_blob(const char *s, int len) {
  if (len < 0) len = s ? (int)strlen(s) : 0;
  int r = sp_imp_d1_bind_blob(s ? s : "", len);
  if (r < 0) sp_host_fail(r, "SpinelHost::D1 bind: ");
  return r;
}

/* Runs the bound statement and stages its rows.  Returns the row count (0 for
   a write).  changes / last_row_id / duration_ms are in the header slot, so a
   write is described even though it has no rows.  */
int sp_host_d1_exec(const char *db, const char *sql) {
  int r = sp_imp_d1_exec(db ? db : "", sql ? sql : "");
  if (r < 0) sp_host_fail(r, "SpinelHost::D1: ");
  return r;
}

/* ---- the table accessors (E055) ------------------------------------------- */

int sp_host_tbl_rows(void) {
  int r = sp_imp_tbl_rows();
  if (r < 0) sp_host_fail(r, "SpinelHost result rows: ");
  return r;
}
int sp_host_tbl_cols(void) {
  int r = sp_imp_tbl_cols();
  if (r < 0) sp_host_fail(r, "SpinelHost result columns: ");
  return r;
}
int sp_host_tbl_cell_type(int row, int col) {
  int r = sp_imp_tbl_cell_type(row, col);
  if (r < 0) sp_host_fail(r, "SpinelHost result cell: ");
  return r;
}

/* FOUR drain slots, rotated (sp_host_next_cell), not one.

   E014 needed two slots because C leaves the evaluation of two arguments of
   one call unsequenced, so a single shared buffer could be realloc'd by the
   second call while the first still held a pointer into it.  A table makes
   that shape ordinary rather than exotic: `row.str("a") + row.str("b")` is
   what anybody writes.  The Ruby wrapper decodes a row cell-by-cell into an
   Array, which is strictly sequenced and safe with one slot -- but the raw FFI
   is a supported way to use this bridge, so the rotation makes the natural
   two- and three-cell expressions safe as well.  Four is not a proof; the
   proof is the wrapper.  It is a wide enough margin that the raw surface is
   not a trap.  */
static SpHostBuf sp_host_cell_bufs[4];
static int sp_host_cell_slot;

static SpHostBuf *sp_host_next_cell(void) {
  SpHostBuf *b = &sp_host_cell_bufs[sp_host_cell_slot];
  sp_host_cell_slot = (sp_host_cell_slot + 1) & 3;
  return b;
}

/* One cell's bytes, verbatim (:binstr -- sp_ffi_bin_len carries the count, so a
   BLOB with an embedded NUL survives).  A NULL cell and a zero-length TEXT
   both come back as "": they are told apart by sp_host_tbl_cell_type, which is
   the whole reason the tag exists.  */
const char *sp_host_tbl_cell(int row, int col) {
  int n = sp_imp_tbl_cell_len(row, col);
  if (n < 0) sp_host_fail(n, "SpinelHost result cell: ");
  if (n == 0) { sp_ffi_bin_len = 0; return sp_host_empty; }
  SpHostBuf *slot = sp_host_next_cell();
  char *b = sp_host_reserve(slot, n);
  int w = sp_imp_tbl_cell_read(row, col, b, n);
  if (w < 0) sp_host_fail(w, "SpinelHost result cell: ");
  b[w] = 0;
  sp_ffi_bin_len = w;
  return b;
}

/* A column name (:str).  Column names come from the SELECT list, so they are
   short and NUL-free; one slot is enough, and the wrapper reads them all once
   into an Array before any row is touched.  */
static SpHostBuf sp_host_colname_buf;

const char *sp_host_tbl_col_name(int i) {
  /* Ask the length, then copy: the plain two-call protocol R003 §2-4 sketched,
     which is exactly right for a pure lookup over already-staged state.  It
     was wrong only for a fetch, where the length question WAS the request
     (E014 §1); here neither call suspends or has any effect at all.  */
  int n = sp_imp_tbl_col_name_len(i);
  if (n < 0) sp_host_fail(n, "SpinelHost result column: ");
  if (n == 0) { sp_ffi_bin_len = 0; return sp_host_empty; }
  char *b = sp_host_reserve(&sp_host_colname_buf, n);
  int w = sp_imp_tbl_col_name(i, b, n);
  if (w < 0) sp_host_fail(w, "SpinelHost result column: ");
  b[w] = 0;
  sp_ffi_bin_len = 0;
  return b;
}

/* ---- compute (decision 0031) ------------------------------------------------
   The WebGPU half of a spinel-rb2comp host: tools/wasm/compute_host.mjs. The
   rules live there and in tools/shader/sp_cuda_compute.c; these only cross the
   import boundary. Unused thunks and their imports are dropped by the linker. */
SP_HOST_IMPORT("cp_open") int sp_imp_cp_open(const char *src, const char *entry, int buffers, int group, int n);
SP_HOST_IMPORT("cp_write") int sp_imp_cp_write(int k, const void *buf, int cap);
SP_HOST_IMPORT("cp_dispatch") int sp_imp_cp_dispatch(int n);
SP_HOST_IMPORT("cp_read") int sp_imp_cp_read(int k, void *buf, int cap);
SP_HOST_IMPORT("cp_close") int sp_imp_cp_close(void);
SP_HOST_IMPORT("cp_last_error") int sp_imp_cp_last_error(char *buf, int cap);

int sp_comp_open(const char *src, const char *entry, int buffers, int group, int n) { return sp_imp_cp_open(src, entry, buffers, group, n); }
int sp_comp_write(int k, const void *buf, int cap) { return sp_imp_cp_write(k, buf, cap); }
int sp_comp_dispatch(int n) { return sp_imp_cp_dispatch(n); }
int sp_comp_read(int k, void *buf, int cap) { return sp_imp_cp_read(k, buf, cap); }
int sp_comp_close(void) { return sp_imp_cp_close(); }
const char *sp_comp_last_error(void) {
  static char msg[512];
  sp_imp_cp_last_error(msg, (int)sizeof msg);
  return msg;
}
