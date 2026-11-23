/* tools/wasm/fastly/fastly_abi.h -- THE contract header for Fastly Compute.
 *
 * E041's discipline, applied to a foreign ABI: every `import_module` /
 * `import_name` declaration this project makes against Fastly's
 * compute-at-edge ABI lives in THIS FILE AND NOWHERE ELSE.  fastly_cgi.c
 * (layer 0) and sp_fastly_host.c (layer 1) include it and call nothing raw.
 * When Fastly moves the ABI, the surface that breaks is one file.
 *
 * Fastly documents the raw ABI as "community-supported" and states plainly
 * that there is NO stability contract -- keeping a hand-written guest building
 * and compatible is our problem, by their own words:
 *   https://www.fastly.com/documentation/guides/compute/developer-guides/custom/
 * That is precisely why it is worth confining to one header.
 *
 * ---------------------------------------------------------------------------
 * THE OUT-PARAMETER TRAP (R008 §2.6, re-measured by E058 as Q5)
 *
 *   handle_t h = 0;
 *   object_store_lookup(store, "no-such-key", 11, &h);   ... returns status 0 !!
 *
 * A miss returns FastlyStatus::OK **and does not write the out parameter**.
 * Handle 0 is a perfectly valid handle, so a zero-initialised variable leaves
 * the caller reading whatever body handle 0 happens to be -- typically the
 * downstream request body.  The link succeeds, nothing traps, and only the
 * value is wrong: the exact failure shape E010 (SP_INT64) and E012
 * (Dir.home -> "") were built to remove.
 *
 * The rule this header enforces mechanically: EVERY handle out-parameter is
 * pre-filled with SP_FA_INVALID (0xFFFFFFFF) before the call, and a returned
 * value still equal to the sentinel means MISS.  Implementations call the
 * sp_fa_* wrappers below; they never see a raw hostcall.  (The Rust SDK does
 * the same thing, which is the only reason its users never met this.)
 * ---------------------------------------------------------------------------
 */
#ifndef SPINEL_FASTLY_ABI_H
#define SPINEL_FASTLY_ABI_H

#include <stddef.h>
#include <stdint.h>

#define SP_FA_IMP(mod, name) \
  __attribute__((import_module(mod), import_name(name)))

typedef uint32_t sp_fa_handle;

/* An unset handle.  Same value the Fastly SDKs use for "invalid handle". */
#define SP_FA_INVALID 0xFFFFFFFFu

/* FastlyStatus, the i32 every hostcall returns.  Measured values in E058's
   pre-flight probe are noted; the enum itself is Fastly's (fastly-sys). */
enum {
  SP_FA_OK          = 0,
  SP_FA_ERROR       = 1,   /* generic; e.g. object_store lookup with "" key   */
  SP_FA_INVAL       = 2,   /* undeclared KV store, undeclared backend         */
  SP_FA_BADF        = 3,   /* invalid handle; undeclared config store         */
  SP_FA_BUFLEN      = 4,   /* the buffer was too small -- NOT truncated       */
  SP_FA_UNSUPPORTED = 5,
  SP_FA_BADALIGN    = 6,
  SP_FA_HTTPINVALID = 7,
  SP_FA_HTTPUSER    = 8,
  SP_FA_HTTPINCOMPLETE = 9,
  SP_FA_NONE        = 10,  /* "there is no such thing" -- config store miss   */
  SP_FA_HTTPHEADTOOLARGE = 11,
  SP_FA_HTTPINVALIDSTATUS = 12,
  SP_FA_LIMITEXCEEDED = 13,
  SP_FA_AGAIN       = 14
};

/* BodyWriteEnd */
#define SP_FA_BODY_BACK  0u
#define SP_FA_BODY_FRONT 1u

/* ---- the raw imports (the ONLY place they appear) ------------------------- */

SP_FA_IMP("fastly_abi", "init")
int32_t sp_fa_raw_init(uint64_t abi_version);

