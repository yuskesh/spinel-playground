/* tools/wasm/fastly/fastly_cgi.c -- layer 0 for Fastly Compute.
 *
 * This is the C counterpart of tools/wasm/worker.mjs.  On Cloudflare Workers
 * the lifecycle layer lives in JavaScript because the JS shim owns
 * wasi_snapshot_preview1 and can hand the guest a Request as ARGV/stdin/ENV.
 * On Fastly the host IS the platform: it owns WASI, there is no JS anywhere,
 * and R008 P05 measured what a guest actually sees --
 *
 *     argv    = ["compute-app"]        (nothing about the request)
 *     environ = FASTLY_* only          (9 variables)
 *     stdin   = immediate EOF
 *     stdout  = the log endpoint, NOT the response
 *     and returning without calling send_downstream answers 200 / empty body.
 *
 * So the layer has to live INSIDE the module.  It still touches neither
 * vendor/spinel nor the generated TU; three link-level hooks are enough:
 *
 *   __main_void()  wasi-libc's crt1-command.o calls this, not main().  It is
 *                  its own object inside libc.a, so defining it here displaces
 *                  libc's copy and we get control before and after main().
 *   --wrap=__imported_wasi_snapshot_preview1_fd_write   stdout -> response body
 *                  (fd 2 is captured AND still forwarded to Fastly's log).
 *   --wrap=__imported_wasi_snapshot_preview1_fd_read    stdin  <- request body
 *   --wrap=exit    exit(n): n == 0 -> 200, n != 0 -> 500 (E013).
 *
 * R008 P07 proved the middle one: --wrap does apply to WASI import symbols.
 * Without that this layer would have had to be a vendor patch.
 *
 * THE CONTRACT IS E013's, UNCHANGED, and that is the whole point --
 *
 *   ARGV[0] = path        ARGV[1] = query string        $stdin  = request body
 *   ENV     = CGI variables (REQUEST_METHOD / PATH_INFO / QUERY_STRING /
 *             CONTENT_TYPE / CONTENT_LENGTH / HTTP_*) plus the platform's own
 *   $stdout = response body (byte exact)
 *   $stderr = diagnostics; also the 500 body when the program fails
 *   exit(0) -> 200, exit(n) -> 500 and stdout is DISCARDED
 *   x-spinel-exit / x-spinel-ms / x-spinel-stdout-bytes on every response
 *   SPINEL_CGI_HEADERS=1 -> a leading "Name: value" block may set the status
 *
 * A Spinel program written for Workers therefore runs here with no edit at
 * all.  E058 demonstrates exactly that with one .rb built both ways.
 *
 * ---------------------------------------------------------------------------
 * WHAT THIS ADDS OVER THE R008 PROBE (r008_probes/c/fastly_cgi.c)
 *
 *   1. $stderr is captured and becomes the 500 body (R008 §3.4-1).  The probe
 *      let fd 2 flow to the log only, so an uncaught Ruby exception arrived at
 *      the client as a blank 500 -- on Workers it arrives as its message.
 *   2. __real_exit(0), ALWAYS (R008 §3.4-8 / H5).  Production Fastly turns a
 *      non-zero proc_exit into {"diagnostic":"runtime_terminated"} -> 500,
 *      which could overwrite a response we have already sent.  The exit status
 *      survives as the x-spinel-exit header instead, so nothing is lost.
 *   3. SPINEL_CGI_HEADERS / SPINEL_CONTENT_TYPE, read from the `spinel` Config
 *      Store (§3.4-2).  Fastly has no way to hand a guest an environment
 *      variable, and R003 §3-1 forbids flattening bindings into ENV, so the
 *      platform's two knobs are read explicitly and nothing else is.
 *   4. Bounded, checked buffers.  The probe's request-body loop had a
 *      malformed growth condition and no cap, and dropped realloc failures
 *      silently.
 *   5. A URI splitter that survives a relative URI (the probe's strstr("://")
 *      walked off the front of "/path").
 * ---------------------------------------------------------------------------
 */
