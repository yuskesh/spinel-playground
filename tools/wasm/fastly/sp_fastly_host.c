/* tools/wasm/fastly/sp_fastly_host.c -- layer 1 (SpinelHost) for Fastly.
 *
 * The Fastly counterpart of tools/wasm/sp_wasm_host.c.  Same Ruby-visible
 * symbols, same exception classes, same "a miss is an answer" rule; a
 * completely different mechanism underneath.  Linked by
 * `spinel-wasm --platform fastly --host-api`, and never together with
 * sp_wasm_host.c -- the driver picks exactly one.
 *
 * WHAT IS DIFFERENT FROM THE WORKERS SIDE, AND WHY IT IS *SIMPLER*
 *
 *   E014's whole protocol -- stage-then-drain, res_body_len/res_body_read,
 *   WebAssembly.Suspending, "nothing may re-enter wasm while a suspend is
 *   outstanding" -- exists because a JS `fetch` is a Promise.  On Fastly
 *   `fastly_http_req::send` is a SYNCHRONOUS hostcall that returns the
 *   response handle from the one call (R008 P09).  There is no suspend, so
 *   there is no re-entrancy window, so the staging is not a protocol at all --
 *   it is just this TU's own malloc'd buffer.  The Ruby side cannot tell:
 *   `SpinelHost.fetch(...)` then `sp_host_res_body` reads exactly the same on
 *   both platforms.  E014's design turned out to be Workers-specific
 *   machinery behind a portable face, which is the best possible outcome.
 *
 * THE ONE GENUINELY NEW DECISION: `backend:` (R008 D-3, decided by E058)
 *
 *   Workers `fetch(url)` may go to any URL.  Fastly cannot: every outbound
 *   request names a BACKEND, a service-configuration object, and the URL alone
 *   is not enough.  Three options were on the table --
 *
 *     (a) invent a default backend and silently route through it
 *     (b) derive the backend from the URL's host (a "dynamic backend")
 *     (c) require it, and refuse loudly when it is missing
 *
 *   (a) is the exact failure shape this project keeps removing: the program
 *   asks for https://api.example.com and the request goes somewhere else, with
 *   a 200 to prove it worked.  (b) hides a service-configuration decision
 *   (dynamic backends are capped at 200 per service, bypass configured TLS and
 *   pooling, and are refusable by service policy) inside what looks like a
 *   pure function.  So (c): the keyword is REQUIRED on this platform and its
 *   absence is an ArgumentError naming the URL, at the call, before any
 *   traffic.  The signature stays `SpinelHost.fetch(url, backend: nil)` in the
 *   shared prelude so one .rb builds for both platforms; Workers ignores the
 *   name (the URL is authoritative there) and Fastly insists on it.
 */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "fastly_abi.h"

/* Defined by the generated TU (R001 §1.5).  One declaration is all a
   driver-side TU ever needs; the link closes on the program's own copy. */
__attribute__((noreturn)) void sp_raise_cls(const char *cls, const char *msg);
/* Defined by lib/sp_alloc.c: the :binstr return mode reads this instead of
   strlen()ing, which is why a NUL-carrying body survives. */
extern int sp_ffi_bin_len;

static char sp_fh_msg[512];

__attribute__((noreturn, format(printf, 2, 3)))
static void sp_fh_fail(const char *cls, const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(sp_fh_msg, sizeof sp_fh_msg, fmt, ap);
  va_end(ap);
  sp_raise_cls(cls, sp_fh_msg);
}

/* The class says what KIND of failure it was, exactly as on Workers:
     ArgumentError        the program asked for something malformed, or for a
                          binding this service does not have
     IOError              the world said no (backend unreachable, body refused)
     RuntimeError         the API was used out of order
     NotImplementedError  the facility does not exist on this platform
   An HTTP status is none of these -- 404 and 503 are answers and come back as
   the return value.  A KV miss is an answer too, and comes back as 0/nil. */

/* ---- staging slots ---------------------------------------------------------
   Two, for E014's reason exactly: `Response.new(status, sp_host_res_body,
   parse_headers(sp_host_res_headers))` leaves the two calls unsequenced in C
   (C11 6.5.2.2p10), so one shared buffer could be realloc'd out from under a
   pointer the other call still holds.  Nothing here suspends, but the
   unsequenced-evaluation hazard has nothing to do with suspending. */
typedef struct { uint8_t *p; size_t len, cap; } sp_fh_buf;
static sp_fh_buf sp_fh_body, sp_fh_head;
static int sp_fh_body_staged, sp_fh_head_staged;
static const char sp_fh_empty[1] = { 0 };