SP_FA_IMP("fastly_http_req", "body_downstream_get")
int32_t sp_fa_raw_req_body_downstream_get(sp_fa_handle *req_out, sp_fa_handle *body_out);
SP_FA_IMP("fastly_http_req", "method_get")
int32_t sp_fa_raw_req_method_get(sp_fa_handle, uint8_t *, size_t, size_t *);
SP_FA_IMP("fastly_http_req", "uri_get")
int32_t sp_fa_raw_req_uri_get(sp_fa_handle, uint8_t *, size_t, size_t *);
SP_FA_IMP("fastly_http_req", "header_names_get")
int32_t sp_fa_raw_req_header_names_get(sp_fa_handle, uint8_t *, size_t, uint32_t,
                                       int64_t *, size_t *);
SP_FA_IMP("fastly_http_req", "header_values_get")
int32_t sp_fa_raw_req_header_values_get(sp_fa_handle, const uint8_t *, size_t,
                                        uint8_t *, size_t, uint32_t, int64_t *, size_t *);
SP_FA_IMP("fastly_http_req", "new")
int32_t sp_fa_raw_req_new(sp_fa_handle *);
SP_FA_IMP("fastly_http_req", "method_set")
int32_t sp_fa_raw_req_method_set(sp_fa_handle, const uint8_t *, size_t);
SP_FA_IMP("fastly_http_req", "uri_set")
int32_t sp_fa_raw_req_uri_set(sp_fa_handle, const uint8_t *, size_t);
SP_FA_IMP("fastly_http_req", "header_insert")
int32_t sp_fa_raw_req_header_insert(sp_fa_handle, const uint8_t *, size_t,
                                    const uint8_t *, size_t);
/* THE call.  Synchronous: the response handle comes back from this one
   invocation, which is why Fastly needs no JSPI and E014's stage-then-drain
   protocol is not required here (R008 §2.3). */
SP_FA_IMP("fastly_http_req", "send")
int32_t sp_fa_raw_req_send(sp_fa_handle req, sp_fa_handle body,
                           const uint8_t *backend, size_t backend_len,
                           sp_fa_handle *resp_out, sp_fa_handle *resp_body_out);

SP_FA_IMP("fastly_http_resp", "new")
int32_t sp_fa_raw_resp_new(sp_fa_handle *);
SP_FA_IMP("fastly_http_resp", "status_set")
int32_t sp_fa_raw_resp_status_set(sp_fa_handle, uint16_t);
SP_FA_IMP("fastly_http_resp", "status_get")
int32_t sp_fa_raw_resp_status_get(sp_fa_handle, uint16_t *);
SP_FA_IMP("fastly_http_resp", "header_insert")
int32_t sp_fa_raw_resp_header_insert(sp_fa_handle, const uint8_t *, size_t,
                                     const uint8_t *, size_t);
SP_FA_IMP("fastly_http_resp", "header_names_get")
int32_t sp_fa_raw_resp_header_names_get(sp_fa_handle, uint8_t *, size_t, uint32_t,
                                        int64_t *, size_t *);
SP_FA_IMP("fastly_http_resp", "header_values_get")
int32_t sp_fa_raw_resp_header_values_get(sp_fa_handle, const uint8_t *, size_t,
                                         uint8_t *, size_t, uint32_t, int64_t *, size_t *);
SP_FA_IMP("fastly_http_resp", "send_downstream")
int32_t sp_fa_raw_resp_send_downstream(sp_fa_handle resp, sp_fa_handle body,
                                       uint32_t streaming);

SP_FA_IMP("fastly_http_body", "new")
int32_t sp_fa_raw_body_new(sp_fa_handle *);
SP_FA_IMP("fastly_http_body", "read")
int32_t sp_fa_raw_body_read(sp_fa_handle, uint8_t *, size_t, size_t *);
SP_FA_IMP("fastly_http_body", "write")
int32_t sp_fa_raw_body_write(sp_fa_handle, const uint8_t *, size_t, uint32_t, size_t *);