#include <stdarg.h>
#include <stddef.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <strings.h>
#include <time.h>

#include "fastly_abi.h"

/* R008 D-5: the platform name that every NotImplementedError message carries.
   raise_stubs.c has a weak "Cloudflare Workers"; this strong definition wins
   whenever this TU is linked, i.e. exactly on --platform fastly. */
const char *const sp_platform_name = "Fastly Compute";

/* ---- limits ----------------------------------------------------------------
   The heap is 128 MB (Fastly's documented figure; Viceroy does not enforce
   it).  A request body is staged in linear memory because E013's contract is
   `$stdin.read`, so the cap has to be well under the heap or the failure is a
   trap instead of a diagnosis.  32 MB leaves room for the program itself.  */
#define SP_CGI_MAX_STDIN   (32u * 1024u * 1024u)
#define SP_CGI_MAX_STDOUT  (32u * 1024u * 1024u)
#define SP_CGI_MAX_STDERR  (256u * 1024u)
#define SP_CGI_URI_MAX     8192
#define SP_CGI_HDRS_MAX    32768
#define SP_CGI_VAL_MAX     8192

/* ---- the wrapped WASI imports ---------------------------------------------- */
typedef struct { const uint8_t *buf; size_t len; } sp_ciovec;
typedef struct { uint8_t *buf; size_t len; } sp_iovec;

int32_t __real___imported_wasi_snapshot_preview1_fd_write(int32_t, const sp_ciovec *,
                                                          size_t, size_t *);
int32_t __real___imported_wasi_snapshot_preview1_fd_read(int32_t, const sp_iovec *,
                                                         size_t, size_t *);
_Noreturn void __real_exit(int);

/* ---- state ------------------------------------------------------------------ */
typedef struct {
  uint8_t *p;
  size_t   len, cap;
  size_t   max;
  int      overflowed;   /* hit `max`, or a realloc failed: reported, not hidden */
} sp_buf;

static sp_buf g_out = { 0, 0, 0, SP_CGI_MAX_STDOUT, 0 };  /* captured stdout    */
static sp_buf g_err = { 0, 0, 0, SP_CGI_MAX_STDERR, 0 };  /* captured stderr    */
static uint8_t *g_in;                                     /* staged stdin       */
static size_t   g_in_len, g_in_pos;
static int      g_in_overflow;

static sp_fa_handle g_req  = SP_FA_INVALID;
static sp_fa_handle g_body = SP_FA_INVALID;
static int          g_sent;          /* the response is sent exactly once      */
static int          g_started;       /* set once the hostcall side is alive    */
static struct timespec g_t0;
static int      g_t0_ok;      /* CLOCK_MONOTONIC may legitimately read 0 */

static int sp_buf_push(sp_buf *b, const uint8_t *p, size_t n) {
  if (b->len + n > b->max) { b->overflowed = 1; n = b->max > b->len ? b->max - b->len : 0; }
  if (!n) return b->overflowed ? -1 : 0;
  if (b->len + n > b->cap) {
    size_t cap = b->cap ? b->cap : 8192;
    while (cap < b->len + n) cap *= 2;
    if (cap > b->max) cap = b->max;
    uint8_t *nb = (uint8_t *)realloc(b->p, cap);
    if (!nb) { b->overflowed = 1; return -1; }
    b->p = nb; b->cap = cap;
  }
  memcpy(b->p + b->len, p, n);
  b->len += n;
  return 0;
}

/* stdout is captured; stderr is captured AND forwarded, so the diagnostics are
   in Fastly's log even if we never get to build a response (a trap, an OOM). */
int32_t __wrap___imported_wasi_snapshot_preview1_fd_write(
    int32_t fd, const sp_ciovec *iovs, size_t n, size_t *nwritten) {
  if (fd != 1 && fd != 2)
    return __real___imported_wasi_snapshot_preview1_fd_write(fd, iovs, n, nwritten);
  sp_buf *b = (fd == 1) ? &g_out : &g_err;
  size_t total = 0;
  for (size_t i = 0; i < n; i++) {
    sp_buf_push(b, iovs[i].buf, iovs[i].len);
    total += iovs[i].len;
  }
  if (fd == 2) {
    size_t sunk = 0;
    __real___imported_wasi_snapshot_preview1_fd_write(2, iovs, n, &sunk);
  }
  /* Report every byte as written even when the cap bit; a short write makes
     stdio retry forever and the truncation is reported in a header instead. */
  if (nwritten) *nwritten = total;
  return 0;
}