static void sp_fh_reset(sp_fh_buf *b) { b->len = 0; }

static void sp_fh_push(sp_fh_buf *b, const void *p, size_t n) {
  if (!n) return;
  if (b->len + n + 1 > b->cap) {
    size_t cap = b->cap ? b->cap : 4096;
    while (cap < b->len + n + 1) cap *= 2;
    uint8_t *nb = (uint8_t *)realloc(b->p, cap);
    if (!nb) sp_raise_cls("NoMemoryError",
                          "spinel_host: cannot grow the staging buffer");
    b->p = nb;
    b->cap = cap;
  }
  memcpy(b->p + b->len, p, n);
  b->len += n;
  b->p[b->len] = 0;
}

/* Drain a Fastly body handle into a slot, byte exact.  The handle stays valid,
   so this is a plain read loop -- no two-call length protocol is needed
   (that was E014's answer to "asking the length IS the side effect"). */
static void sp_fh_drain_body(sp_fh_buf *slot, sp_fa_handle body, const char *what) {
  uint8_t chunk[8192];
  for (;;) {
    size_t got = 0;
    int32_t st = sp_fa_raw_body_read(body, chunk, sizeof chunk, &got);
    if (st != SP_FA_OK)
      sp_fh_fail("IOError", "%s: reading the body failed (%s)", what,
                 sp_fa_status_name(st));
    if (!got) break;
    sp_fh_push(slot, chunk, got);
  }
}

/* ---- the response accessors (shared with the Workers surface) -------------- */
const char *sp_host_res_body(void) {
  if (!sp_fh_body_staged)
    sp_raise_cls("RuntimeError",
                 "SpinelHost response body: nothing staged -- no completed "
                 "fetch, KV get or config get on this platform yet");
  sp_ffi_bin_len = (int)sp_fh_body.len;
  return sp_fh_body.len ? (const char *)sp_fh_body.p : sp_fh_empty;
}

const char *sp_host_res_headers(void) {
  if (!sp_fh_head_staged)
    sp_raise_cls("RuntimeError",
                 "SpinelHost response headers: nothing staged -- no completed "
                 "fetch on this platform yet");
  sp_ffi_bin_len = 0;
  return sp_fh_head.len ? (const char *)sp_fh_head.p : sp_fh_empty;
}

/* ---- fetch ----------------------------------------------------------------- */
/* Parse the CGI-shaped "Name: value\n" request-header block and insert each
   line.  The same block shape E013 speaks and spinel_host.rb formats, so the
   Ruby side is untouched by the platform swap. */
static void sp_fh_insert_headers(sp_fa_handle req, const char *hdrs) {
  while (hdrs && *hdrs) {
    const char *eol = strchr(hdrs, '\n');
    size_t line = eol ? (size_t)(eol - hdrs) : strlen(hdrs);
    const char *colon = (const char *)memchr(hdrs, ':', line);
    if (colon && colon > hdrs) {
      const char *v = colon + 1;
      size_t nlen = (size_t)(colon - hdrs);
      while (v < hdrs + line && (*v == ' ' || *v == '\t')) v++;
      size_t vlen = (size_t)((hdrs + line) - v);
      if (vlen && v[vlen - 1] == '\r') vlen--;
      sp_fa_raw_req_header_insert(req, (const uint8_t *)hdrs, nlen,
                                  (const uint8_t *)v, vlen);
    }
    if (!eol) break;
    hdrs = eol + 1;
  }
}

/* Stage a response's headers as the same "Name: value\n" block the Workers
   host produces.  Fastly can return several values for one name (a cursor per
   name), so each value gets its own line -- strictly more information than
   Workers' Headers object, which joins them (R008 §3.4-4). */
static void sp_fh_stage_headers(sp_fa_handle resp) {
  sp_fh_reset(&sp_fh_head);
  uint8_t names[16384];
  size_t nn = 0;
  int64_t cur = 0;
  if (sp_fa_raw_resp_header_names_get(resp, names, sizeof names, 0, &cur, &nn)
      != SP_FA_OK)
    nn = 0;
  for (size_t i = 0; i < nn;) {
    size_t l = strlen((char *)names + i);
    if (!l) break;
    uint8_t val[8192];
    size_t vn = 0;
    int64_t vc = 0;
    if (sp_fa_raw_resp_header_values_get(resp, names + i, l, val, sizeof val, 0,
                                         &vc, &vn) == SP_FA_OK && vn) {
      size_t at = 0;
      while (at < vn) {
        size_t vl = strlen((char *)val + at);
        if (!vl) break;
        sp_fh_push(&sp_fh_head, names + i, l);
        sp_fh_push(&sp_fh_head, ": ", 2);
        sp_fh_push(&sp_fh_head, val + at, vl);
        sp_fh_push(&sp_fh_head, "\n", 1);
        at += vl + 1;
      }
    }
    i += l + 1;
  }
  sp_fh_head_staged = 1;
}

