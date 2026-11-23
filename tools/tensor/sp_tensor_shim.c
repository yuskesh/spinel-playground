/* sp_tensor_shim.c -- E031: the seam under spinel/tensor.rb.
 *
 * Generalised from E030's sp_gpu_shim.c (452 lines, one hard-wired saxpy
 * entry) into three things it did not have:
 *
 *   1. an N-ENTRY TABLE.  `spinel-mlirgen --tensor` emits sp_tensor_table.h
 *      with one row per tensor_def; dispatch is by name, so adding a kernel
 *      touches no C.
 *   2. DEVICE-RESIDENT BUFFERS as the normal case.  A Tensor owns a handle
 *      into g_bufs; nothing crosses the host boundary between the initial
 *      uploads and the final readback.  E030 s4.2 measured that this is not a
 *      nicety: without residency the GPU never beats the pure-Ruby loop, even
 *      at N=16M.
 *   3. TRANSFER COUNTERS, so a Ruby program can assert on its own traffic
 *      (E031 gate d).
 *
 * Two things from E030 are carried over verbatim because they are ABI:
 *
 *   - IREE_HAL_MEMORY_TYPE_HOST_CACHED on every buffer the host reads: the
 *     readback staging buffer AND (E037, fixing what E036 s6 found) the
 *     resident buffers sp_t_alloc hands out.  Without it IREE's Metal allocator
 *     picks MTLResourceCPUCacheModeWriteCombined and the CPU read is 56x slower
 *     at N=16M, silently and with the same answer (E030 s4.3).
 *   - the staging buffer is allocated once and reused, not per call, which is
 *     the other half of that 56x.
 *
 * Everything crossing into Ruby is scalar+pointer, which is the whole of
 * spinel's FFI boundary (R001 s1.5).  Declarations: tools/tensor/spinel/tensor.rb.
 *
 * NOT thread safe: every bit of state here is a process-global static, exactly
 * as in E030.  Spinel's M:N threads calling in concurrently would corrupt it.
 */

#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iree/runtime/api.h"
#include "sp_tensor_table.h"

#ifdef SP_T_STATIC_DEVICE
iree_status_t sp_t_static_device(const char *uri, iree_allocator_t a, iree_hal_device_t **out);
#endif

/* ------------------------------------------------------------------ state */

static iree_runtime_instance_t *g_instance = NULL;
static iree_hal_device_t       *g_device   = NULL;
static iree_runtime_session_t  *g_session  = NULL;
static char g_err[512] = {0};
/* E072 s5: is this scope running on the Metal backend?  The only thing that
 * depends on it is the byte-destination guard in invoke() -- see SP_T_U8_TAIL.
 * Recorded from the device URI at sp_t_open, because that is the only place the
 * surface ever names a backend. */
static int g_is_metal = 0;

/* Counters, read from Ruby via sp_t_counter(i).  Gate (d) asserts on 0 and 1. */
enum { C_H2D = 0, C_D2H = 1, C_INVOKE = 2, C_ALLOC = 3, C_FREE = 4, C_FILL = 5,
       C_NCOUNTER = 6 };
static int64_t g_count[C_NCOUNTER];

/* E037: element types.  The surface was f32-only through E036 because every
 * kernel was one we generated and the generator only speaks f32.  A FOREIGN
 * module brings its own: E037 exports a uint8 input (the u8->f32 scaling moved
 * into the graph, s3) and int8 weights (the quantised model, s1).  The codes
 * are shared, by value, with spinel/tensor.rb and spinel-mlirgen's table -- a
 * mismatch between the Ruby dtype and the module's is caught by --extern-check
 * at build time and by the `dtypes` column of the entry table at dispatch. */
enum { SP_T_F32 = 0, SP_T_U8 = 1, SP_T_F16 = 2, SP_T_I8 = 3, SP_T_I32 = 4,
       SP_T_NDTYPE = 5 };
static const char *const SP_T_DTNAME[SP_T_NDTYPE] = {"f32", "u8", "f16", "i8", "i32"};

/* E038: how many captured f32 scalars a dispatch can carry.  A tensor_def has
 * at most one (:scalar); a fused call-site expression may mention several. */
#define SP_T_MAX_SCALARS 4
static const int SP_T_DTSIZE[SP_T_NDTYPE] = {4, 1, 2, 1, 4};

static iree_hal_element_type_t sp_t_eltype(int dt) {
  switch (dt) {
    case SP_T_U8:  return IREE_HAL_ELEMENT_TYPE_UINT_8;
    case SP_T_F16: return IREE_HAL_ELEMENT_TYPE_FLOAT_16;
    case SP_T_I8:  return IREE_HAL_ELEMENT_TYPE_SINT_8;
    case SP_T_I32: return IREE_HAL_ELEMENT_TYPE_SINT_32;
    default:       return IREE_HAL_ELEMENT_TYPE_FLOAT_32;
  }
}

/* f16 is a STORAGE type here: values cross the Ruby boundary as f64 and are
 * rounded once, on this side, by the same round-to-nearest-even the hardware
 * uses.  _Float16 is native on arm64; elsewhere the surface refuses :f16 at
 * allocation rather than emulating it and calling the result the same thing. */
#if defined(__FLT16_MAX__)
#define SP_T_HAVE_F16 1
typedef _Float16 sp_f16_t;
#else
#define SP_T_HAVE_F16 0
typedef unsigned short sp_f16_t;
#endif

/* Handle table.  A Ruby Tensor holds `index + 1`; 0 is never a live handle.
 * E033: the RANK and the individual dimensions travel with the buffer, because
 * the shape checks a rank-2 vocabulary needs (matvec's cols(W) == len(x)) can
 * only be made here -- the Ruby side has no way to see the other argument.
 * E037 adds the DTYPE for the same reason: only this side can see that the
 * tensor handed to a foreign entry is f32 where the module wants ui8. */
/* E039: the rank ceiling.  Through E038 a Tensor was rank 1 or rank 2 and the
 * rank was ENCODED (d1 == 0 meant rank 1), which is why widening it is a change
 * to the struct and not just to a constant.  4 is the ceiling because NHWC is
 * the layout every named conv op in linalg speaks (R005 s2.4-F) and because the
 * `ranks` column of the entry table is one ASCII digit per tensor -- it would
 * hold 9, but the generator's identity-map emission is the part that would have
 * to grow, and nothing in P002 asks for rank 5. */
#define SP_T_MAX_RANK 4

typedef struct {
  iree_hal_buffer_view_t *bv;
  size_t n;                    /* total elements */
  size_t d[SP_T_MAX_RANK];     /* d[0..rank-1]; the rest are 0 */
  int rank;
  int dt;                      /* SP_T_F32 | SP_T_U8 | ... */
  int live;
} sp_t_buf_t;

static sp_t_buf_t *g_bufs = NULL;
static size_t g_nbufs = 0, g_capbufs = 0;

/* Host-side f32 staging, grown on demand, reused across calls. */
static float *g_stage_f32 = NULL;
static size_t g_stage_f32_n = 0;

/* Device-side readback staging: allocated once, HOST_CACHED (see the header).
 * Sized in BYTES since E037 (a tensor's element is no longer always 4 bytes). */
static iree_hal_buffer_t *g_stage = NULL;
static size_t g_stage_n = 0;

/* --------------------------------------------------------------- plumbing */