int32_t __wrap___imported_wasi_snapshot_preview1_fd_read(
    int32_t fd, const sp_iovec *iovs, size_t n, size_t *nread) {
  if (fd != 0)
    return __real___imported_wasi_snapshot_preview1_fd_read(fd, iovs, n, nread);
  size_t total = 0;
  for (size_t i = 0; i < n && g_in_pos < g_in_len; i++) {
    size_t l = iovs[i].len;
    if (l > g_in_len - g_in_pos) l = g_in_len - g_in_pos;
    memcpy(iovs[i].buf, g_in + g_in_pos, l);
    g_in_pos += l;
    total += l;
  }
  if (nread) *nread = total;
  return 0;
}

/* ---- the two platform knobs, from the `spinel` Config Store ----------------
   Fastly cannot give a guest an environment variable, and R003 §3-1 forbids
   collapsing a binding namespace into ENV (that is how "absent" and "empty"
   stop being distinguishable).  So the platform layer reads exactly two named
   keys from one named store and injects nothing.  An undeclared store answers
   BAD_HANDLE and everything below simply keeps its default -- measured, not
   assumed: a missing store does not trap (E058 pre-flight Q1).  */
static int g_cgi_headers = -1;                 /* -1 = not looked up yet       */
static char g_content_type[128];

static void sp_cgi_load_config(void) {
  if (g_cgi_headers >= 0) return;
  g_cgi_headers = 0;
  sp_fa_handle cs = SP_FA_INVALID;
  if (sp_fa_config_open("spinel", 6, &cs) != SP_FA_OK) return;
  uint8_t v[128]; size_t n = 0;
  if (sp_fa_config_get(cs, "SPINEL_CGI_HEADERS", 18, v, sizeof v - 1, &n) == 1) {
    v[n] = 0;
    g_cgi_headers = (n == 1 && v[0] == '1');
  }
  n = 0;
  if (sp_fa_config_get(cs, "SPINEL_CONTENT_TYPE", 19, v, sizeof v - 1, &n) == 1 && n) {
    if (n > sizeof g_content_type - 1) n = sizeof g_content_type - 1;
    memcpy(g_content_type, v, n);
    g_content_type[n] = 0;
  }
}

/* ---- the response ----------------------------------------------------------- */
static void sp_hdr(sp_fa_handle r, const char *n, const char *v) {
  sp_fa_raw_resp_header_insert(r, (const uint8_t *)n, strlen(n),
                               (const uint8_t *)v, strlen(v));
}

static void sp_hdr_n(sp_fa_handle r, const char *n, const char *v, size_t vlen) {
  sp_fa_raw_resp_header_insert(r, (const uint8_t *)n, strlen(n),
                               (const uint8_t *)v, vlen);
}

/* worker.mjs's splitCgiHeaders, byte for byte in intent: parse a leading
   "Name: value" block terminated by a blank line, stop at the first line that
   is not a header, and on any doubt treat the whole thing as a body.  A
   program that forgets the blank line gets its text back, not a 500. */