/* KV Store.  This is the `fastly_object_store` namespace -- the OLDER of the
   two names for the same product.  It is the one R008 P10 and E058's
   pre-flight probe actually measured, and it is synchronous.  The newer
   `fastly_kv_store` namespace exists in Viceroy but has a lookup/lookup_wait
   shape that suggests it is asynchronous, and we have never called it: see
   E058 Honest boundary. */
SP_FA_IMP("fastly_object_store", "open")
int32_t sp_fa_raw_kv_open(const uint8_t *, size_t, sp_fa_handle *);
SP_FA_IMP("fastly_object_store", "lookup")
int32_t sp_fa_raw_kv_lookup(sp_fa_handle, const uint8_t *, size_t, sp_fa_handle *);
SP_FA_IMP("fastly_object_store", "insert")
int32_t sp_fa_raw_kv_insert(sp_fa_handle, const uint8_t *, size_t, sp_fa_handle);

SP_FA_IMP("fastly_config_store", "open")
int32_t sp_fa_raw_config_open(const uint8_t *, size_t, sp_fa_handle *);
SP_FA_IMP("fastly_config_store", "get")
int32_t sp_fa_raw_config_get(sp_fa_handle, const uint8_t *, size_t,
                             uint8_t *, size_t, size_t *);

/* ---- the sentinel-safe wrappers ------------------------------------------- */
/* Every function here that yields a handle takes `*out` and guarantees:
     return SP_FA_OK  and *out != SP_FA_INVALID   -> a real handle
     return SP_FA_OK  and *out == SP_FA_INVALID   -> a MISS (no such key)
     return != SP_FA_OK                           -> a failure; *out untouched
   There is no path on which an unwritten out parameter can be mistaken for a
   valid handle, because the sentinel is written by the wrapper, not by the
   caller who might forget. */

static inline int32_t sp_fa_init(void) { return sp_fa_raw_init(1); }

static inline int32_t sp_fa_downstream(sp_fa_handle *req, sp_fa_handle *body) {
  *req = SP_FA_INVALID; *body = SP_FA_INVALID;
  int32_t st = sp_fa_raw_req_body_downstream_get(req, body);
  if (st == SP_FA_OK && (*req == SP_FA_INVALID || *body == SP_FA_INVALID))
    return SP_FA_ERROR;                    /* OK with nothing written: refuse */
  return st;
}

static inline int32_t sp_fa_body_new(sp_fa_handle *out) {
  *out = SP_FA_INVALID;
  int32_t st = sp_fa_raw_body_new(out);
  if (st == SP_FA_OK && *out == SP_FA_INVALID) return SP_FA_ERROR;
  return st;
}

static inline int32_t sp_fa_resp_new(sp_fa_handle *out) {
  *out = SP_FA_INVALID;
  int32_t st = sp_fa_raw_resp_new(out);
  if (st == SP_FA_OK && *out == SP_FA_INVALID) return SP_FA_ERROR;
  return st;
}

static inline int32_t sp_fa_req_new(sp_fa_handle *out) {
  *out = SP_FA_INVALID;
  int32_t st = sp_fa_raw_req_new(out);
  if (st == SP_FA_OK && *out == SP_FA_INVALID) return SP_FA_ERROR;
  return st;
}

static inline int32_t sp_fa_send(sp_fa_handle req, sp_fa_handle body,
                                 const char *backend, size_t backend_len,
                                 sp_fa_handle *resp, sp_fa_handle *resp_body) {
  *resp = SP_FA_INVALID; *resp_body = SP_FA_INVALID;
  int32_t st = sp_fa_raw_req_send(req, body, (const uint8_t *)backend, backend_len,
                                  resp, resp_body);
  if (st == SP_FA_OK && (*resp == SP_FA_INVALID || *resp_body == SP_FA_INVALID))
    return SP_FA_ERROR;
  return st;
}