static int fail(iree_status_t status, const char *what) {
  char *buf = NULL;
  iree_host_size_t len = 0;
  iree_allocator_t sys = iree_allocator_system();
  if (iree_status_to_string(status, &sys, &buf, &len)) {
    snprintf(g_err, sizeof g_err, "%s: %.*s", what, (int)len, buf);
    iree_allocator_free(sys, buf);
  } else {
    snprintf(g_err, sizeof g_err, "%s: status code %d", what,
             (int)iree_status_code(status));
  }
  iree_status_ignore(status);
  return -1;
}

static int failf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_err, sizeof g_err, fmt, ap);
  va_end(ap);
  return -1;
}

static const sp_t_entry_t *lookup(const char *name) {
  for (int i = 0; i < SP_T_TABLE_N; i++)
    if (strcmp(SP_T_TABLE[i].name, name) == 0) return &SP_T_TABLE[i];
  return NULL;
}

static sp_t_buf_t *deref(int64_t h) {
  if (h <= 0 || (size_t)h > g_nbufs) return NULL;
  sp_t_buf_t *b = &g_bufs[h - 1];
  return b->live ? b : NULL;
}

static float *stage_f32(size_t n) {
  if (n == 0) n = 1;
  if (n > g_stage_f32_n) {
    float *p = (float *)realloc(g_stage_f32, n * sizeof(float));
    if (!p) return NULL;
    g_stage_f32 = p;
    g_stage_f32_n = n;
  }
  return g_stage_f32;
}

/* -------------------------------------------------------------- lifecycle */

/* E037 s2: a module that is IN THE BINARY, not next to it.  iree-c-embed-data
 * turns a .vmfb into a C array; the program's own TU registers it here (from a
 * constructor, before Ruby runs) and the surface names it "@<name>" wherever a
 * path would go.  The shim never sees the symbol, so nothing about this couples
 * the shim to a particular embedded module -- or to there being one at all. */
typedef struct { const char *name; const void *data; size_t len; } sp_t_mod_t;
enum { SP_T_MAX_EMBEDDED = 8 };
static sp_t_mod_t g_mods[SP_T_MAX_EMBEDDED];
static int g_nmods = 0;

int sp_t_register_module(const char *name, const void *data, int64_t len) {
  if (!name || !data || len <= 0) return -1;
  if (g_nmods >= SP_T_MAX_EMBEDDED) return -1;
  g_mods[g_nmods].name = name;
  g_mods[g_nmods].data = data;
  g_mods[g_nmods].len = (size_t)len;
  g_nmods++;
  return 0;
}

/* AN EMBEDDED MODULE IS COPIED OUT OF THE IMAGE BEFORE IT IS APPENDED, and
 * that memcpy cost a SIGBUS to find (E037 s2).
 *
 * Handing IREE the `const uint8_t[]` that iree-c-embed-data emits works for the
 * llvm-cpu .vmfb and CRASHES for the metal-spirv one: EXC_BAD_ACCESS on a load
 * 4 700 bytes into the module, from an address that is inside the binary's
 * mapped __TEXT,__const section.  Copying the identical bytes into ordinary
 * process memory fixes it, and results/E037/embed_probe.tsv records the probes
 * that ruled out the obvious explanation: it is NOT alignment (a copy placed at
 * page+64 and one placed at page+2432 -- the very offset the linker gave the
 * array -- both work), and it is NOT that IREE writes to the buffer (a copy
 * mprotect'ed PROT_READ works).  The mechanism is not identified; the copy is,
 * and it costs one memcpy of the module at scope open.
 *
 * Freed at sp_t_close. */
static void *g_mod_copies[SP_T_MAX_EMBEDDED];
static int g_nmod_copies = 0;

static int append_module(const char *spec) {
  if (spec && spec[0] == '@') {
    for (int i = 0; i < g_nmods; i++) {
      if (strcmp(g_mods[i].name, spec + 1) == 0) {
        if (g_nmod_copies >= SP_T_MAX_EMBEDDED)
          return failf("sp_t_open: too many embedded modules in one scope");
        void *p = malloc(g_mods[i].len);
        if (!p)
          return failf("sp_t_open: could not copy embedded module '%s' (%zu bytes)",
                       spec + 1, g_mods[i].len);
        memcpy(p, g_mods[i].data, g_mods[i].len);
        g_mod_copies[g_nmod_copies++] = p;
        iree_status_t st = iree_runtime_session_append_bytecode_module_from_memory(
            g_session, iree_make_const_byte_span(p, g_mods[i].len),
            iree_allocator_null());
        if (!iree_status_is_ok(st)) return fail(st, "load_embedded_module");
        return 0;
      }
    }
    return failf("sp_t_open: no embedded module named '%s'. Embedded modules are "
                 "registered by the program's own TU at start-up (E037 s2); a name "
                 "that is not registered cannot appear later", spec + 1);
  }
  iree_status_t st = iree_runtime_session_append_bytecode_module_from_file(g_session, spec);
  /* This is where a CPU .vmfb loaded onto a metal device is caught
     (E030 s5): INCOMPATIBLE, at load time, loudly. */
  if (!iree_status_is_ok(st)) return fail(st, "load_module");
  return 0;
}

/* E037 s3: a SECOND module in the SAME session.  E034's premise was one .vmfb
 * per scope, which pushed everything the model does not do (the u8 -> f32
 * scaling) back into the Ruby `while` loop -- 39 ms per 10 000 images, more than
 * the inference itself.  iree_runtime_session_append_bytecode_module_* may be
 * called any number of times, so this is additive in the strict sense: a program
 * that never calls it sees the E034 behaviour. */
int sp_t_append(const char *vmfb_path) {
  g_err[0] = 0;
  if (!g_session)
    return failf("sp_t_append: no device scope is open (wrap the work in Tensor.device)");
  if (!vmfb_path || !vmfb_path[0])
    return failf("sp_t_append: no .vmfb path");
  return append_module(vmfb_path);
}

int sp_t_open(const char *vmfb_path, const char *device_uri) {
  g_err[0] = 0;
  if (g_session) return failf("sp_t_open: a device scope is already open "
                              "(Tensor.device blocks do not nest)");
  if (!vmfb_path || !vmfb_path[0])
    return failf("sp_t_open: no .vmfb path. The module must exist at COMPILE "
                 "time -- an AOT binary carries no runtime compiler (E030)");
  memset(g_count, 0, sizeof g_count);
  g_is_metal = (device_uri && strstr(device_uri, "metal") != NULL);

  iree_runtime_instance_options_t opts;
  iree_runtime_instance_options_initialize(&opts);
  iree_runtime_instance_options_use_all_available_drivers(&opts);
  iree_status_t st =
      iree_runtime_instance_create(&opts, iree_allocator_system(), &g_instance);
  if (!iree_status_is_ok(st)) return fail(st, "instance_create");

#ifdef SP_T_STATIC_DEVICE
  /* A program with no driver registry (tools/npu) builds its own device. */
  st = sp_t_static_device(device_uri, iree_runtime_instance_host_allocator(g_instance), &g_device);
#else
  st = iree_runtime_instance_try_create_default_device(
      g_instance, iree_make_cstring_view(device_uri), &g_device);
#endif
  if (!iree_status_is_ok(st)) {
    /* E012 policy: an absent GPU is a catchable condition on the Ruby side,
       not a crash.  spinel/tensor.rb turns this into a TensorError. */
    iree_runtime_instance_release(g_instance);
    g_instance = NULL;
    return fail(st, "create_device");
  }

  iree_runtime_session_options_t sopts;
  iree_runtime_session_options_initialize(&sopts);
  st = iree_runtime_session_create_with_device(
      g_instance, &sopts, g_device,
      iree_runtime_instance_host_allocator(g_instance), &g_session);
  if (!iree_status_is_ok(st)) return fail(st, "session_create");

  if (append_module(vmfb_path) != 0) {
    /* E037: unwind the whole scope, not just the session.  E034 left the
       instance and the device standing, so a program that caught the error and
       opened a second scope leaked both and overwrote the globals. */
    iree_runtime_session_release(g_session);
    g_session = NULL;
    iree_hal_device_release(g_device);
    g_device = NULL;
    iree_runtime_instance_release(g_instance);
    g_instance = NULL;
    return -1;
  }
  return 0;
}