int sp_host_fetch(const char *url, const char *method,
                  const char *body, int body_len, const char *headers,
                  const char *backend) {
  if (!url || !*url)
    sp_fh_fail("ArgumentError", "SpinelHost.fetch: the URL must not be empty");

  /* ★ R008 D-3, decided here.  Refusing is the whole point: the alternative is
     a request that succeeds against a destination the program did not name. */
  if (!backend || !*backend)
    sp_fh_fail("ArgumentError",
               "SpinelHost.fetch(%s): this is the %s platform, where every "
               "outbound request names a backend from the service "
               "configuration -- a URL alone cannot reach anything.  Pass "
               "backend: \"<name>\" (the name in fastly.toml's "
               "[local_server.backends] or in the service).  On Workers the "
               "same call ignores backend:, so one program builds for both.",
               url, sp_platform_name);

  sp_fa_handle req = SP_FA_INVALID, rbody = SP_FA_INVALID;
  if (sp_fa_req_new(&req) != SP_FA_OK)
    sp_fh_fail("IOError", "SpinelHost.fetch: could not create a request");

  const char *m = (method && *method) ? method : "GET";
  int32_t st = sp_fa_raw_req_method_set(req, (const uint8_t *)m, strlen(m));
  if (st != SP_FA_OK)
    sp_fh_fail("ArgumentError", "SpinelHost.fetch: bad method %s (%s)", m,
               sp_fa_status_name(st));

  st = sp_fa_raw_req_uri_set(req, (const uint8_t *)url, strlen(url));
  if (st != SP_FA_OK)
    sp_fh_fail("ArgumentError", "SpinelHost.fetch: %s is not a usable URL (%s)",
               url, sp_fa_status_name(st));

  sp_fh_insert_headers(req, headers);

  if (sp_fa_body_new(&rbody) != SP_FA_OK)
    sp_fh_fail("IOError", "SpinelHost.fetch: could not create a request body");
  if (body && body_len > 0) {
    size_t off = 0;
    while (off < (size_t)body_len) {
      size_t w = 0;
      st = sp_fa_raw_body_write(rbody, (const uint8_t *)body + off,
                                (size_t)body_len - off, SP_FA_BODY_BACK, &w);
      if (st != SP_FA_OK || !w)
        sp_fh_fail("IOError", "SpinelHost.fetch: the request body was refused (%s)",
                   sp_fa_status_name(st));
      off += w;
    }
  }

  sp_fa_handle resp = SP_FA_INVALID, respbody = SP_FA_INVALID;
  st = sp_fa_send(req, rbody, backend, strlen(backend), &resp, &respbody);
  if (st != SP_FA_OK) {
    /* An undeclared backend answers INVALID_ARGUMENT -- that is a statement
       about what the program asked for, so ArgumentError; anything else is
       the world saying no, so IOError.  (E058 pre-flight Q4 measured the
       INVAL; it does not trap.) */
    if (st == SP_FA_INVAL)
      sp_fh_fail("ArgumentError",
                 "SpinelHost.fetch(%s, backend: \"%s\"): no backend named "
                 "\"%s\" is available to this service", url, backend, backend);
    sp_fh_fail("IOError", "SpinelHost.fetch(%s, backend: \"%s\"): %s", url,
               backend, sp_fa_status_name(st));
  }

  uint16_t code = 0;
  sp_fa_raw_resp_status_get(resp, &code);
  sp_fh_stage_headers(resp);
  sp_fh_reset(&sp_fh_body);
  sp_fh_drain_body(&sp_fh_body, respbody, "SpinelHost.fetch");
  sp_fh_body_staged = 1;
  return (int)code;
}

/* ---- KV Store --------------------------------------------------------------- */
/* One-entry memo of the open store.  Opening is cheap but not free, and the
   overwhelmingly common shape is several operations against one store. */
static char sp_fh_kv_name[256];
static sp_fa_handle sp_fh_kv_h = SP_FA_INVALID;