static size_t sp_cgi_split_headers(sp_fa_handle resp, const uint8_t *b, size_t len,
                                   int *status_out, int *have_ct) {
  size_t limit = len < 8192 ? len : 8192;
  size_t i = 0;
  /* First pass: validate.  Nothing is inserted until the whole block parses,
     so a half-parsed block cannot leave stray headers on the response. */
  while (i < limit) {
    size_t j = i;
    while (j < limit && b[j] != '\n') j++;
    if (j >= limit) return 0;                        /* no terminator in range */
    size_t end = j;
    if (end > i && b[end - 1] == '\r') end--;
    if (end == i) break;                             /* blank line: block ends */
    const uint8_t *colon = (const uint8_t *)memchr(b + i, ':', end - i);
    if (!colon || colon == b + i) return 0;          /* not a header block     */
    i = j + 1;
  }
  if (i >= limit) return 0;
  size_t body_at = 0;
  i = 0;
  while (i < limit) {
    size_t j = i;
    while (j < limit && b[j] != '\n') j++;
    size_t end = j;
    if (end > i && b[end - 1] == '\r') end--;
    if (end == i) { body_at = j + 1; break; }
    const uint8_t *colon = (const uint8_t *)memchr(b + i, ':', end - i);
    size_t nlen = (size_t)(colon - (b + i));
    const uint8_t *vp = colon + 1;
    while (vp < b + end && (*vp == ' ' || *vp == '\t')) vp++;
    size_t vlen = (size_t)((b + end) - vp);
    char name[128];
    if (nlen < sizeof name) {
      memcpy(name, b + i, nlen);
      name[nlen] = 0;
      if (!strcasecmp(name, "status")) {
        int st = 0;
        for (size_t k = 0; k < vlen && vp[k] >= '0' && vp[k] <= '9'; k++)
          st = st * 10 + (vp[k] - '0');
        if (st >= 100 && st <= 599) *status_out = st;
      } else {
        if (!strcasecmp(name, "content-type")) *have_ct = 1;
        sp_hdr_n(resp, name, (const char *)vp, vlen);
      }
    }
    i = j + 1;
  }
  return body_at;
}

static void sp_send_response(int code) {
  if (g_sent || !g_started) return;
  g_sent = 1;
  fflush(NULL);                        /* land anything stdio still holds */

  sp_fa_handle resp = SP_FA_INVALID, rb = SP_FA_INVALID;
  if (sp_fa_resp_new(&resp) != SP_FA_OK || sp_fa_body_new(&rb) != SP_FA_OK) {
    /* Nothing we can say; Fastly answers 200/empty.  Say it to the log. */
    const char *m = "spinel-fastly: could not allocate a response\n";
    sp_ciovec io = { (const uint8_t *)m, strlen(m) }; size_t w = 0;
    __real___imported_wasi_snapshot_preview1_fd_write(2, &io, 1, &w);
    return;
  }

  int status = code == 0 ? 200 : 500;
  const uint8_t *body = g_out.p;
  size_t body_len = g_out.len;

  int have_ct = 0;
  if (code == 0) {
    sp_cgi_load_config();
    if (g_cgi_headers && body_len) {
      int st = status;
      size_t at = sp_cgi_split_headers(resp, body, body_len, &st, &have_ct);
      if (at) { body += at; body_len -= at; status = st; }
    }
  } else {
    /* E013: a half-written body is worse than none, so stdout is discarded and
       stderr becomes the body.  Its size is reported so it is not invisible. */
    body = g_err.len ? g_err.p : (const uint8_t *)"spinel: the program exited non-zero\n";
    body_len = g_err.len ? g_err.len : 36;
  }

  char n[64];
  snprintf(n, sizeof n, "%d", code);          sp_hdr(resp, "x-spinel-exit", n);
  snprintf(n, sizeof n, "%zu", g_out.len);    sp_hdr(resp, "x-spinel-stdout-bytes", n);
  struct timespec t1;
  if (g_t0_ok && clock_gettime(CLOCK_MONOTONIC, &t1) == 0) {
    long ms = (long)((t1.tv_sec - g_t0.tv_sec) * 1000
                     + (t1.tv_nsec - g_t0.tv_nsec) / 1000000);
    snprintf(n, sizeof n, "%ld", ms < 0 ? 0 : ms);
    sp_hdr(resp, "x-spinel-ms", n);
  }
  sp_hdr(resp, "x-spinel-platform", "fastly");
  if (g_out.overflowed || g_err.overflowed || g_in_overflow)
    sp_hdr(resp, "x-spinel-truncated",
           g_in_overflow ? "stdin" : (g_out.overflowed ? "stdout" : "stderr"));

  /* A content-type from the program's own CGI block wins; otherwise the
     Config Store's SPINEL_CONTENT_TYPE; otherwise worker.mjs's default.
     Never both -- header_insert appends, so a duplicate would be visible. */
  sp_cgi_load_config();
  if (!have_ct)
    sp_hdr(resp, "content-type",
           g_content_type[0] ? g_content_type : "text/plain; charset=utf-8");

  sp_fa_raw_resp_status_set(resp, (uint16_t)status);
  if (body_len) {
    size_t off = 0;
    while (off < body_len) {
      size_t chunk = body_len - off;
      size_t w = 0;
      if (sp_fa_raw_body_write(rb, body + off, chunk, SP_FA_BODY_BACK, &w) != SP_FA_OK
          || w == 0) break;
      off += w;
    }
  }
  sp_fa_raw_resp_send_downstream(resp, rb, 0 /* not streaming: R008 D-4 */);
}