void sp_t_close(void) {
  for (size_t i = 0; i < g_nbufs; i++) {
    if (g_bufs[i].live) {
      iree_hal_buffer_view_release(g_bufs[i].bv);
      g_bufs[i].live = 0;
    }
  }
  free(g_bufs);
  g_bufs = NULL;
  g_nbufs = g_capbufs = 0;
  iree_hal_buffer_release(g_stage);
  g_stage = NULL;
  g_stage_n = 0;
  iree_runtime_session_release(g_session);
  g_session = NULL;
  iree_hal_device_release(g_device);
  g_device = NULL;
  iree_runtime_instance_release(g_instance);
  g_instance = NULL;
  free(g_stage_f32);
  g_stage_f32 = NULL;
  g_stage_f32_n = 0;
  for (int i = 0; i < g_nmod_copies; i++) free(g_mod_copies[i]);
  g_nmod_copies = 0;
}

const char *sp_t_last_error(void) { return g_err; }

int64_t sp_t_counter(int i) {
  return (i >= 0 && i < C_NCOUNTER) ? g_count[i] : -1;
}

/* ------------------------------------------------------ resident buffers */

/* DEVICE_LOCAL for the kernel, HOST_VISIBLE + MAPPING so the f64->f32 upload
 * writes straight into device memory (unified on Apple silicon) instead of
 * through a second host copy.
 *
 * E037 (fixing what E036 s6 found): HOST_CACHED is part of that request, not an
 * optimisation.  Without it IREE's Metal allocator picks
 * MTLResourceCPUCacheModeWriteCombined, `iree_hal_buffer_map_read` still
 * SUCCEEDS on Apple's unified memory -- so the HOST_CACHED staging path in
 * read_f32 below never runs -- and the CPU read is 6.1-8.4x slower with the same
 * answer and no error (E036 readback.tsv; E030 s4.3 measured 56x on its own
 * path).  Some allocators legitimately refuse the combination, so a refusal
 * falls back to the E034 request rather than failing the allocation. */
/* E039: the general form.  `rank` is now SAID, not encoded in d1 == 0, because
 * a rank-3 image may legitimately have a zero-length axis in the same way a
 * rank-1 vector may.  sp_t_alloc_dt keeps its exact E037 behaviour by deriving
 * the rank the old way and calling this, so every E031..E038 allocation takes
 * the identical path and produces the identical buffer view. */
int64_t sp_t_alloc_nd(size_t d0, size_t d1, size_t d2, size_t d3, int rank, int dt) {
  g_err[0] = 0;
  if (!g_session) {
    failf("sp_t_alloc: no device scope is open (wrap the work in Tensor.device)");
    return 0;
  }
  if (dt < 0 || dt >= SP_T_NDTYPE) {
    failf("sp_t_alloc: dtype code %d is not one of f32/u8/f16/i8/i32", dt);
    return 0;
  }
  if (dt == SP_T_F16 && !SP_T_HAVE_F16) {
    failf("sp_t_alloc: :f16 needs a compiler with _Float16 (this build has none) -- "
          "the surface refuses rather than emulating half and calling it the same thing");
    return 0;
  }
  if (rank < 1 || rank > SP_T_MAX_RANK) {
    failf("sp_t_alloc: rank %d is outside 1..%d (a Tensor is a :vec, :mat, :ten3 or "
          ":ten4)", rank, SP_T_MAX_RANK);
    return 0;
  }
  const size_t dd[SP_T_MAX_RANK] = {d0, d1, d2, d3};
  size_t n = 1;
  for (int i = 0; i < rank; i++) n *= dd[i];
  if (n == 0) n = 1;  /* IREE rejects a zero-length allocation */

  iree_hal_buffer_params_t p = {
      .type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL | IREE_HAL_MEMORY_TYPE_HOST_VISIBLE |
              IREE_HAL_MEMORY_TYPE_HOST_CACHED, /* load-bearing: E036 s6 */
      .access = IREE_HAL_MEMORY_ACCESS_ALL,
      .usage = IREE_HAL_BUFFER_USAGE_DEFAULT | IREE_HAL_BUFFER_USAGE_MAPPING,
  };
  iree_hal_dim_t shape[SP_T_MAX_RANK];
  for (int i = 0; i < rank; i++)
    shape[i] = (iree_hal_dim_t)(rank == 1 ? n : dd[i]);
  iree_hal_buffer_t *b = NULL;
  iree_hal_allocator_t *dalloc = iree_runtime_session_device_allocator(g_session);
  const size_t bytes = n * (size_t)SP_T_DTSIZE[dt];
  iree_status_t st = iree_hal_allocator_allocate_buffer(dalloc, p, bytes, &b);
  if (!iree_status_is_ok(st)) {
    /* An allocator that cannot give us a cached device-local buffer is not an
       error -- it is the E034 request.  Only the readback gets slower. */
    iree_status_ignore(st);
    p.type &= ~(iree_hal_memory_type_t)IREE_HAL_MEMORY_TYPE_HOST_CACHED;
    st = iree_hal_allocator_allocate_buffer(dalloc, p, bytes, &b);
  }
  iree_hal_buffer_view_t *bv = NULL;
  if (iree_status_is_ok(st))
    st = iree_hal_buffer_view_create(
        b, (iree_host_size_t)rank, shape, sp_t_eltype(dt),
        IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR,
        iree_runtime_session_host_allocator(g_session), &bv);
  iree_hal_buffer_release(b);
  if (!iree_status_is_ok(st)) {
    fail(st, "sp_t_alloc");
    return 0;
  }

  size_t slot = g_nbufs;
  for (size_t i = 0; i < g_nbufs; i++)
    if (!g_bufs[i].live) { slot = i; break; }
  if (slot == g_nbufs) {
    if (g_nbufs == g_capbufs) {
      size_t cap = g_capbufs ? g_capbufs * 2 : 16;
      sp_t_buf_t *nb = (sp_t_buf_t *)realloc(g_bufs, cap * sizeof(sp_t_buf_t));
      if (!nb) {
        iree_hal_buffer_view_release(bv);
        failf("sp_t_alloc: handle table realloc failed");
        return 0;
      }
      g_bufs = nb;
      g_capbufs = cap;
    }
    g_nbufs++;
  }
  g_bufs[slot].bv = bv;
  g_bufs[slot].n = n;
  for (int i = 0; i < SP_T_MAX_RANK; i++)
    g_bufs[slot].d[i] = i >= rank ? 0 : (rank == 1 ? n : dd[i]);
  g_bufs[slot].rank = rank;
  g_bufs[slot].dt = dt;
  g_bufs[slot].live = 1;
  g_count[C_ALLOC]++;
  return (int64_t)(slot + 1);
}

