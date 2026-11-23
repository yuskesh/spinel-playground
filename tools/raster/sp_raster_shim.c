/* sp_raster_shim.c -- E061 (P005 Phase 3): the seam under the Job IR GPU path.
 *
 * WHY THIS IS NOT sp_tensor_shim.c.  The tensor shim (tools/tensor, E030..E042)
 * is the right shape for the tensor surface and the wrong shape for raster:
 *
 *   - its element路 is f64 in Ruby -> f32/u8 on the device; every value crosses
 *     as a double and is rounded once.  A raster job is i32 and a framebuffer is
 *     u8 INDICES into a palette -- there is no rounding, and going through
 *     doubles would be both slower and a lie about the contract.
 *   - its entry table is sp_tensor_table.h (generated from tensor_def);
 *     ours is sp_job_table.h (generated from the Job IR declaration).  Two
 *     different contracts should not share one lookup.
 *   - E060 is running against the tensor shim's gates (E033/E034/E037/E038/
 *     E039/E042) in the same tree.  ADDITIVE changes there would still force a
 *     re-run of six gate suites to prove non-regression, and would put two
 *     experiments on one file.  A separate TU costs ~300 lines and zero risk.
 *
 * What is carried over VERBATIM from E030/E037, because it is ABI and was paid
 * for in measurements:
 *
 *   - IREE_HAL_MEMORY_TYPE_HOST_CACHED on every buffer the host reads.  Without
 *     it IREE's Metal allocator picks MTLResourceCPUCacheModeWriteCombined and
 *     the readback is 6-56x slower, silently, with the same answer (E036 s6).
 *   - the readback staging buffer is allocated ONCE and reused (E030 s4.3).
 *   - residency is the normal case: the atlas (1.3 MB) and the colormap go up
 *     once, outside the frame loop; only the job slots move per frame.
 *
 * NOT thread safe: all state is process-global static, as in E030/E031.
 */

#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "iree/runtime/api.h"
#include "sp_job_table.h"

/* ------------------------------------------------------------------ state */

static iree_runtime_instance_t *g_instance = NULL;
static iree_hal_device_t       *g_device   = NULL;
static iree_runtime_session_t  *g_session  = NULL;
static char g_err[768] = {0};

enum { C_H2D = 0, C_D2H = 1, C_INVOKE = 2, C_ALLOC = 3, C_FREE = 4,
       C_NCOUNTER = 5 };
static int64_t g_count[C_NCOUNTER];

/* Element types.  A raster buffer is either bytes (framebuffer, atlas,
 * colormap) or i32 (job slots).  There is nothing else, on purpose. */
enum { SP_R_I8 = 0, SP_R_I32 = 1, SP_R_NDTYPE = 2 };
static const int SP_R_DTSIZE[SP_R_NDTYPE] = {1, 4};
static const char *const SP_R_DTNAME[SP_R_NDTYPE] = {"i8", "i32"};

typedef struct {
  iree_hal_buffer_view_t *bv;
  size_t n;          /* elements */
  size_t d0, d1;     /* rank-1: d0 == n, d1 == 0 */
  int rank;
  int dt;
  int live;
} sp_r_buf_t;

/* E071: the full-screen frame is up to 4 + 7 = 11 dispatches (opaque, plane, and
 * the masked batch list), each with its own framebuffer handle, on top of five
 * resident resources and four slot buffers.  16 was E061's number for a
 * two-dispatch frame. */
#define SP_R_MAX_BUFS 40
static sp_r_buf_t g_bufs[SP_R_MAX_BUFS];

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

static sp_r_buf_t *deref(int64_t h) {
  if (h <= 0 || h > SP_R_MAX_BUFS) return NULL;
  sp_r_buf_t *b = &g_bufs[h - 1];
  return b->live ? b : NULL;
}

const char *sp_r_last_error(void) { return g_err; }

int64_t sp_r_counter(int i) {
  return (i >= 0 && i < C_NCOUNTER) ? g_count[i] : -1;
}