/* exit(n) -- and then ALWAYS proc_exit(0).  R008 §3.4-8: production Fastly
   maps a non-zero proc_exit to {"diagnostic":"runtime_terminated"} -> 500,
   which would replace the response we have just sent.  The status is not lost:
   it is the x-spinel-exit header, which is where E013 already put it. */
_Noreturn void __wrap_exit(int code) {
  sp_send_response(code);
  __real_exit(0);
}

/* ---- CGI variables ----------------------------------------------------------- */
static void sp_put_header_env(const char *name, const char *value) {
  size_t l = strlen(name);
  char key[256];
  if (l > sizeof key - 8) return;
  if (!strcasecmp(name, "content-type")) {
    setenv("CONTENT_TYPE", value, 1);
    return;
  }
  if (!strcasecmp(name, "content-length")) {
    setenv("CONTENT_LENGTH", value, 1);
    return;
  }
  memcpy(key, "HTTP_", 5);
  for (size_t i = 0; i < l; i++) {
    char c = name[i];
    key[5 + i] = (c == '-') ? '_' : (char)((c >= 'a' && c <= 'z') ? c - 32 : c);
  }
  key[5 + l] = 0;
  setenv(key, value, 1);
}

/* uri_get answers an ABSOLUTE url ("http://host/p?q") when the request had an
   absolute-form target, and whatever the client sent otherwise.  Split off the
   authority only when there really is a scheme, and never walk past the start
   of the string -- the probe's strstr("://") did on a relative URI. */
static const char *sp_uri_path(char *uri) {
  char *scheme = strstr(uri, "://");
  if (scheme && scheme > uri) {
    char *host = scheme + 3;
    char *slash = strchr(host, '/');
    char *qm = strchr(host, '?');
    if (slash && (!qm || slash < qm)) return slash;
    return qm ? qm : "/";          /* authority-only target: the path is "/" */
  }
  return uri[0] ? uri : "/";
}

extern int main(int, char **);