static sp_fa_handle sp_fh_kv_store(const char *ns, const char *what) {
  if (!ns || !*ns)
    sp_fh_fail("ArgumentError", "%s: the KV Store name must not be empty", what);
  if (sp_fh_kv_h != SP_FA_INVALID && !strcmp(sp_fh_kv_name, ns))
    return sp_fh_kv_h;
  sp_fa_handle h = SP_FA_INVALID;
  int32_t st = sp_fa_kv_open(ns, strlen(ns), &h);
  if (st != SP_FA_OK)
    /* Same sentence shape as the Workers side's "no KV namespace named X is
       available to this worker": reachability is a deployment decision, and
       the program should be told which name it asked for. */
    sp_fh_fail("ArgumentError",
               "%s: no KV Store named \"%s\" is available to this service "
               "(declare it in fastly.toml [local_server.kv_stores] for local "
               "runs, or in the service configuration) [%s]",
               what, ns, sp_fa_status_name(st));
  if (strlen(ns) < sizeof sp_fh_kv_name) {
    strcpy(sp_fh_kv_name, ns);
    sp_fh_kv_h = h;
  }
  return h;
}

/* 1 = hit and the value is staged, 0 = miss.  R003 §3-1: a miss is an answer,
   and it must NOT collapse onto "" -- which on this platform takes real care,
   because the hostcall reports a miss by NOT WRITING the out parameter
   (R008 §2.6).  The sentinel discipline lives in fastly_abi.h; this is its
   only consumer, so the trap has exactly one place it could be sprung. */
int sp_host_kv_get(const char *ns, const char *key) {
  if (!key || !*key)
    sp_fh_fail("ArgumentError", "SpinelHost::KV.get: the key must not be empty");
  sp_fa_handle store = sp_fh_kv_store(ns, "SpinelHost::KV.get");
  sp_fa_handle body = SP_FA_INVALID;
  int r = sp_fa_kv_lookup(store, key, strlen(key), &body);
  if (r < 0)
    sp_fh_fail("IOError", "SpinelHost::KV.get(%s, %s): %s", ns, key,
               sp_fa_status_name(r));
  if (r == 0) {
    /* Leave nothing readable behind: a program that ignores the return value
       and drains the body slot anyway must not get the previous value. */
    sp_fh_reset(&sp_fh_body);
    sp_fh_body_staged = 1;
    return 0;
  }
  sp_fh_reset(&sp_fh_body);
  sp_fh_drain_body(&sp_fh_body, body, "SpinelHost::KV.get");
  sp_fh_body_staged = 1;
  return 1;
}

int sp_host_kv_put(const char *ns, const char *key, const char *val, int val_len) {
  if (!key || !*key)
    sp_fh_fail("ArgumentError", "SpinelHost::KV.put: the key must not be empty");
  if (val_len < 0) val_len = val ? (int)strlen(val) : 0;
  sp_fa_handle store = sp_fh_kv_store(ns, "SpinelHost::KV.put");
  sp_fa_handle body = SP_FA_INVALID;
  if (sp_fa_body_new(&body) != SP_FA_OK)
    sp_fh_fail("IOError", "SpinelHost::KV.put: could not create a value body");
  size_t off = 0;
  while (off < (size_t)val_len) {
    size_t w = 0;
    int32_t st = sp_fa_raw_body_write(body, (const uint8_t *)val + off,
                                      (size_t)val_len - off, SP_FA_BODY_BACK, &w);
    if (st != SP_FA_OK || !w)
      sp_fh_fail("IOError", "SpinelHost::KV.put(%s, %s): the value was refused (%s)",
                 ns, key, sp_fa_status_name(st));
    off += w;
  }
  int32_t st = sp_fa_raw_kv_insert(store, (const uint8_t *)key, strlen(key), body);
  if (st != SP_FA_OK)
    sp_fh_fail("IOError", "SpinelHost::KV.put(%s, %s): %s", ns, key,
               sp_fa_status_name(st));
  return 0;
}

/* ---- Config Store (Fastly-specific; NotImplementedError on Workers) --------
   This is where a Fastly service keeps what wrangler.toml keeps in `vars`.
   It is an explicit API and NOT injected into ENV: R003 §3-1's rule is that a
   binding namespace must not be flattened into the environment, because that
   is where "absent" and "empty" stop being distinguishable.  1 = found and
   staged, 0 = no such key. */