void sp_r_counters_reset(void) { memset(g_count, 0, sizeof g_count); }

/* -------------------------------------------------------------- lifecycle */

int sp_r_open(const char *vmfb_path, const char *device_uri) {
  g_err[0] = 0;
  if (g_session) return failf("sp_r_open: a device scope is already open");
  if (!vmfb_path || !vmfb_path[0]) return failf("sp_r_open: no .vmfb path");
  memset(g_count, 0, sizeof g_count);

  iree_runtime_instance_options_t opts;
  iree_runtime_instance_options_initialize(&opts);
  iree_runtime_instance_options_use_all_available_drivers(&opts);
  iree_status_t st =
      iree_runtime_instance_create(&opts, iree_allocator_system(), &g_instance);
  if (!iree_status_is_ok(st)) return fail(st, "instance_create");

  st = iree_runtime_instance_try_create_default_device(
      g_instance, iree_make_cstring_view(device_uri), &g_device);
  if (!iree_status_is_ok(st)) {
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

  /* The module must exist at COMPILE time -- an AOT binary carries no runtime
   * compiler (E030).  A CPU .vmfb handed to a metal device is caught here,
   * loudly, at load time (E030 s5: INCOMPATIBLE). */
  st = iree_runtime_session_append_bytecode_module_from_file(g_session, vmfb_path);
  if (!iree_status_is_ok(st)) return fail(st, "load_module");
  return 0;
}

void sp_r_close(void) {
  for (int i = 0; i < SP_R_MAX_BUFS; i++) {
    if (g_bufs[i].live) {
      iree_hal_buffer_view_release(g_bufs[i].bv);
      g_bufs[i].live = 0;
    }
  }
  iree_hal_buffer_release(g_stage);
  g_stage = NULL;
  g_stage_n = 0;
  iree_runtime_session_release(g_session);
  g_session = NULL;
  iree_hal_device_release(g_device);
  g_device = NULL;
  iree_runtime_instance_release(g_instance);
  g_instance = NULL;
}

/* ------------------------------------------------------ resident buffers */

int64_t sp_r_alloc(int64_t d0, int64_t d1, int rank, int dt) {
  g_err[0] = 0;
  if (!g_session) { failf("sp_r_alloc: no device scope is open"); return 0; }
  if (dt < 0 || dt >= SP_R_NDTYPE) {
    failf("sp_r_alloc: dtype %d is not i8/i32", dt);
    return 0;
  }
  if (rank < 1 || rank > 2) { failf("sp_r_alloc: rank %d not in 1..2", rank); return 0; }
  size_t n = rank == 1 ? (size_t)d0 : (size_t)d0 * (size_t)d1;
  if (n == 0) { failf("sp_r_alloc: zero-length allocation"); return 0; }

  iree_hal_buffer_params_t p = {
      .type = IREE_HAL_MEMORY_TYPE_DEVICE_LOCAL | IREE_HAL_MEMORY_TYPE_HOST_VISIBLE |
              IREE_HAL_MEMORY_TYPE_HOST_CACHED,   /* load-bearing: E036 s6 */
      .access = IREE_HAL_MEMORY_ACCESS_ALL,
      .usage = IREE_HAL_BUFFER_USAGE_DEFAULT | IREE_HAL_BUFFER_USAGE_MAPPING,
  };
  iree_hal_dim_t shape[2];
  int nd = rank;
  if (rank == 1) shape[0] = (iree_hal_dim_t)n;
  else { shape[0] = (iree_hal_dim_t)d0; shape[1] = (iree_hal_dim_t)d1; }

  iree_hal_buffer_t *b = NULL;
  iree_hal_allocator_t *dalloc = iree_runtime_session_device_allocator(g_session);
  const size_t bytes = n * (size_t)SP_R_DTSIZE[dt];
  iree_status_t st = iree_hal_allocator_allocate_buffer(dalloc, p, bytes, &b);
  if (!iree_status_is_ok(st)) {
    iree_status_ignore(st);
    p.type &= ~(iree_hal_memory_type_t)IREE_HAL_MEMORY_TYPE_HOST_CACHED;
    st = iree_hal_allocator_allocate_buffer(dalloc, p, bytes, &b);
  }
  iree_hal_buffer_view_t *bv = NULL;
  if (iree_status_is_ok(st))
    st = iree_hal_buffer_view_create(
        b, (iree_host_size_t)nd, shape,
        dt == SP_R_I8 ? IREE_HAL_ELEMENT_TYPE_SINT_8 : IREE_HAL_ELEMENT_TYPE_SINT_32,
        IREE_HAL_ENCODING_TYPE_DENSE_ROW_MAJOR,
        iree_runtime_session_host_allocator(g_session), &bv);
  iree_hal_buffer_release(b);
  if (!iree_status_is_ok(st)) { fail(st, "sp_r_alloc"); return 0; }

  int slot = -1;
  for (int i = 0; i < SP_R_MAX_BUFS; i++) if (!g_bufs[i].live) { slot = i; break; }
  if (slot < 0) {
    iree_hal_buffer_view_release(bv);
    failf("sp_r_alloc: more than %d live buffers", SP_R_MAX_BUFS);
    return 0;
  }
  g_bufs[slot].bv = bv;
  g_bufs[slot].n = n;
  g_bufs[slot].d0 = rank == 1 ? n : (size_t)d0;
  g_bufs[slot].d1 = rank == 1 ? 0 : (size_t)d1;
  g_bufs[slot].rank = rank;
  g_bufs[slot].dt = dt;
  g_bufs[slot].live = 1;
  g_count[C_ALLOC]++;
  return (int64_t)(slot + 1);
}

void sp_r_free(int64_t h) {
  sp_r_buf_t *b = deref(h);
  if (!b) return;
  iree_hal_buffer_view_release(b->bv);
  b->bv = NULL;
  b->live = 0;
  g_count[C_FREE]++;
}

/* Raw bytes in.  This is a memcpy on unified memory -- the Job IR is already
 * POD in the layout the device wants (E057's `Jobs#pack`), so there is nothing
 * to convert.  That is the whole point of the two-layer ABI. */
int sp_r_h2d(int64_t h, const void *src, size_t nbytes) {
  g_err[0] = 0;
  sp_r_buf_t *b = deref(h);
  if (!b) return failf("sp_r_h2d: handle %lld is not live", (long long)h);
  size_t cap = b->n * (size_t)SP_R_DTSIZE[b->dt];
  if (nbytes > cap)
    return failf("sp_r_h2d: %zu bytes into a %zu-byte buffer", nbytes, cap);
  iree_hal_buffer_mapping_t m;
  iree_status_t st = iree_hal_buffer_map_range(
      iree_hal_buffer_view_buffer(b->bv), IREE_HAL_MAPPING_MODE_SCOPED,
      IREE_HAL_MEMORY_ACCESS_WRITE, 0, nbytes, &m);
  if (iree_status_is_ok(st)) {
    memcpy((void *)m.contents.data, src, nbytes);
    iree_hal_buffer_unmap_range(&m);
  } else {
    iree_status_ignore(st);
    st = iree_hal_device_transfer_h2d(
        g_device, src, iree_hal_buffer_view_buffer(b->bv), 0, nbytes,
        IREE_HAL_TRANSFER_BUFFER_FLAG_DEFAULT, iree_infinite_timeout());
    if (!iree_status_is_ok(st)) return fail(st, "sp_r_h2d");
  }
  g_count[C_H2D]++;
  return 0;
}

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
                IREE_HAL_MEMORY_TYPE_HOST_CACHED,  /* load-bearing: E030 s4.3 */
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

int sp_r_d2h(int64_t h, void *dst, size_t nbytes) {
  g_err[0] = 0;
  sp_r_buf_t *b = deref(h);
  if (!b) return failf("sp_r_d2h: handle %lld is not live", (long long)h);
  size_t cap = b->n * (size_t)SP_R_DTSIZE[b->dt];
  if (nbytes > cap)
    return failf("sp_r_d2h: %zu bytes out of a %zu-byte buffer", nbytes, cap);
  iree_status_t st = read_raw(iree_hal_buffer_view_buffer(b->bv), dst, nbytes);
  if (!iree_status_is_ok(st)) return fail(st, "sp_r_d2h");
  g_count[C_D2H]++;
  return 0;
}

/* ---------------------------------------------------------------- dispatch */

static const sp_job_entry_t *lookup(const char *kind) {
  for (int i = 0; i < SP_JOB_TABLE_N; i++)
    if (strcmp(SP_JOB_TABLE[i].name, kind) == 0) return &SP_JOB_TABLE[i];
  return NULL;
}

/* The dispatch is where the TABLE becomes load-bearing (checker #7/#8).
 *
 * `entry` is the name the generator put in the .vmfb; it is
 * `wall_gather_<ksig>` where ksig is the FNV-1a of the kernel declaration,
 * which folds in the table's semsig, the form, K, the resolution and centery.
 * This function recomputes nothing -- it is given the ksig the CALLER derived
 * from the table + parameters and refuses if the name does not carry it.  A
 * kernel compiled from a different declaration therefore cannot be dispatched
 * by accident: the name lookup inside IREE fails, loudly, before any pixel
 * moves (E033 s4's signature check, done with the name space instead of a
 * side channel).
 */
/* E070: the entry-name prefix is the head of the table row's name --
 * "wall_columns" -> "wall", "plane_spans_k16" -> "plane".  Deriving it costs
 * nothing and, crucially, does NOT add a column to the table: a new column
 * would change wall_columns' declaration row, move its `sig`, and break the
 * continuity with E061's .vmfb and sp_job_table.h.  tools/raster/spinel-jobtable
 * `entry_prefix()` computes the same thing on the Python side. */
static void entry_prefix(const sp_job_entry_t *e, char *out, size_t n) {
  size_t i = 0;
  for (; e->name[i] && e->name[i] != '_' && i + 1 < n; i++) out[i] = e->name[i];
  out[i] = 0;
}

/* The general gather dispatch (E070).
 *
 * `slotdim` is the axis the planar-SoA slots are cut by: W for wall columns
 * (K slots per screen column) and H for plane spans (K slots per scanline).
 * That single number is the whole difference between the two kernels at this
 * seam -- everything else (four operands, one result, the ksig-in-the-name
 * contract) is shared. */
int sp_r_dispatch_gather(const char *kind, uint64_t ksig, const char *entry,
                         int64_t hjobs, int64_t hres, int64_t hcmap, int64_t hbg,
                         int64_t hout, int W, int H, int K, int slotdim) {
  g_err[0] = 0;
  if (!g_session) return failf("sp_r_dispatch: no device scope is open");
  const sp_job_entry_t *e = lookup(kind);
  if (!e)
    return failf("sp_r_dispatch: no job kind '%s' in sp_job_table.h. The table is "
                 "generated from the Job IR declaration at BUILD time; a kind that "
                 "is not in it cannot appear later", kind);
  if (strcmp(e->form, "gather") != 0)
    return failf("sp_r_dispatch: job kind '%s' has form '%s'; this dispatch only "
                 "implements the gather form (P005 Phase 3/4 = wall columns and "
                 "plane spans)", kind, e->form);
  if (e->k_max != K)
    return failf("check #8: the table says k_max=%d for '%s' but the kernel was "
                 "generated with K=%d -- table and kernel disagree",
                 e->k_max, kind, K);
  char pfx[32], want[128];
  entry_prefix(e, pfx, sizeof pfx);
  snprintf(want, sizeof want, "%s_gather_%016llx", pfx, (unsigned long long)ksig);
  if (strcmp(want, entry) != 0)
    return failf("check #8: the entry name is '%s' but the table + parameters say "
                 "'%s'. The .vmfb and sp_job_table.h come from the same "
                 "spinel-rastergen run; regenerate both", entry, want);

  sp_r_buf_t *bj = deref(hjobs), *bt = deref(hres), *bc = deref(hcmap),
             *bb = deref(hbg), *bo = deref(hout);
  if (!bj || !bt || !bc || !bb || !bo)
    return failf("sp_r_dispatch: one of the five buffers is not live");
  if (bj->dt != SP_R_I32)
    return failf("sp_r_dispatch: the job buffer is :%s but the slots are i32",
                 SP_R_DTNAME[bj->dt]);
  if (slotdim != W && slotdim != H)
    return failf("sp_r_dispatch: slotdim=%d is neither W=%d nor H=%d; the gather "
                 "slots are cut by one of the two screen axes", slotdim, W, H);
  if (bj->n != (size_t)slotdim * (size_t)K * 6)
    return failf("sp_r_dispatch: the job buffer holds %zu i32 but planar SoA for "
                 "slotdim=%d K=%d needs %d (6 planes)", bj->n, slotdim, K,
                 slotdim * K * 6);
  if (bb->rank != 2 || bb->d0 != (size_t)H || bb->d1 != (size_t)W)
    return failf("sp_r_dispatch: the background is %dx%d but the view is %dx%d",
                 (int)bb->d0, (int)bb->d1, H, W);

  char fq[160];
  snprintf(fq, sizeof fq, "module.%s", entry);
  iree_runtime_call_t call;
  iree_status_t st =
      iree_runtime_call_initialize_by_name(g_session, iree_make_cstring_view(fq), &call);
  if (!iree_status_is_ok(st)) return fail(st, "call_initialize");

  st = iree_runtime_call_inputs_push_back_buffer_view(&call, bj->bv);
  if (iree_status_is_ok(st))
    st = iree_runtime_call_inputs_push_back_buffer_view(&call, bt->bv);
  if (iree_status_is_ok(st))
    st = iree_runtime_call_inputs_push_back_buffer_view(&call, bc->bv);
  if (iree_status_is_ok(st))
    st = iree_runtime_call_inputs_push_back_buffer_view(&call, bb->bv);
  if (iree_status_is_ok(st)) st = iree_runtime_call_invoke(&call, 0);
  if (iree_status_is_ok(st)) {
    /* IREE does not tie operands, so the result is a NEW buffer view even
     * though the kernel reads a background and returns a framebuffer (E030
     * s4.3-1).  Adopt it into `hout` rather than copying it back: zero
     * transfers, and the caller's handle keeps naming the current frame. */
    iree_hal_buffer_view_t *br = NULL;
    st = iree_runtime_call_outputs_pop_front_buffer_view(&call, &br);
    if (iree_status_is_ok(st)) {
      iree_hal_buffer_view_release(bo->bv);
      bo->bv = br;
      bo->n = (size_t)H * (size_t)W;
      bo->d0 = (size_t)H;
      bo->d1 = (size_t)W;
      bo->rank = 2;
      bo->dt = SP_R_I8;
    }
  }
  iree_runtime_call_deinitialize(&call);
  if (!iree_status_is_ok(st)) return fail(st, "sp_r_dispatch");
  g_count[C_INVOKE]++;
  return 0;
}

/* E061's entry point, kept byte-compatible: wall slots are cut by x, so the
 * slot axis is W. */
int sp_r_dispatch(const char *kind, uint64_t ksig, const char *entry,
                  int64_t hjobs, int64_t htex, int64_t hcmap, int64_t hbg,
                  int64_t hout, int W, int H, int K) {
  return sp_r_dispatch_gather(kind, ksig, entry, hjobs, htex, hcmap, hbg, hout,
                              W, H, K, W);
}