/* The E037 spelling, byte-for-byte behaviour preserved: d1 == 0 IS the rank-1
 * spelling on this entry point, and it stays that way because the generated
 * dispatches E031..E038 recorded are the ABI those measurements were taken
 * against. */
int64_t sp_t_alloc_dt(size_t d0, size_t d1, int dt) {
  return sp_t_alloc_nd(d0, d1, 0, 0, d1 == 0 ? 1 : 2, dt);
}

/* The E031..E036 spelling, unchanged: f32 is still what a Tensor is unless the
 * declaration says otherwise. */
int64_t sp_t_alloc(size_t d0, size_t d1) {
  return sp_t_alloc_dt(d0, d1, SP_T_F32);
}

void sp_t_free(int64_t h) {
  sp_t_buf_t *b = deref(h);
  if (!b) return;
  iree_hal_buffer_view_release(b->bv);
  b->bv = NULL;
  b->live = 0;
  g_count[C_FREE]++;
}

/* Map a resident buffer for writing.  Returns NULL and sets g_err on failure;
 * *out_mapping is only valid when non-NULL is returned. */
static void *map_write(sp_t_buf_t *b, size_t nbytes, iree_hal_buffer_mapping_t *m) {
  iree_status_t st = iree_hal_buffer_map_range(
      iree_hal_buffer_view_buffer(b->bv), IREE_HAL_MAPPING_MODE_SCOPED,
      IREE_HAL_MEMORY_ACCESS_WRITE, 0, nbytes, m);
  if (!iree_status_is_ok(st)) {
    fail(st, "map_write");
    return NULL;
  }
  return (void *)m->contents.data;
}

/* E037: the ONE place a Ruby Float becomes a device element, and the one place
 * it comes back.  Integer dtypes round to nearest and SATURATE -- a value that
 * does not fit is clamped, not wrapped, because a wrapped pixel is a silently
 * wrong answer and this surface's rule (E018/E012) is never to do that quietly.
 * f32/f16 round once, here, by the host's round-to-nearest-even. */
static inline unsigned char sat_u8(double v) {
  v = v < 0.0 ? 0.0 : (v > 255.0 ? 255.0 : v);
  return (unsigned char)(v + 0.5);
}
static inline signed char sat_i8(double v) {
  v = v < -128.0 ? -128.0 : (v > 127.0 ? 127.0 : v);
  return (signed char)(v < 0 ? v - 0.5 : v + 0.5);
}
static inline int32_t sat_i32(double v) {
  v = v < -2147483648.0 ? -2147483648.0 : (v > 2147483647.0 ? 2147483647.0 : v);
  return (int32_t)(v < 0 ? v - 0.5 : v + 0.5);
}

/* The dtype switch is OUTSIDE the loop and the loop body has no branch on it.
 * The first version of this had `use_scalar ? scalar : src[i]` inside the loop
 * to share the code with sp_t_fill, and that ternary cost 2.7x on the f32 h2d
 * (0.14 -> 0.37 ms at N=1M) by blocking vectorisation -- caught by E037's own
 * `h2d` gate, which exists because E036 asked whether HOST_CACHED slows writes
 * down.  A measurement kept in the harness catches the regression the surface
 * change itself introduced. */
static void store_elems(void *dst, int dt, const double *src, size_t n) {
  size_t i;
  switch (dt) {
    case SP_T_F32: {
      float *d = (float *)dst;
      for (i = 0; i < n; i++) d[i] = (float)src[i];
      break;
    }
    case SP_T_F16: {
      sp_f16_t *d = (sp_f16_t *)dst;
      for (i = 0; i < n; i++) d[i] = (sp_f16_t)src[i];
      break;
    }
    case SP_T_U8: {
      unsigned char *d = (unsigned char *)dst;
      for (i = 0; i < n; i++) d[i] = sat_u8(src[i]);
      break;
    }
    case SP_T_I8: {
      signed char *d = (signed char *)dst;
      for (i = 0; i < n; i++) d[i] = sat_i8(src[i]);
      break;
    }
    default: {
      int32_t *d = (int32_t *)dst;
      for (i = 0; i < n; i++) d[i] = sat_i32(src[i]);
      break;
    }
  }
}

static void fill_elems(void *dst, int dt, double v, size_t n) {
  size_t i;
  switch (dt) {
    case SP_T_F32: {
      float *d = (float *)dst, f = (float)v;
      for (i = 0; i < n; i++) d[i] = f;
      break;
    }
    case SP_T_F16: {
      sp_f16_t *d = (sp_f16_t *)dst, f = (sp_f16_t)v;
      for (i = 0; i < n; i++) d[i] = f;
      break;
    }
    case SP_T_U8: {
      unsigned char *d = (unsigned char *)dst, f = sat_u8(v);
      for (i = 0; i < n; i++) d[i] = f;
      break;
    }
    case SP_T_I8: {
      signed char *d = (signed char *)dst, f = sat_i8(v);
      for (i = 0; i < n; i++) d[i] = f;
      break;
    }
    default: {
      int32_t *d = (int32_t *)dst, f = sat_i32(v);
      for (i = 0; i < n; i++) d[i] = f;
      break;
    }
  }
}

static void load_elems(double *dst, int dt, const void *src, size_t n) {
  size_t i;
  switch (dt) {
    case SP_T_F32: {
      const float *s = (const float *)src;
      for (i = 0; i < n; i++) dst[i] = (double)s[i];
      break;
    }
    case SP_T_F16: {
      const sp_f16_t *s = (const sp_f16_t *)src;
      for (i = 0; i < n; i++) dst[i] = (double)(float)s[i];
      break;
    }
    case SP_T_U8: {
      const unsigned char *s = (const unsigned char *)src;
      for (i = 0; i < n; i++) dst[i] = (double)s[i];
      break;
    }
    case SP_T_I8: {
      const signed char *s = (const signed char *)src;
      for (i = 0; i < n; i++) dst[i] = (double)s[i];
      break;
    }
    default: {
      const int32_t *s = (const int32_t *)src;
      for (i = 0; i < n; i++) dst[i] = (double)s[i];
      break;
    }
  }
}

int sp_t_fill(int64_t h, double v, size_t n) {
  g_err[0] = 0;
  sp_t_buf_t *b = deref(h);
  if (!b) return failf("sp_t_fill: handle %lld is not live", (long long)h);
  if (n == 0) return 0;
  if (n > b->n) return failf("sp_t_fill: %zu elements into a [%zu] tensor", n, b->n);
  iree_hal_buffer_mapping_t m;
  void *d = map_write(b, n * (size_t)SP_T_DTSIZE[b->dt], &m);
  if (!d) return -1;
  fill_elems(d, b->dt, v, n);
  iree_hal_buffer_unmap_range(&m);
  g_count[C_FILL]++;
  return 0;
}

/* host -> device.  `src` is the Spinel Array's contiguous .data (:float_array
 * is `const double *`, src/codegen_call.c:18672); we only read it, and we do
 * not retain it -- docs/FFI.md's lifetime is call-duration only. */