int sp_host_config_get(const char *store, const char *key) {
  if (!store || !*store)
    sp_fh_fail("ArgumentError", "SpinelHost::Config.get: the store name must not be empty");
  if (!key || !*key)
    sp_fh_fail("ArgumentError", "SpinelHost::Config.get: the key must not be empty");
  sp_fa_handle h = SP_FA_INVALID;
  int32_t st = sp_fa_config_open(store, strlen(store), &h);
  if (st != SP_FA_OK)
    sp_fh_fail("ArgumentError",
               "SpinelHost::Config.get: no Config Store named \"%s\" is "
               "available to this service (declare it in fastly.toml "
               "[local_server.config_stores]) [%s]", store, sp_fa_status_name(st));
  uint8_t buf[8192];
  size_t n = 0;
  int r = sp_fa_config_get(h, key, strlen(key), buf, sizeof buf, &n);
  if (r < 0)
    sp_fh_fail("IOError", "SpinelHost::Config.get(%s, %s): %s", store, key,
               sp_fa_status_name(r));
  sp_fh_reset(&sp_fh_body);
  if (r == 1) sp_fh_push(&sp_fh_body, buf, n);
  sp_fh_body_staged = 1;
  return r;
}

/* Never raises: on Fastly the hostcalls are the platform itself, so if this
   module is running at all the host API is there. */
int sp_host_available(void) { return 1; }

/* ---- what this platform does not have (R008 §4.2, E055's spelling) ---------
   R2 has a shape-alike (Object Storage, S3-compatible) but no hostcall: it is
   reached as a backend with SigV4 request signing, which is a different
   implementation behind the same face and is deliberately out of M1.  D1 has
   NOTHING to map to -- Fastly has no SQL database product at all.
   R003 §3-1 is explicit about what to do: raise.  An empty result set would be
   an answer, and it would be the wrong one. */
#define SP_FH_NI(what, why)                                                    \
  sp_fh_fail("NotImplementedError",                                            \
             what " is not available on the %s target (wasm32-wasip1): " why,  \
             sp_platform_name)

#define SP_FH_NI_R2(fn)                                                        \
  SP_FH_NI("SpinelHost::R2." fn,                                               \
           "Fastly's shape-alike is Object Storage, which is S3-compatible "   \
           "and has no hostcall of its own -- it is reached as a backend with " \
           "SigV4 signing, which E058 (M1) does not implement.  Use "          \
           "SpinelHost::KV for values up to 25 MB")

int sp_host_r2_get(const char *b, const char *k) { (void)b; (void)k; SP_FH_NI_R2("get"); }
int sp_host_r2_head(const char *b, const char *k) { (void)b; (void)k; SP_FH_NI_R2("head"); }
int sp_host_r2_put(const char *b, const char *k, const char *v, int vl, const char *m) {
  (void)b; (void)k; (void)v; (void)vl; (void)m; SP_FH_NI_R2("put");
}
int sp_host_r2_delete(const char *b, const char *k) { (void)b; (void)k; SP_FH_NI_R2("delete"); }
int sp_host_r2_list(const char *b, const char *p, int l, const char *c) {
  (void)b; (void)p; (void)l; (void)c; SP_FH_NI_R2("list");
}

#define SP_FH_NI_D1(fn)                                                        \
  SP_FH_NI("SpinelHost::D1" fn,                                                \
           "Fastly has no SQL database product -- there is nothing to map it " \
           "to.  Returning an empty result set would be an answer, and it "    \
           "would be the wrong one (R003 §3-1)")

int sp_host_d1_bind_reset(void) { SP_FH_NI_D1(" bind"); }
int sp_host_d1_bind_null(void) { SP_FH_NI_D1(" bind"); }
int sp_host_d1_bind_int(long long v) { (void)v; SP_FH_NI_D1(" bind"); }
int sp_host_d1_bind_real(double v) { (void)v; SP_FH_NI_D1(" bind"); }
int sp_host_d1_bind_text(const char *s, int l) { (void)s; (void)l; SP_FH_NI_D1(" bind"); }
int sp_host_d1_bind_blob(const char *s, int l) { (void)s; (void)l; SP_FH_NI_D1(" bind"); }
int sp_host_d1_exec(const char *db, const char *sql) { (void)db; (void)sql; SP_FH_NI_D1(""); }

/* The addressed-table slot exists only for D1 and R2.list, so on this platform
   nothing can ever stage one. */
#define SP_FH_NI_TBL()                                                         \
  SP_FH_NI("SpinelHost's result-table surface",                                \
           "the only things that stage a table are SpinelHost::D1 and "        \
           "SpinelHost::R2.list, and neither exists here")

int sp_host_tbl_rows(void) { SP_FH_NI_TBL(); }
int sp_host_tbl_cols(void) { SP_FH_NI_TBL(); }
int sp_host_tbl_cell_type(int r, int c) { (void)r; (void)c; SP_FH_NI_TBL(); }
const char *sp_host_tbl_cell(int r, int c) { (void)r; (void)c; SP_FH_NI_TBL(); }
const char *sp_host_tbl_col_name(int i) { (void)i; SP_FH_NI_TBL(); }