int __main_void(void) {
  g_t0_ok = (clock_gettime(CLOCK_MONOTONIC, &g_t0) == 0);

  if (sp_fa_init() != SP_FA_OK) {
    /* Production traps here on an ABI version mismatch; Viceroy only reports
       it (R008 §2.5).  Either way there is no way to answer, so say it loudly
       in the log and give the platform a zero status. */
    fprintf(stderr, "spinel-fastly: fastly_abi::init(1) refused\n");
    return 0;
  }
  if (sp_fa_downstream(&g_req, &g_body) != SP_FA_OK) {
    fprintf(stderr, "spinel-fastly: body_downstream_get failed\n");
    return 0;
  }
  g_started = 1;

  static uint8_t uri[SP_CGI_URI_MAX];
  size_t uri_n = 0;
  if (sp_fa_raw_req_uri_get(g_req, uri, sizeof uri - 1, &uri_n) != SP_FA_OK)
    uri_n = 0;
  uri[uri_n] = 0;

  static uint8_t meth[64];
  size_t meth_n = 0;
  if (sp_fa_raw_req_method_get(g_req, meth, sizeof meth - 1, &meth_n) != SP_FA_OK)
    meth_n = 0;
  meth[meth_n] = 0;

  static char path[SP_CGI_URI_MAX], query[SP_CGI_URI_MAX];
  const char *p = sp_uri_path((char *)uri);
  char *q = strchr(p, '?');
  if (q) {
    *q = 0;
    snprintf(query, sizeof query, "%s", q + 1);
  } else {
    query[0] = 0;
  }
  snprintf(path, sizeof path, "%s", p[0] ? p : "/");

  setenv("REQUEST_METHOD", meth_n ? (char *)meth : "GET", 1);
  setenv("PATH_INFO", path, 1);
  setenv("QUERY_STRING", query, 1);
  setenv("SCRIPT_NAME", "", 1);
  setenv("SERVER_PROTOCOL", "HTTP/1.1", 1);
  setenv("GATEWAY_INTERFACE", "CGI/1.1", 1);
  /* worker.mjs sets "spinel-wasm/workers"; same shape, so a Ruby program can
     tell the platforms apart from ENV alone (SpinelHost.platform). */
  setenv("SERVER_SOFTWARE", "spinel-wasm/fastly", 1);

  /* Request headers -> HTTP_* / CONTENT_*.  The names block is NUL separated
     and `ending_cursor == -1` terminates; one page has been enough for every
     request we have seen, and a second page would only add more variables. */
  static uint8_t names[SP_CGI_HDRS_MAX];
  size_t names_n = 0;
  int64_t cur = 0;
  if (sp_fa_raw_req_header_names_get(g_req, names, sizeof names, 0, &cur, &names_n)
      == SP_FA_OK) {
    for (size_t i = 0; i < names_n;) {
      size_t l = strlen((char *)names + i);
      if (!l) break;
      static uint8_t val[SP_CGI_VAL_MAX];
      size_t vn = 0;
      int64_t vc = 0;
      if (sp_fa_raw_req_header_values_get(g_req, names + i, l, val, sizeof val, 0,
                                          &vc, &vn) == SP_FA_OK && vn) {
        /* The value block is a NUL-separated list; CGI can hold one value, so
           the first is what ENV gets.  A program that needs all of them has
           the real header surface through SpinelHost (R008 §3.4-4). */
        val[vn - 1] = 0;
        sp_put_header_env((char *)names + i, (char *)val);
      }
      i += l + 1;
    }
  }

  /* Stage the request body for $stdin.  Fastly holds it host-side, so the only
     limit is the one we impose by copying it into linear memory -- which E013's
     `$stdin.read` contract requires. */
  for (;;) {
    if (g_in_len + 65536 > SP_CGI_MAX_STDIN) { g_in_overflow = 1; break; }
    uint8_t *nb = (uint8_t *)realloc(g_in, g_in_len + 65536);
    if (!nb) { g_in_overflow = 1; break; }
    g_in = nb;
    size_t got = 0;
    if (sp_fa_raw_body_read(g_body, g_in + g_in_len, 65536, &got) != SP_FA_OK) break;
    if (got == 0) break;
    g_in_len += got;
  }
  if (!getenv("CONTENT_LENGTH")) {
    char cl[32];
    snprintf(cl, sizeof cl, "%zu", g_in_len);
    setenv("CONTENT_LENGTH", cl, 1);
  }

  /* Ruby's ARGV is argv[1..], so ARGV[0] = path and ARGV[1] = query (E013). */
  static char prog[] = "spinel";
  static char *argvv[4];
  argvv[0] = prog;
  argvv[1] = path;
  argvv[2] = query;
  argvv[3] = NULL;

  int rc = main(3, argvv);
  sp_send_response(rc);

  /* ALWAYS 0.  crt1-command calls _Exit(r) -- not exit(r) -- for a non-zero
     return, and that is a non-zero proc_exit, which production Fastly turns
     into runtime_terminated -> 500 (R008 H5).  The status rides the header. */
  return 0;
}