int sp_t_h2d(int64_t h, const double *src, size_t n) {
  g_err[0] = 0;
  sp_t_buf_t *b = deref(h);
  if (!b) return failf("sp_t_h2d: handle %lld is not live", (long long)h);
  if (n == 0) return 0;
  if (n > b->n) return failf("sp_t_h2d: %zu elements into a [%zu] tensor", n, b->n);
  const size_t esz = (size_t)SP_T_DTSIZE[b->dt];
  iree_hal_buffer_mapping_t m;
  void *d = map_write(b, n * esz, &m);
  if (d) {
    store_elems(d, b->dt, src, n);
    iree_hal_buffer_unmap_range(&m);
  } else {
    /* A buffer that came back out of a dispatch may be DEVICE_LOCAL only.
       Stage through the host instead of pretending the write happened. */
    float *s = stage_f32((n * esz + sizeof(float) - 1) / sizeof(float));
    if (!s) return failf("sp_t_h2d: staging alloc failed");
    store_elems(s, b->dt, src, n);
    iree_status_t st = iree_hal_device_transfer_h2d(
        g_device, s, iree_hal_buffer_view_buffer(b->bv), 0, n * esz,
        IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT, iree_infinite_timeout());
    if (!iree_status_is_ok(st)) return fail(st, "sp_t_h2d");
    g_err[0] = 0;
  }
  g_count[C_H2D]++;
  return 0;
}

/* E037 s3: RAW BYTES straight into a byte-typed tensor.
 *
 * E034 s7 measured the cost of not having this: 10 000 MNIST images cost 39 ms
 * in `read + unpack("C*") + a while loop`, more than the inference itself, and
 * the loop exists only because the only route into a Tensor was an Array of
 * Ruby Floats.  A `String` read straight off the file is already the bytes the
 * device wants, so for a :u8 or :i8 tensor there is nothing to convert -- this
 * is a memcpy, and the Ruby side does no per-element work at all.
 *
 * `src` is the Spinel String's contiguous bytes (:str is `const char *`); it is
 * only read and never retained (docs/FFI.md: call-duration lifetime). */
int sp_t_h2d_bytes(int64_t h, const char *src, size_t n) {
  g_err[0] = 0;
  sp_t_buf_t *b = deref(h);
  if (!b) return failf("sp_t_h2d_bytes: handle %lld is not live", (long long)h);
  if (!src) return failf("sp_t_h2d_bytes: null source");
  if (b->dt != SP_T_U8 && b->dt != SP_T_I8)
    return failf("sp_t_h2d_bytes: this tensor is :%s, and raw bytes are only the "
                 "representation of a :u8 or :i8 tensor (use #store for the rest)",
                 SP_T_DTNAME[b->dt]);
  if (n == 0) return 0;
  if (n > b->n) return failf("sp_t_h2d_bytes: %zu bytes into a [%zu] tensor", n, b->n);
  iree_hal_buffer_mapping_t m;
  void *d = map_write(b, n, &m);
  if (d) {
    memcpy(d, src, n);
    iree_hal_buffer_unmap_range(&m);
  } else {
    iree_status_t st = iree_hal_device_transfer_h2d(
        g_device, src, iree_hal_buffer_view_buffer(b->bv), 0, n,
        IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT, iree_infinite_timeout());
    if (!iree_status_is_ok(st)) return fail(st, "sp_t_h2d_bytes");
    g_err[0] = 0;
  }
  g_count[C_H2D]++;
  return 0;
}

/* device -> host.  The one synchronisation point in the surface (`.to_f32_a`).
 * Fast path: the buffer is mappable, so this is a memcpy on unified memory.
 * Otherwise d2d into the HOST_CACHED staging buffer allocated once -- which is
 * what iree_hal_device_transfer_d2h does per call, 56x slower (E030 s4.3). */
static iree_status_t read_raw(iree_hal_buffer_t *buf, void *dst, size_t nbytes) {
  iree_device_size_t bytes = (iree_device_size_t)nbytes;
  iree_status_t st = iree_hal_buffer_map_read(buf, 0, dst, bytes);
  if (iree_status_is_ok(st)) return st;
  iree_status_ignore(st);

  if (g_stage_n < nbytes) {
    iree_hal_buffer_release(g_stage);
    g_stage = NULL;
    g_stage_n = 0;
    iree_hal_buffer_params_t sp = {
        .type = IREE_HAL_MEMORY_TYPE_HOST_LOCAL |
                IREE_HAL_MEMORY_TYPE_DEVICE_VISIBLE |
                IREE_HAL_MEMORY_TYPE_HOST_CACHED, /* load-bearing: E030 s4.3 */
        .access = IREE_HAL_MEMORY_ACCESS_ALL,
        .usage = IREE_HAL_BUFFER_USAGE_TRANSFER | IREE_HAL_BUFFER_USAGE_MAPPING,
    };
    st = iree_hal_allocator_allocate_buffer(iree_hal_device_allocator(g_device),
                                            sp, bytes, &g_stage);
    if (!iree_status_is_ok(st)) return st;
    g_stage_n = nbytes;
  }
  st = iree_hal_device_transfer_d2d(g_device, buf, 0, g_stage, 0, bytes,
                                    IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT,
                                    iree_infinite_timeout());
  if (iree_status_is_ok(st))
    st = iree_hal_buffer_map_read(g_stage, 0, dst, bytes);
  return st;
}

int sp_t_d2h(int64_t h, const double *dst, size_t n) {
  g_err[0] = 0;
  sp_t_buf_t *b = deref(h);
  if (!b) return failf("sp_t_d2h: handle %lld is not live", (long long)h);
  if (n == 0) return 0;
  if (n > b->n) return failf("sp_t_d2h: %zu elements out of a [%zu] tensor", n, b->n);
  const size_t esz = (size_t)SP_T_DTSIZE[b->dt];
  float *s = stage_f32((n * esz + sizeof(float) - 1) / sizeof(float));
  if (!s) return failf("sp_t_d2h: staging alloc failed");
  iree_status_t st = read_raw(iree_hal_buffer_view_buffer(b->bv), s, n * esz);
  if (!iree_status_is_ok(st)) return fail(st, "sp_t_d2h");
  double *out = (double *)dst;  /* the caller's Array.data, written in place */
  load_elems(out, b->dt, s, n);
  g_count[C_D2H]++;
  return 0;
}

/* E072 s1 (P002 Phase 4): RAW BYTES straight OUT of a byte-typed tensor -- the
 * symmetric form of sp_t_h2d_bytes, and the thing E069 s7.3 measured the absence
 * of.
 *
 * At 4K the Metal pipeline computed its answer in 3.94 ms and then spent
 * 24.94 ms in `to_f_a`, which is a d2h of 8.3 MB followed by the construction of
 * an 8 294 400-element Ruby Array of Floats -- 66 MB of boxed f64 for a result
 * that is 8.3 MB of bytes and is about to be written to a file as bytes.  The
 * entry point below skips the Array entirely: the bytes are copied once into the
 * reused host staging buffer and handed to Spinel's `:binstr` FFI return mode,
 * which builds the String from the EXACT byte count published in sp_ffi_bin_len
 * (docs/FFI.md; `:str` would truncate at the first 0x00 pixel, and a black pixel
 * is 0x00).
 *
 * `sp_ffi_bin_len` lives in the Spinel runtime (lib/sp_alloc.c) and is declared
 * here rather than by including sp_alloc.h, because this file is compiled
 * against the IREE headers only and the ABI is one `int`.  vendor/spinel is
 * READ-ONLY: this is a consumer of a contract that has been in the fork since
 * matz/spinel#1466, not a change to it.
 *
 * The returned pointer is BORROWED -- it is the staging buffer, and the next
 * readback overwrites it.  That is safe because the `:binstr` lowering copies
 * into a GC String inside the same expression (codegen_call.c: the call is
 * sequenced into a temp and then `sp_str_from_bytes`), and it is why the Ruby
 * side may never hold the return value of the FFI call itself. */