static inline int32_t sp_fa_kv_open(const char *name, size_t len, sp_fa_handle *out) {
  *out = SP_FA_INVALID;
  int32_t st = sp_fa_raw_kv_open((const uint8_t *)name, len, out);
  if (st == SP_FA_OK && *out == SP_FA_INVALID) return SP_FA_ERROR;
  return st;
}

/* ★ The one that matters.  status OK + sentinel intact == the key is absent.
   Returns 1 = hit (body in *out), 0 = miss, negative = the FastlyStatus. */
static inline int sp_fa_kv_lookup(sp_fa_handle store, const char *key, size_t len,
                                  sp_fa_handle *out) {
  *out = SP_FA_INVALID;
  int32_t st = sp_fa_raw_kv_lookup(store, (const uint8_t *)key, len, out);
  if (st != SP_FA_OK) return -(int)st;
  return (*out == SP_FA_INVALID) ? 0 : 1;
}

static inline int32_t sp_fa_config_open(const char *name, size_t len, sp_fa_handle *out) {
  *out = SP_FA_INVALID;
  int32_t st = sp_fa_raw_config_open((const uint8_t *)name, len, out);
  if (st == SP_FA_OK && *out == SP_FA_INVALID) return SP_FA_ERROR;
  return st;
}

/* 1 = found (bytes in buf, count in *n), 0 = no such key, negative = status.
   A config-store miss is SP_FA_NONE, which is a *different* shape from the KV
   sentinel trap -- one more reason nothing calls these raw. */
static inline int sp_fa_config_get(sp_fa_handle store, const char *key, size_t klen,
                                   uint8_t *buf, size_t cap, size_t *n) {
  *n = 0;
  int32_t st = sp_fa_raw_config_get(store, (const uint8_t *)key, klen, buf, cap, n);
  if (st == SP_FA_NONE) return 0;
  if (st != SP_FA_OK) return -(int)st;
  return 1;
}

/* A short, stable name for a status, for exception messages.  A number alone
   would make every Fastly failure look the same from Ruby. */
static inline const char *sp_fa_status_name(int st) {
  if (st < 0) st = -st;
  switch (st) {
    case SP_FA_OK:              return "OK";
    case SP_FA_ERROR:           return "ERROR";
    case SP_FA_INVAL:           return "INVALID_ARGUMENT";
    case SP_FA_BADF:            return "BAD_HANDLE";
    case SP_FA_BUFLEN:          return "BUFFER_TOO_SMALL";
    case SP_FA_UNSUPPORTED:     return "UNSUPPORTED";
    case SP_FA_BADALIGN:        return "BAD_ALIGNMENT";
    case SP_FA_HTTPINVALID:     return "HTTP_INVALID";
    case SP_FA_HTTPUSER:        return "HTTP_USER";
    case SP_FA_HTTPINCOMPLETE:  return "HTTP_INCOMPLETE";
    case SP_FA_NONE:            return "NONE";
    case SP_FA_HTTPHEADTOOLARGE:return "HTTP_HEAD_TOO_LARGE";
    case SP_FA_HTTPINVALIDSTATUS: return "HTTP_INVALID_STATUS";
    case SP_FA_LIMITEXCEEDED:   return "LIMIT_EXCEEDED";
    case SP_FA_AGAIN:           return "AGAIN";
    default:                    return "UNKNOWN";
  }
}

/* ---- the platform name, for message text (R008 D-5) -----------------------
   raise_stubs.c defines this WEAK as "Cloudflare Workers"; fastly_cgi.c
   defines it strong as "Fastly Compute".  A weak symbol is how the platform
   gets into every NotImplementedError message without adding a -D to $CFLAGS
   -- and $CFLAGS must stay one array, byte for byte, or the runtime object
   cache stops being shareable between the two platforms (D-1). */
extern const char *const sp_platform_name;

#endif /* SPINEL_FASTLY_ABI_H */