extern int sp_ffi_bin_len;

const char *sp_t_d2h_bytes(int64_t h, size_t n) {
  g_err[0] = 0;
  sp_ffi_bin_len = 0;
  sp_t_buf_t *b = deref(h);
  if (!b) {
    failf("sp_t_d2h_bytes: handle %lld is not live", (long long)h);
    return "";
  }
  if (b->dt != SP_T_U8 && b->dt != SP_T_I8) {
    failf("sp_t_d2h_bytes: this tensor is :%s, and raw bytes are only the "
          "representation of a :u8 or :i8 tensor (use #to_f_a for the rest)",
          SP_T_DTNAME[b->dt]);
    return "";
  }
  if (n == 0) return "";
  if (n > b->n) {
    failf("sp_t_d2h_bytes: %zu bytes out of a [%zu] tensor", n, b->n);
    return "";
  }
  /* sp_ffi_bin_len is an int; a String longer than INT_MAX would be built with
     a truncated (or negative) length, which is a silently wrong answer -- the
     one thing this surface never does (E018/E012). */
  if (n > (size_t)2147483647) {
    failf("sp_t_d2h_bytes: %zu bytes does not fit the :binstr length contract "
          "(sp_ffi_bin_len is an int). Read the tensor in pieces", n);
    return "";
  }
  float *s = stage_f32((n + sizeof(float) - 1) / sizeof(float));
  if (!s) {
    failf("sp_t_d2h_bytes: staging alloc failed");
    return "";
  }
  iree_status_t st = read_raw(iree_hal_buffer_view_buffer(b->bv), s, n);
  if (!iree_status_is_ok(st)) {
    fail(st, "sp_t_d2h_bytes");
    return "";
  }
  g_count[C_D2H]++;
  sp_ffi_bin_len = (int)n;
  return (const char *)s;
}

/* FNV-1a over the raw f64 bytes of a Spinel Array.  f32 -> f64 is exact, so
 * this is a bitwise witness for what the device produced, which is how E030
 * cross-checked the CPU .vmfb against the Metal .vmfb from Ruby and how E031
 * gate (b) does it.  Validation scaffolding, not part of the surface -- a test
 * program declares it itself. */
int64_t sp_t_hash64(const double *v, size_t n) {
  const unsigned char *p = (const unsigned char *)v;
  uint64_t h = 1469598103934665603ull;
  for (size_t i = 0; i < n * sizeof(double); i++) {
    h ^= p[i];
    h *= 1099511628211ull;
  }
  return (int64_t)(h & 0x7fffffffffffffffull);
}

/* ---------------------------------------------------------------- dispatch */

/* One shape constraint: "a:d=b:e" (dim d of tensor a equals dim e of tensor b),
 * "a:d/B=b:e" (ceil(dim d of a / B) equals dim e of b, which is what one level
 * of the fixed-arity reduction tree contracts by), or -- E034 -- "a:d=#K" (dim
 * d of a equals the literal K, which is how a FIXED dimension of a foreign
 * module's signature is checked; a generated kernel never has one, because its
 * shapes are all dynamic).  The generator derives these from the kernel body
 * (or, for tensor_extern, from the declared `shapes:`), so a shape mismatch is
 * named in terms of the declaration instead of surfacing as an IREE buffer-size
 * error (or, worse, not surfacing at all). */
static int check_shapes(const sp_t_entry_t *e, sp_t_buf_t **bufs) {
  const char *p = e->shape;
  while (p && *p) {
    int a = 0, ad = 0, b = 0, bd = 0, blk = 0;
    long lit = -1;
    char sep = 0;
    /* a:d[/B]=b:e  |  a:d=#K  |  a!b */
    a = (int)strtol(p, (char **)&p, 10);
    /* E042 (P002 Phase 2): `a!b` says tensor arguments a and b must be DIFFERENT
     * buffers.  It is emitted only for an entry that contains a window op, and it
     * is the run-time half of a rejection whose static half lives in the
     * generator.  The static half refuses `dst.assign(dst.conv2d(:k))`; this half
     * refuses `blur(img, img)`, where the same unsafety arrives through the
     * handle rather than the name.
     *
     * The reason is E038 s4's aliasing argument, negated.  An all-parallel
     * linalg.generic whose operands all have identity maps reads input element i
     * to write output element i, so aliasing the destination into the expression
     * is safe under ANY tiling.  A convolution's input map is (d0 + d2, d1 + d3)
     * and two of its iterators are reductions, so output pixel i reads input
     * pixels i-1, i, i+1 -- and whether those are the old values or ones this
     * same dispatch has already overwritten is the tiling order's business.
     *
     * It lives in the shape-constraint string rather than in a new table column
     * on purpose: the constraint string is already inside the signature hash, so
     * the alias contract is covered by the E033 s4 cross-check for free, and
     * every table row E031..E039 recorded is unchanged. */
    if (*p == '!') {
      b = (int)strtol(p + 1, (char **)&p, 10);
      sep = *p;
      if (sep == ';') p++;
      if (a >= e->ntensor || b >= e->ntensor)
        return failf("%s: shape constraint out of range", e->name);
      if (bufs[a] == bufs[b])
        return failf("%s: tensor arguments %d and %d are the SAME Tensor, and this "
                     "entry contains a window op (a convolution) or a resample, whose "
                     "output pixel reads a NEIGHBOURHOOD of the input. Writing into a "
                     "tensor such an op also reads is safe only if every operand is "
                     "read at the index being written -- which is what makes the "
                     "element-wise case safe -- so the answer here would depend on the "
                     "order the backend happens to tile in. Pass a different "
                     "destination",
                     e->name, a, b);
      continue;
    }
    if (*p != ':') return failf("%s: malformed shape constraint '%s'", e->name, e->shape);
    ad = (int)strtol(p + 1, (char **)&p, 10);
    if (*p == '/') {
      blk = (int)strtol(p + 1, (char **)&p, 10);
    }
    if (*p != '=') return failf("%s: malformed shape constraint '%s'", e->name, e->shape);
    if (p[1] == '#') {
      lit = strtol(p + 2, (char **)&p, 10);
    } else {
      b = (int)strtol(p + 1, (char **)&p, 10);
      if (*p != ':') return failf("%s: malformed shape constraint '%s'", e->name, e->shape);
      bd = (int)strtol(p + 1, (char **)&p, 10);
    }
    sep = *p;
    if (sep == ';') p++;

    if (a >= e->ntensor || (lit < 0 && b >= e->ntensor))
      return failf("%s: shape constraint out of range", e->name);
    /* E039 (R005 s2.3): the DIMENSION subscripts were never checked.  Only `a`
     * and `b` were, so `0:2=1:2` -- which the generator could not emit while
     * mlir_ty was capped at rank 2, but ExternDecl.constraints has always been
     * rank-generic -- read `d[2]` out of a struct whose d[] was `size_t d[2]`,
     * i.e. the `int rank; int dt;` pair reinterpreted as a size_t.  This is the
     * first commit of the rank extension for that reason: without it, widening
     * mlir_ty turns a latent out-of-bounds read into a reachable one.
     *
     * Checked against the TENSOR'S OWN rank, not SP_T_MAX_RANK: a constraint
     * naming dim 2 of a rank-2 argument is a declaration/argument disagreement
     * even though d[2] is now in bounds, and it is exactly the disagreement the
     * `ranks` check above would have caught if the constraint language could
     * see it. */
    if (ad < 0 || ad >= bufs[a]->rank)
      return failf("%s: shape constraint '%s' names dim %d of tensor argument %d, which "
                   "is rank %d (dimensions are 0..%d)",
                   e->name, e->shape, ad, a, bufs[a]->rank, bufs[a]->rank - 1);
    if (lit < 0 && (bd < 0 || bd >= bufs[b]->rank))
      return failf("%s: shape constraint '%s' names dim %d of tensor argument %d, which "
                   "is rank %d (dimensions are 0..%d)",
                   e->name, e->shape, bd, b, bufs[b]->rank, bufs[b]->rank - 1);
    size_t va = bufs[a]->d[ad];
    if (blk > 0) va = (va + (size_t)blk - 1) / (size_t)blk;
    if (lit >= 0) {
      if (va != (size_t)lit)
        return failf("%s: shape mismatch -- dim %d of tensor argument %d is %zu but the "
                     "declared signature of this entry fixes it at %ld",
                     e->name, ad, a, va, lit);
      continue;
    }
    size_t vb = bufs[b]->d[bd];
    if (va != vb) {
      if (blk > 0)
        return failf("%s: shape mismatch -- ceil(dim %d of tensor argument %d / %d) = %zu "
                     "but dim %d of tensor argument %d is %zu",
                     e->name, ad, a, blk, va, bd, b, vb);
      return failf("%s: shape mismatch -- dim %d of tensor argument %d is %zu but dim %d "
                   "of tensor argument %d is %zu (the declaration requires them equal)",
                   e->name, ad, a, bufs[a]->d[ad], bd, b, vb);
    }
  }
  return 0;
}

/* Shared body of sp_t_invoke / sp_t_invoke_f / sp_t_invoke_fx.
 *
 * E038: `sv` is nscalar captured f32 values, not one.  Through E037 every entry
 * had at most one scalar (a tensor_def's single :scalar parameter, MAX_SCALARS
 * in spinel-mlirgen), so the old signature carried exactly one double and this
 * loop pushed it nscalar times -- indistinguishable while nscalar <= 1.  A
 * FUSED call-site expression can capture several Ruby numbers (`x * a + y * b`),
 * so the array is the general form; sp_t_invoke passes {s0,0,0,0} and every
 * E031..E037 row behaves exactly as before. */
static int invoke(const char *name, int64_t sig, const double *sv, int64_t h0, int64_t h1,
                  int64_t h2, int64_t h3, size_t n, double *out_scalar) {
  g_err[0] = 0;
  if (!g_session)
    return failf("%s: no device scope is open (wrap the work in Tensor.device)", name);
  const sp_t_entry_t *e = lookup(name);
  if (!e) return failf("no kernel '%s' in this build. The .vmfb is generated at "
                       "COMPILE time from the tensor_def declarations; a name that "
                       "is not in the table cannot appear later", name);
  /* E033 s4: the ABI cross-check.  The generated dispatch presents the hash of
   * the declaration it was generated from; the table carries the hash of the
   * declaration the .vmfb was built from.  They can only differ if the two were
   * generated from different sources, which is exactly the failure E031's
   * honest boundary said nothing catches. */
  if (sig != 0 && sig != e->sig)
    return failf("%s: signature mismatch -- the calling dispatch was generated from a "
                 "declaration whose signature hash is %lld, but this build's entry table "
                 "says %lld. The .gen.rb and the .vmfb/table come from the same "
                 "spinel-mlirgen run; regenerate both", name, (long long)sig,
                 (long long)e->sig);
  if (n == 0) {
    if (out_scalar) *out_scalar = 0.0;
    return 0;
  }

  const int64_t hs[4] = {h0, h1, h2, h3};
  sp_t_buf_t *bufs[4] = {NULL, NULL, NULL, NULL};
  for (int i = 0; i < e->ntensor; i++) {
    bufs[i] = deref(hs[i]);
    if (!bufs[i])
      return failf("%s: tensor argument %d is not a live Tensor", name, i);
    int want = e->ranks[i] - '0';
    if (bufs[i]->rank != want) {
      /* E039: the rank-1/2 wording is VERBATIM E033's -- it is what
       * results/E033/reject_runtime.tsv rt02 and results/E038 rt02 record, and
       * a reworded message is a gate diff for no gain.  Rank 3/4 gets its own
       * sentence rather than a rewrite of that one. */
      if (want >= 3 || bufs[i]->rank >= 3)
        return failf("%s: tensor argument %d is rank %d but the declaration says rank %d "
                     "(a :ten3 is Tensor.ten3(:u8, h, w, c); a :ten4 is Tensor.ten4)",
                     name, i, bufs[i]->rank, want);
      return failf("%s: tensor argument %d is rank %d but the declaration says rank %d "
                   "(a :mat is Tensor.mat(:f32, rows, cols); a :vec is Tensor.vec)",
                   name, i, bufs[i]->rank, want);
    }
    /* E037 s6: the dtype half of the same check.  The table's `dtypes` column is
     * what --extern-check verified against the module's own func.func, so a
     * mismatch here means the Tensor is the wrong element type for an entry
     * whose type WAS checked -- which IREE would otherwise report as an opaque
     * buffer-view type error deep inside the invoke, if at all. */
    int wantdt = e->dtypes[i] - '0';
    if (bufs[i]->dt != wantdt)
      return failf("%s: tensor argument %d is :%s but the declared signature of this "
                   "entry says :%s",
                   name, i, SP_T_DTNAME[bufs[i]->dt],
                   (wantdt >= 0 && wantdt < SP_T_NDTYPE) ? SP_T_DTNAME[wantdt] : "?");
  }
  if (check_shapes(e, bufs) != 0) return -1;

  /* ======================================================================
   * E072 s5: THE METAL BYTE-TAIL GUARD.  This is not a shape check -- it is a
   * refusal to run a configuration in which the METAL BACKEND SILENTLY WRITES
   * A SHORT ANSWER.
   *
   * Measured (results/E072/metalbug.tsv): when a dispatch's destination is a
   * :u8 or :i8 tensor whose ELEMENT COUNT is not a multiple of 4, the
   * metal-spirv backend writes only part of it and reports success.  The
   * written prefix is 32*ceil(n/128) elements for E042's `blur3_u8` at
   * n = 65..3723; other kernels truncate at other residues.  An f32 destination
   * of the same shape is correct, and llvm-cpu is correct at every size.
   *
   * IT IS NOT E072's OPS.  The minimal reproducer is E042's own `conv2d`
   * declaration, unchanged, at 61x61 -- and E042/E069 never saw it because
   * every resolution they used (64^2, 256^2, 512^2, 3840x2160) has an element
   * count divisible by 4.  A resample is the first thing in this project that
   * naturally produces an arbitrary output size, which is why Phase 4 is where
   * it surfaced.
   *
   * A silently short image is the exact failure mode E018/E012 forbid, so the
   * shim refuses rather than letting it through.  `SPINEL_TENSOR_ALLOW_METAL_U8_TAIL=1`
   * lifts the refusal, and exists so that E072's own census gate can MEASURE
   * the defect instead of only asserting it.
   * ================================================================== */
  if (g_is_metal && e->dest >= 0) {
    sp_t_buf_t *db = bufs[e->dest];
    if (db && (db->dt == SP_T_U8 || db->dt == SP_T_I8) && (db->n % 4) != 0) {
      static int allow = -1;
      if (allow < 0) {
        const char *v = getenv("SPINEL_TENSOR_ALLOW_METAL_U8_TAIL");
        allow = (v && v[0] && v[0] != '0') ? 1 : 0;
      }
      if (!allow) {
        iree_runtime_call_t dummy;
        (void)dummy;
        return failf(
            "%s: the destination is a :%s tensor of %zu elements and %zu is not a "
            "multiple of 4. On the metal-spirv backend of this IREE build "
            "(e4a3b040 / compiler 3.11.0) a byte destination whose element count "
            "is not a multiple of 4 is written SHORT and the invoke still "
            "succeeds -- a silently wrong image (E072 s5 measured it on E042's "
            "own conv2d declaration at 61x61: 960 of 3721 pixels written). An f32 "
            "destination of the same shape is correct, and every CPU backend is "
            "correct at every size. Pad the destination to a multiple of 4 "
            "elements, keep the result in f32 and quantise on the host, or run "
            "this kernel on a CPU device. Set "
            "SPINEL_TENSOR_ALLOW_METAL_U8_TAIL=1 to run it anyway (E072's census "
            "gate does, in order to measure the defect)",
            name, SP_T_DTNAME[db->dt], db->n, db->n);
      }
    }
  }

  /* E034: the fully-qualified VM name is a TABLE FIELD, not "module." + name.
   * A module spinel-mlirgen generated is always `module.<name>`, but a foreign
   * .vmfb brings its own namespace (jax.export names the VM module after the
   * jitted function, e.g. `jit_infer.main`), and the Ruby-visible kernel name
   * is ours to choose independently of it. */
  iree_runtime_call_t call;
  iree_status_t st =
      iree_runtime_call_initialize_by_name(g_session, iree_make_cstring_view(e->fq), &call);
  if (!iree_status_is_ok(st)) return fail(st, "call_initialize");

  /* Scalars first (they are the leading arguments of every generated
     func.func), then the buffer views, in declaration order. */
  if (e->nscalar > SP_T_MAX_SCALARS) {
    iree_runtime_call_deinitialize(&call);
    return failf("%s: the entry table says %d scalars but the dispatch carries at most %d",
                 name, e->nscalar, SP_T_MAX_SCALARS);
  }
  for (int i = 0; i < e->nscalar && iree_status_is_ok(st); i++) {
    iree_vm_value_t v = iree_vm_value_make_f32((float)sv[i]);
    st = iree_vm_list_push_value(iree_runtime_call_inputs(&call), &v);
  }
  /* E034: only the first `nin` tensors are arguments.  A generated kernel is
   * destination-passing (nin == ntensor); a foreign export usually returns its
   * result instead (`main(x) -> y`), so the last Ruby-visible tensor is not an
   * argument at all -- it is where the returned buffer view is adopted. */
  for (int i = 0; i < e->nin && iree_status_is_ok(st); i++)
    st = iree_runtime_call_inputs_push_back_buffer_view(&call, bufs[i]->bv);

  if (iree_status_is_ok(st)) st = iree_runtime_call_invoke(&call, 0);

  if (iree_status_is_ok(st)) {
    if (e->ret_scalar) {
      iree_vm_value_t v;
      st = iree_vm_list_get_value(iree_runtime_call_outputs(&call), 0, &v);
      if (iree_status_is_ok(st) && out_scalar)
        *out_scalar = (double)iree_vm_value_get_f32(&v);
    } else {
      /* IREE does not tie operands, so the result comes back as a NEW buffer
       * view even though the kernel is destination-passing (E030 s4.3-1).
       * Rather than copy it back into the destination, adopt it: the handle
       * now names the result.  Zero transfers, zero device copies, and the
       * Ruby-visible identity of the Tensor is unchanged. */
      iree_hal_buffer_view_t *br = NULL;
      st = iree_runtime_call_outputs_pop_front_buffer_view(&call, &br);
      if (iree_status_is_ok(st) && e->dest >= 0) {
        /* E037 s6: the module's ACTUAL result type, not the declared one.  This
         * is the last place a lie about a foreign signature can be caught, and
         * the only one that does not depend on reading the .mlir. */
        int wantdt = e->dtypes[e->dest] - '0';
        iree_hal_element_type_t got = iree_hal_buffer_view_element_type(br);
        if (got != sp_t_eltype(wantdt)) {
          iree_hal_buffer_view_release(br);
          iree_runtime_call_deinitialize(&call);
          return failf("%s: the entry returned element type 0x%08x but the declaration "
                       "says :%s -- the module and the tensor_extern disagree "
                       "(rerun spinel-mlirgen --extern-check)",
                       name, (unsigned)got,
                       (wantdt >= 0 && wantdt < SP_T_NDTYPE) ? SP_T_DTNAME[wantdt] : "?");
        }
        iree_hal_buffer_view_release(bufs[e->dest]->bv);
        bufs[e->dest]->bv = br;
      } else {
        iree_hal_buffer_view_release(br);
      }
    }
  }
  iree_runtime_call_deinitialize(&call);
  if (!iree_status_is_ok(st)) return fail(st, name);
  g_count[C_INVOKE]++;
  return 0;
}

int sp_t_invoke(const char *name, int64_t sig, double s0, int64_t h0, int64_t h1,
                int64_t h2, int64_t h3, size_t n) {
  const double sv[SP_T_MAX_SCALARS] = {s0, 0.0, 0.0, 0.0};
  return invoke(name, sig, sv, h0, h1, h2, h3, n, NULL);
}

double sp_t_invoke_f(const char *name, int64_t sig, double s0, int64_t h0, int64_t h1,
                     int64_t h2, int64_t h3, size_t n) {
  const double sv[SP_T_MAX_SCALARS] = {s0, 0.0, 0.0, 0.0};
  double r = 0.0;
  if (invoke(name, sig, sv, h0, h1, h2, h3, n, &r) != 0) return (double)NAN; /* loud */
  return r;
}

/* E038: the dispatch for a FUSED call-site expression (R004 design B).
 *
 * Identical to sp_t_invoke in every respect except the number of captured
 * scalars it can carry.  It is a SEPARATE entry point rather than a widening of
 * sp_t_invoke because the generated dispatches E033/E034/E037 recorded call
 * sp_t_invoke by name with eight arguments, and their signature hashes are the
 * ABI those measurements were taken against.
 *
 * The scalars are the Ruby numbers the expression mentioned -- literals AND
 * variables alike -- passed at RUN TIME.  Folding a literal into the .vmfb
 * instead would make `y.assign!(x * 2.5 + y)` and `y.assign!(x * a + y)` two
 * different kernels and would break outright the moment the number is not a
 * literal, which for an AOT binary is not a corner case but the normal one. */
int sp_t_invoke_fx(const char *name, int64_t sig, double s0, double s1, double s2,
                   double s3, int64_t h0, int64_t h1, int64_t h2, int64_t h3,
                   size_t n) {
  const double sv[SP_T_MAX_SCALARS] = {s0, s1, s2, s3};
  return invoke(name, sig, sv, h0, h1, h2, h3, n, NULL);
}
