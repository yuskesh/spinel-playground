/* sp_raster_gpu.c -- E073 (P005 Phase 6): the RUBY-facing seam of the Job IR
 * GPU path.
 *
 * Through E071 every GPU frame was drawn by `raster_run.c`, a C driver that
 * read the Job IR back out of files that `dump_jobs` had written.  That proved
 * the kernels but left the sentence "a Ruby program draws DOOM on the GPU"
 * untrue: nothing in doom/ could reach the device.  This TU is that reach.
 *
 * WHAT IS DIFFERENT FROM raster_run.c, and why each difference exists:
 *
 *  1. THE JOB IR ARRIVES AS THE RUBY BANK ITSELF.  `Doom::Jobs` keeps its three
 *     banks as typed `Array<Int>` in AoS (`i * NF + f`), and Spinel's
 *     `:int_array` hands C the Array's contiguous `.data` (`const int64_t *`)
 *     with no copy and no allocation (vendor/spinel docs/FFI.md).  So the
 *     planar-SoA `Jobs#pack` step that raster_run consumed from a file does not
 *     happen at all: the slot builder reads the AoS bank directly.  That is the
 *     two-layer ABI of E057 doing its job -- layer 1 (the logical fields) is
 *     what crosses, layer 2 (the physical layout) is chosen at this seam.
 *
 *     Lifetime: FFI.md says the pointer is call-duration only.  Nothing here
 *     stashes it; every bank, the zone ring and the WAD are passed on EVERY
 *     frame call for exactly that reason.
 *
 *  2. THE BACKGROUND IS THE CURRENT SCREEN, NOT ZERO.  raster_run uploaded a
 *     zeroed background because its oracle (`stagedfb.bin`) was drawn on one.
 *     In the real program the framebuffer PERSISTS across frames (D-3-7: vanilla
 *     never clears it), and `R_DrawFuzzColumn` reads whatever is under it.  So
 *     the view rectangle of the caller's screen goes UP as the background and
 *     comes back down as the result: the GPU path is then bit-identical to the
 *     CPU executor by construction, whatever the coverage of the frame is.
 *
 *  3. A REFUSAL MUST LEAVE THE SCREEN UNTOUCHED.  Everything that can say no --
 *     the caps, the window atlas, the batch plan, the runtime K selection -- runs
 *     BEFORE the first upload, and the only write to the caller's buffer is the
 *     final readback.  That is what makes "fall back to the CPU executor and draw
 *     the same frame" a correct answer rather than a repair.
 *
 *  4. ZERO PER-FRAME ALLOCATION ON BOTH SIDES.  Every host scratch buffer is
 *     allocated in sp_rg_open/sp_rg_geometry and reused; the device buffers are
 *     allocated once (one slot buffer per table row, as in E071).  sp_rg_frame
 *     therefore contains no call to malloc AT ALL -- that is a property of the
 *     source, checkable by reading it, and the shim's own alloc counter (index 3)
 *     is the second instrument that must not move once the loop starts.
 *
 * The kernels, the entry table, the ordering argument and the K-selection rule
 * are E071's, ported here rather than shared, because raster_run.c is the
 * artifact 114 bit-exact runs were measured with and E073 is additive: the old
 * driver is not touched.  The cost of the duplication is paid back by the gate
 * that matters -- every sampled frame of DEMO1/2/3 is compared against the Job
 * IR CPU executor IN THE SAME PROCESS, which is exactly the comparison that
 * would catch a divergence between the two copies of the plan.
 *
 * NOT thread safe: all state is process-global static, as in E030/E061.
 */

#include <stdarg.h>
#include <stdint.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "sp_job_table.h"

/* ------------------------------------------------- the E061 device seam */

enum { SP_R_I8 = 0, SP_R_I32 = 1 };
enum { C_H2D = 0, C_D2H = 1, C_INVOKE = 2, C_ALLOC = 3, C_FREE = 4 };

int sp_r_open(const char *vmfb_path, const char *device_uri);
void sp_r_close(void);
const char *sp_r_last_error(void);
int64_t sp_r_alloc(int64_t d0, int64_t d1, int rank, int dt);
int sp_r_h2d(int64_t h, const void *src, size_t nbytes);
int sp_r_d2h(int64_t h, void *dst, size_t nbytes);
int sp_r_dispatch_gather(const char *kind, uint64_t ksig, const char *entry,
                         int64_t hjobs, int64_t hres, int64_t hcmap, int64_t hbg,
                         int64_t hout, int W, int H, int K, int slotdim);
int64_t sp_r_counter(int i);

/* -------------------------------------------------------------- constants */

#define NPLANE 6            /* the six gather planes every kernel reads      */
#define WC_NF 7             /* Doom::Jobs::WC_NF -- wall / opaque columns    */
#define SP_NF 7             /* Doom::Jobs::SP_NF -- plane spans              */
#define MC_NF 9             /* Doom::Jobs::MC_NF -- masked / fuzz columns    */

#define MC_X 0
#define MC_YL 1
#define MC_YH 2
#define MC_ISCALE 3
#define MC_TEXMID 4
#define MC_SRCRES 5
#define MC_SRCOFS 6
#define MC_CMAP 7
#define MC_FUZZ 8

#define RES_WAD 1           /* Doom::Jobs::RES_WAD  */
#define RES_ZONE 2          /* Doom::Jobs::RES_ZONE */

#define WIN_SLOTS 8192      /* = Doom::Jobs::CAP_MASKED; the ksig folds it in */
#define WIN_STRIDE 128
#define WIN_BYTES ((size_t)WIN_SLOTS * WIN_STRIDE)
#define FUZZOFF_N 50
/* E071 measured at most 7 masked batches (9 dispatches with opaque + span).
 * 16 is the cap here; more than that is a loud REJECT and the CPU executor
 * draws the frame, which is the whole point of Phase 6. */
#define MAX_BATCH 16
#define MAX_ENTRIES 32

/* Ring caps, mirrored from Doom::Jobs so the seam refuses a bank that could not
 * have come from the Job IR (a Ruby-side ring overflow raises before it gets
 * here; this is the C side saying the same thing about its own scratch). */
#define CAP_WALL 4096
#define CAP_SPAN 3072
#define CAP_MASKED 8192
/* E075 (P005 Phase 7): the caps above are the s = 1 (320x200) values.  Wall and
 * masked columns are a per-screen-column family and spans are a per-scanline
 * family, so all three rings scale with the internal resolution factor
 * s = W / 320 exactly as Doom::Jobs does.  The WINDOW ATLAS does NOT scale:
 * its capacity is folded into every masked kernel's ksig, and the number of
 * DISTINCT 128 B source windows is bounded by the visible sprites' texel
 * columns, not by the screen width (E075 s3.3 measured it at every
 * resolution).  Overflowing it is a loud REJECT and the CPU executor draws
 * the frame, which is the designed answer. */
#define RES_BASE_W 320

/* ------------------------------------------------------------------ state */

static char g_err[768];
static int g_open = 0;
static int g_geom = 0;
static int g_res = 0;
static int g_W, g_H, g_SW, g_SH, g_vwx, g_vwy;
/* E075: the internal-resolution factor and the ring caps it scales. */
static int g_rs = 1;
static int g_cap_wall = CAP_WALL, g_cap_span = CAP_SPAN,
           g_cap_masked = CAP_MASKED;

typedef struct {
  char row[64];
  char kind[16];
  char entry[128];
  uint64_t ksig;
  int K;
  int64_t hslots;      /* one device slot buffer per table row (E071) */
} entry_row_t;

static entry_row_t g_ent[MAX_ENTRIES];
static int g_nent = 0;
/* E075: the resolution the entry table was generated for (0 = an older table
 * that does not declare one).  sp_rg_geometry refuses a disagreement. */
static int g_ent_W = 0, g_ent_H = 0;
static int g_klimit = 0;      /* SPINEL_RASTER_KLIMIT: drop rows with K > this */
static int g_force_reject = 0;/* SPINEL_RASTER_FORCE_REJECT                    */

typedef struct {
  int fuzz, lo, hi, slot;
} mbatch_t;

/* host scratch -- all of it allocated once, outside any frame */
static unsigned char *g_win = NULL;      /* the per-frame 128 B window atlas   */
static int32_t *g_newofs = NULL;         /* rewritten srcofs, one per masked   */
static uint32_t *g_slots = NULL;         /* the widest slot buffer of any row  */
static size_t g_slots_cap = 0;
static unsigned char *g_fbstage = NULL;  /* the view rectangle, packed         */
static int *g_cnt = NULL;                /* per-column / per-scanline counter  */
static int g_cnt_n = 0;
static mbatch_t g_plan[MAX_BATCH];
static const entry_row_t *g_rowM[MAX_BATCH];

static int64_t g_hcmap, g_hatlas, g_hflat, g_hwin, g_hfoff, g_hbg, g_hfb[2];

/* counters: 0..4 mirror the E061 shim, 5.. are this seam's */
enum { G_FRAMES = 5, G_DISPATCH = 6, G_REJECT = 7, G_NWIN = 8, G_NBATCH = 9,
       /* ★ which TABLE ROW the host chose for this frame -- the runtime K
        * switch of E070 item 7, published so a Ruby caller can record it.
        * (10 is left unused so the K indices keep the numbers a Ruby caller
        * already learned.) */
       G_KOPAQUE = 11, G_KSPAN = 12, G_KMASKED = 13, G_NCOUNTER = 14 };
static int64_t g_count[G_NCOUNTER];

/* --------------------------------------------------------------- plumbing */

static int failf(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_err, sizeof g_err, fmt, ap);
  va_end(ap);
  return -1;
}

/* A REJECT is a refusal, not a crash: it is counted, it names itself, and the
 * caller's framebuffer has not been touched. */
static int reject(const char *fmt, ...) {
  va_list ap;
  va_start(ap, fmt);
  vsnprintf(g_err, sizeof g_err, fmt, ap);
  va_end(ap);
  g_count[G_REJECT]++;
  return -1;
}

const char *sp_rg_error(void) { return g_err; }

/* 1 when the real IREE-backed seam is linked in.  The stub TU answers 0, and
 * that is Phase 6's "device absent" leg: a binary built without a GPU backend
 * asks this, gets 0, says so once, and runs the CPU executor. */
int sp_rg_available(void) { return 1; }

int64_t sp_rg_counter(int i) {
  if (i >= 0 && i <= C_FREE) return sp_r_counter(i);
  if (i >= G_FRAMES && i < G_NCOUNTER) return g_count[i];
  return -1;
}

void sp_rg_counters_reset(void) {
  for (int i = G_FRAMES; i < G_NCOUNTER; i++) g_count[i] = 0;
}

/* ---------------------------------------------------------- the entry table */

static int load_entries(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) return failf("sp_rg_open: cannot read the entry table %s", path);
  char line[512];
  g_nent = 0;
  g_ent_W = 0;
  g_ent_H = 0;
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '#') continue;
    if (g_nent >= MAX_ENTRIES) break;
    entry_row_t *e = &g_ent[g_nent];
    char ks[64], sd[8];
    int ew = 0, eh = 0;
    int nf = sscanf(line, "%63s %15s %d %127s %63s %7s %d %d", e->row, e->kind,
                    &e->K, e->entry, ks, sd, &ew, &eh);
    if (nf < 5) continue;
    e->ksig = strtoull(ks, NULL, 16);
    /* E075: columns 7/8 are the view resolution the kernels were generated for.
     * Older tables (E061..E073) stop at column 6 and leave it unknown. */
    if (nf >= 8 && ew > 0 && eh > 0) { g_ent_W = ew; g_ent_H = eh; }
    /* SPINEL_RASTER_KLIMIT drops the wide rows of the two families that declare
     * more than one K (`masked` k8/k16/k40 and `span` k4/k16).  It is NOT a
     * simulated failure: pick_row then genuinely cannot cover the frames whose
     * per-column count is large, so the K-overflow REJECT that Phase 6's
     * fallback has to survive is the real one, on real frames, and it fires on
     * SOME frames and not others -- which is what makes it a test of the
     * fallback rather than a test of "everything is off" (E071 hand-off 2).
     * opaque and fuzz have exactly one row each; dropping those would mean "no
     * kernels at all", and that case has its own switch (FORCE_REJECT). */
    if (g_klimit > 0 && e->K > g_klimit &&
        (strcmp(e->kind, "masked") == 0 || strcmp(e->kind, "span") == 0))
      continue;
    e->hslots = 0;
    g_nent++;
  }
  fclose(f);
  if (g_nent == 0) return failf("sp_rg_open: the entry table %s has no rows", path);
  return 0;
}

/* The smallest declared K of `kind` that covers `need` (E071's rule, verbatim).
 * NULL means the table declares no kernel that can draw this frame -- a REJECT,
 * never a silent truncation. */
static const entry_row_t *pick_row(const char *kind, int need) {
  const entry_row_t *best = NULL;
  for (int i = 0; i < g_nent; i++)
    if (strcmp(g_ent[i].kind, kind) == 0 && g_ent[i].K >= need &&
        (!best || g_ent[i].K < best->K))
      best = &g_ent[i];
  return best;
}

/* -------------------------------------------------------------- lifecycle */

static const char *env_or(const char *name, const char *dflt) {
  const char *v = getenv(name);
  return (v && v[0]) ? v : dflt;
}

int sp_rg_open(const char *vmfb, const char *device, const char *entries) {
  g_err[0] = 0;
  if (g_open) return failf("sp_rg_open: a device scope is already open");
  if (!vmfb || !vmfb[0]) vmfb = env_or("SPINEL_RASTER_VMFB", "");
  if (!device || !device[0]) device = env_or("SPINEL_RASTER_DEVICE", "metal");
  if (!entries || !entries[0]) entries = env_or("SPINEL_RASTER_ENTRIES", "");
  if (!vmfb[0])
    return failf("sp_rg_open: no .vmfb (pass one or set SPINEL_RASTER_VMFB). "
                 "An AOT binary carries no compiler, so the module must have "
                 "been built before the program ran (E030)");
  if (!entries[0])
    return failf("sp_rg_open: no entry table (pass one or set "
                 "SPINEL_RASTER_ENTRIES). The table decides which kernels "
                 "exist; without it the host cannot choose a row");

  const char *kl = getenv("SPINEL_RASTER_KLIMIT");
  g_klimit = kl && kl[0] ? atoi(kl) : 0;
  g_force_reject = getenv("SPINEL_RASTER_FORCE_REJECT") != NULL;

  if (load_entries(entries) != 0) return -1;
  if (sp_r_open(vmfb, device) != 0) {
    snprintf(g_err, sizeof g_err, "sp_rg_open: %s", sp_r_last_error());
    /* sp_r_open leaves whatever it managed to build standing (a session with no
     * module, say).  Tear it down here, or the NEXT open answers "a device
     * scope is already open" and a caller that retries -- or a reject suite
     * that tries several broken forms in one process -- gets the wrong reason. */
    sp_r_close();
    return -1;
  }
  g_open = 1;
  g_geom = 0;
  g_res = 0;
  for (int i = G_FRAMES; i < G_NCOUNTER; i++) g_count[i] = 0;
  return 0;
}

void sp_rg_close(void) {
  if (g_open) sp_r_close();
  g_open = 0;
  g_geom = 0;
  g_res = 0;
  g_nent = 0;
  free(g_win); g_win = NULL;
  free(g_newofs); g_newofs = NULL;
  free(g_slots); g_slots = NULL;
  g_slots_cap = 0;
  free(g_fbstage); g_fbstage = NULL;
  free(g_cnt); g_cnt = NULL;
  g_cnt_n = 0;
}

/* The view rectangle and the screen it sits in.  Both are frame constants of
 * the Job IR executor (executor.rb's third bullet), and the kernels' ksig folds
 * W / H / centery in -- so this is also where a resolution that the .vmfb was
 * not built for is refused, before a single job moves. */
int sp_rg_geometry(int W, int H, int screen_w, int screen_h, int vwx, int vwy) {
  g_err[0] = 0;
  if (!g_open) return failf("sp_rg_geometry: no device scope is open");
  if (W <= 0 || H <= 0 || screen_w <= 0 || screen_h <= 0)
    return failf("sp_rg_geometry: %dx%d view in a %dx%d screen is not a screen",
                 W, H, screen_w, screen_h);
  if (vwx < 0 || vwy < 0 || vwx + W > screen_w || vwy + H > screen_h)
    return failf("sp_rg_geometry: the %dx%d view at (%d,%d) does not fit in the "
                 "%dx%d screen", W, H, vwx, vwy, screen_w, screen_h);
  /* The geometry is set ONCE per device scope, because it is what sizes the
   * device buffers.  Calling it again with the same numbers is a no-op (a
   * caller may re-assert it); calling it with different numbers would strand
   * the buffers the first call allocated, so it is refused rather than leaked.
   * The resolution is also part of every kernel's ksig, so "change the geometry"
   * really means "load a different module". */
  if (g_geom) {
    if (g_W == W && g_H == H && g_SW == screen_w && g_SH == screen_h &&
        g_vwx == vwx && g_vwy == vwy)
      return 0;
    return failf("sp_rg_geometry: the geometry is already %dx%d at (%d,%d) in "
                 "%dx%d; it sizes the device buffers and the kernels' ksig folds "
                 "the resolution in, so it cannot change inside one device scope",
                 g_W, g_H, g_vwx, g_vwy, g_SW, g_SH);
  }
  /* E075: the kernels' ksig folds the resolution in, so a table generated for a
   * different view CANNOT draw this one.  Until Phase 7 the only thing that
   * noticed was IREE's shape assert, deep inside the first dispatch (still a
   * loud REJECT before any readback, so the fallback was correct -- but the
   * table and the checker were silent about it, and the whole point of the
   * "table + checker" method is that the contract is checked HERE). */
  if (g_ent_W > 0 && (g_ent_W != W || g_ent_H != H))
    return failf("sp_rg_geometry: the entry table was generated for a %dx%d "
                 "view but this scope declares %dx%d; the resolution is folded "
                 "into every kernel's ksig, so regenerate the .vmfb and the "
                 "entry table for %dx%d", g_ent_W, g_ent_H, W, H, W, H);
  g_W = W; g_H = H; g_SW = screen_w; g_SH = screen_h; g_vwx = vwx; g_vwy = vwy;
  g_rs = W / RES_BASE_W;
  if (g_rs < 1) g_rs = 1;
  g_cap_wall = CAP_WALL * g_rs;
  g_cap_span = CAP_SPAN * g_rs;
  g_cap_masked = CAP_MASKED * g_rs;

  /* --- host scratch, allocated ONCE (nothing below is ever freed per frame) */
  int cn = W > H ? W : H;
  g_cnt = realloc(g_cnt, (size_t)cn * sizeof(int));
  g_cnt_n = cn;
  g_win = realloc(g_win, WIN_BYTES);
  memset(g_win, 0, WIN_BYTES);
  g_newofs = realloc(g_newofs, (size_t)g_cap_masked * sizeof(int32_t));
  g_fbstage = realloc(g_fbstage, (size_t)W * (size_t)H);
  if (!g_cnt || !g_win || !g_newofs || !g_fbstage)
    return failf("sp_rg_geometry: out of memory for the host scratch");

  /* --- device buffers, allocated ONCE.  One slot buffer per table row, sized
   * EXACTLY slotdim*K*6 i32 so the E070 exact-size guard in sp_r_dispatch_gather
   * stays meaningful (E071 s3.7). */
  size_t widest = 0;
  for (int i = 0; i < g_nent; i++) {
    int sd = strcmp(g_ent[i].kind, "span") == 0 ? H : W;
    size_t n = (size_t)sd * (size_t)g_ent[i].K * NPLANE;
    g_ent[i].hslots = sp_r_alloc((int64_t)n, 0, 1, SP_R_I32);
    if (!g_ent[i].hslots)
      return failf("sp_rg_geometry: slot buffer for %s: %s", g_ent[i].row,
                   sp_r_last_error());
    if (n > widest) widest = n;
  }
  g_slots = realloc(g_slots, widest * sizeof(uint32_t));
  g_slots_cap = widest;
  g_hbg = sp_r_alloc(H, W, 2, SP_R_I8);
  g_hfb[0] = sp_r_alloc(H, W, 2, SP_R_I8);
  g_hfb[1] = sp_r_alloc(H, W, 2, SP_R_I8);
  if (!g_slots || !g_hbg || !g_hfb[0] || !g_hfb[1])
    return failf("sp_rg_geometry: framebuffer alloc: %s", sp_r_last_error());
  g_geom = 1;
  return 0;
}

/* The resident resources (E030's `resident_alloc` position): they go up once,
 * outside the frame loop, because they are static for the whole level.  The
 * atlases are permutations of texdata/flatdata (E057 T-atlas), so sending them
 * IS sending the WAD's textures. */
int sp_rg_resident(const char *atlas, size_t natlas, const char *flat, size_t nflat,
                   const char *cmap, size_t ncmap, const char *fuzzoff, size_t nfuzz) {
  g_err[0] = 0;
  if (!g_open) return failf("sp_rg_resident: no device scope is open");
  if (!g_geom) return failf("sp_rg_resident: call sp_rg_geometry first");
  if (!atlas || !flat || !cmap || !fuzzoff)
    return failf("sp_rg_resident: a null resource");
  if (natlas == 0 || nflat == 0 || ncmap == 0)
    return failf("sp_rg_resident: a zero-length resource (%zu/%zu/%zu)",
                 natlas, nflat, ncmap);
  if (nfuzz < FUZZOFF_N)
    return failf("sp_rg_resident: the fuzzoffset table is %zu bytes, the kernel "
                 "declares %d", nfuzz, FUZZOFF_N);
  g_hcmap = sp_r_alloc((int64_t)ncmap, 0, 1, SP_R_I8);
  g_hatlas = sp_r_alloc((int64_t)natlas, 0, 1, SP_R_I8);
  g_hflat = sp_r_alloc((int64_t)nflat, 0, 1, SP_R_I8);
  g_hwin = sp_r_alloc((int64_t)WIN_BYTES, 0, 1, SP_R_I8);
  g_hfoff = sp_r_alloc(FUZZOFF_N, 0, 1, SP_R_I8);
  if (!g_hcmap || !g_hatlas || !g_hflat || !g_hwin || !g_hfoff)
    return failf("sp_rg_resident: alloc: %s", sp_r_last_error());
  if (sp_r_h2d(g_hcmap, cmap, ncmap) != 0 ||
      sp_r_h2d(g_hatlas, atlas, natlas) != 0 ||
      sp_r_h2d(g_hflat, flat, nflat) != 0 ||
      sp_r_h2d(g_hfoff, fuzzoff, FUZZOFF_N) != 0)
    return failf("sp_rg_resident: h2d: %s", sp_r_last_error());
  g_res = 1;
  return 0;
}

/* -------------------------------------------------- the AoS bank accessors */

/* The Ruby bank is `Array<Int>` in AoS: element (i, f) is `bank[i * nf + f]`,
 * mrb_int = int64.  A Job IR field is 32 bits (i32 or a 16.16 u32), so the low
 * 32 bits are the value -- exactly what `Jobs#pack` masked with 0xffffffff. */
static inline uint32_t fld(const int64_t *b, int nf, int i, int f) {
  return (uint32_t)(uint64_t)b[(size_t)i * nf + f];
}
static inline int32_t sfld(const int64_t *b, int nf, int i, int f) {
  return (int32_t)(uint32_t)(uint64_t)b[(size_t)i * nf + f];
}

/* -------------------------------------------------------- slot building */

/* wall / opaque and span share a shape: field 0 is the axis the slots are cut
 * by, fields 1..2 are the closed interval on the other axis, fields 1..6 are the
 * six planes.  One builder serves both (raster_run's `build_slots`). */
static int build_slots(const int64_t *bank, int n, int nf, int slotdim, int K,
                       uint32_t *out) {
  size_t wk = (size_t)slotdim * (size_t)K;
  for (size_t f = 0; f < NPLANE; f++)
    for (size_t s = 0; s < wk; s++) out[f * wk + s] = (f == 0) ? 1u : 0u;
  memset(g_cnt, 0, (size_t)slotdim * sizeof(int));
  for (int i = 0; i < n; i++) {
    int32_t lo = sfld(bank, nf, i, 1), hi = sfld(bank, nf, i, 2);
    if (lo > hi) continue;                       /* paints nothing */
    int32_t a = sfld(bank, nf, i, 0);
    if (a < 0 || a >= slotdim) return -1;
    int k = g_cnt[a]++;
    if (k >= K) return 1;
    size_t s = (size_t)a * K + k;
    for (int f = 0; f < NPLANE; f++) out[(size_t)f * wk + s] = fld(bank, nf, i, f + 1);
  }
  return 0;
}

static int slots_max_k(const int64_t *bank, int n, int nf, int slotdim) {
  memset(g_cnt, 0, (size_t)slotdim * sizeof(int));
  int mk = 0;
  for (int i = 0; i < n; i++) {
    if (sfld(bank, nf, i, 1) > sfld(bank, nf, i, 2)) continue;
    int32_t a = sfld(bank, nf, i, 0);
    if (a < 0 || a >= slotdim) continue;
    if (++g_cnt[a] > mk) mk = g_cnt[a];
  }
  return mk;
}

/* The per-frame 128-byte window atlas.  Deduplicated by (srcres, srcofs): one
 * sprite post window is usually read by many columns.  Fuzz jobs read no
 * texture at all, so they are skipped. */
static int build_windows(const int64_t *m, int n, const unsigned char *wad,
                         size_t nwad, const unsigned char *zone, size_t nzone,
                         int *nwin) {
  static int32_t kres[WIN_SLOTS * 2], kofs[WIN_SLOTS * 2], kval[WIN_SLOTS * 2];
  const int M = WIN_SLOTS * 2;
  for (int i = 0; i < M; i++) kval[i] = -1;
  int cnt = 0;
  for (int i = 0; i < n; i++) {
    g_newofs[i] = 0;
    if (sfld(m, MC_NF, i, MC_FUZZ) >= 0) continue;
    if (sfld(m, MC_NF, i, MC_YL) > sfld(m, MC_NF, i, MC_YH)) continue;
    int32_t r = sfld(m, MC_NF, i, MC_SRCRES);
    int32_t o = sfld(m, MC_NF, i, MC_SRCOFS);
    if (r != RES_WAD && r != RES_ZONE) return -2;
    if (o < 0) return -3;
    uint32_t h = ((uint32_t)r * 2654435761u + (uint32_t)o * 2246822519u) &
                 (uint32_t)(M - 1);
    while (kval[h] >= 0 && !(kres[h] == r && kofs[h] == o))
      h = (h + 1) & (uint32_t)(M - 1);
    if (kval[h] < 0) {
      if (cnt >= WIN_SLOTS) return -1;
      const unsigned char *src = (r == RES_ZONE) ? zone : wad;
      size_t cap = (r == RES_ZONE) ? nzone : nwad;
      unsigned char *dst = g_win + (size_t)cnt * WIN_STRIDE;
      memset(dst, 0, WIN_STRIDE);
      if ((size_t)o < cap) {
        size_t take = cap - (size_t)o;
        if (take > WIN_STRIDE) take = WIN_STRIDE;
        memcpy(dst, src + o, take);
      }
      kres[h] = r;
      kofs[h] = o;
      kval[h] = cnt * WIN_STRIDE;
      cnt++;
    }
    g_newofs[i] = kval[h];
  }
  *nwin = cnt;
  return 0;
}

/* The dispatch plan: cut at every fuzz/non-fuzz transition, then split each
 * fuzz run by slot index.  This IS the ordering argument of E071 s3.3. */
static int plan_batches(const int64_t *m, int n, int W) {
  int nb = 0, i = 0;
  while (i < n) {
    while (i < n && sfld(m, MC_NF, i, MC_YL) > sfld(m, MC_NF, i, MC_YH)) i++;
    if (i >= n) break;
    int fz = sfld(m, MC_NF, i, MC_FUZZ) >= 0;
    int lo = i;
    while (i < n) {
      if (sfld(m, MC_NF, i, MC_YL) <= sfld(m, MC_NF, i, MC_YH) &&
          (sfld(m, MC_NF, i, MC_FUZZ) >= 0) != fz)
        break;
      i++;
    }
    if (!fz) {
      if (nb >= MAX_BATCH) return -1;
      g_plan[nb].fuzz = 0; g_plan[nb].lo = lo; g_plan[nb].hi = i;
      g_plan[nb].slot = -1;
      nb++;
    } else {
      memset(g_cnt, 0, (size_t)W * sizeof(int));
      int mx = 0;
      for (int j = lo; j < i; j++) {
        if (sfld(m, MC_NF, j, MC_YL) > sfld(m, MC_NF, j, MC_YH)) continue;
        int32_t x = sfld(m, MC_NF, j, MC_X);
        if (x < 0 || x >= W) continue;
        if (++g_cnt[x] > mx) mx = g_cnt[x];
      }
      for (int sl = 0; sl < mx; sl++) {
        if (nb >= MAX_BATCH) return -1;
        g_plan[nb].fuzz = 1; g_plan[nb].lo = lo; g_plan[nb].hi = i;
        g_plan[nb].slot = sl;
        nb++;
      }
    }
  }
  return nb;
}

/* The per-column count a batch needs, without building its slots -- the host
 * must know it before it can choose which declared K to dispatch. */
static int mbatch_max_k(const int64_t *m, int n, const mbatch_t *b, int W) {
  memset(g_cnt, 0, (size_t)W * sizeof(int));
  int mk = 0;
  for (int i = b->lo; i < b->hi; i++) {
    if (sfld(m, MC_NF, i, MC_YL) > sfld(m, MC_NF, i, MC_YH)) continue;
    if ((sfld(m, MC_NF, i, MC_FUZZ) >= 0) != b->fuzz) continue;
    int32_t x = sfld(m, MC_NF, i, MC_X);
    if (x < 0 || x >= W) continue;
    int k = ++g_cnt[x];
    if (b->fuzz) k = 1;                 /* one slot per column by construction */
    if (k > mk) mk = k;
  }
  return b->fuzz ? (mk ? 1 : 0) : mk;
}

/* Slots for one masked batch.  The order the slots are packed in IS the
 * schedule order, and the kernel's max-by-key uses k as the key -- packing them
 * any other way silently draws a different picture (checker #12). */
static int build_mbatch_slots(const int64_t *m, int n, const mbatch_t *b, int W,
                              int K, uint32_t *out) {
  memset(g_cnt, 0, (size_t)W * sizeof(int));
  size_t wk = (size_t)W * (size_t)K;
  for (size_t f = 0; f < NPLANE; f++)
    for (size_t s = 0; s < wk; s++) out[f * wk + s] = (f == 0) ? 1u : 0u;
  for (int i = b->lo; i < b->hi; i++) {
    if (sfld(m, MC_NF, i, MC_YL) > sfld(m, MC_NF, i, MC_YH)) continue;
    int isfz = sfld(m, MC_NF, i, MC_FUZZ) >= 0;
    if (isfz != b->fuzz) continue;
    int32_t x = sfld(m, MC_NF, i, MC_X);
    if (x < 0 || x >= W) return -1;
    int k = g_cnt[x]++;
    if (b->fuzz) {
      if (k != b->slot) continue;      /* this dispatch takes one slot only */
      k = 0;
    }
    if (k >= K) return 1;
    size_t s = (size_t)x * K + k;
    out[0 * wk + s] = fld(m, MC_NF, i, MC_YL);
    out[1 * wk + s] = fld(m, MC_NF, i, MC_YH);
    if (b->fuzz) {
      out[2 * wk + s] = fld(m, MC_NF, i, MC_FUZZ);
    } else {
      out[2 * wk + s] = fld(m, MC_NF, i, MC_ISCALE);
      out[3 * wk + s] = fld(m, MC_NF, i, MC_TEXMID);
      out[4 * wk + s] = (uint32_t)g_newofs[i];
      out[5 * wk + s] = fld(m, MC_NF, i, MC_CMAP);
    }
  }
  return 0;
}

/* ------------------------------------------------------------- the frame */

int sp_rg_frame(const int64_t *wall, size_t nwall,
                const int64_t *span, size_t nspan,
                const int64_t *masked, size_t nmasked,
                char *zone, size_t nzone,
                const char *wad, size_t nwad,
                char *fb, size_t nfb) {
  g_err[0] = 0;
  if (!g_open) return reject("sp_rg_frame: no device scope is open -- "
                             "sp_rg_open was not called or it failed");
  if (!g_geom) return reject("sp_rg_frame: no geometry -- call sp_rg_geometry");
  if (!g_res) return reject("sp_rg_frame: the resident resources were never "
                            "uploaded -- call sp_rg_resident");
  if (!wall || !span || !masked || !fb)
    return reject("sp_rg_frame: a null bank or framebuffer");
  if (nfb < (size_t)g_SW * (size_t)g_SH)
    return reject("sp_rg_frame: the framebuffer is %zu bytes, the %dx%d screen "
                  "needs %zu", nfb, g_SW, g_SH, (size_t)g_SW * g_SH);
  if (nwall > (size_t)g_cap_wall || nspan > (size_t)g_cap_span ||
      nmasked > (size_t)g_cap_masked)
    return reject("sp_rg_frame: bank overflow (wall %zu/%d, span %zu/%d, masked "
                  "%zu/%d) -- these are the Job IR ring caps (s=%d) and a bank "
                  "cannot be larger than the ring it came from",
                  nwall, g_cap_wall, nspan, g_cap_span, nmasked, g_cap_masked,
                  g_rs);
  if (g_force_reject)
    return reject("sp_rg_frame: SPINEL_RASTER_FORCE_REJECT is set");

  const int W = g_W, H = g_H;

  /* ---- 1. the window atlas (no upload yet) ------------------------------- */
  int nwin = 0;
  int rc = build_windows(masked, (int)nmasked, (const unsigned char *)wad, nwad,
                         (const unsigned char *)zone, nzone, &nwin);
  if (rc == -1)
    return reject("sp_rg_frame: more than %d distinct masked windows in one "
                  "frame -- the window atlas capacity is folded into the "
                  "kernel's ksig, so it cannot grow at run time", WIN_SLOTS);
  if (rc == -2)
    return reject("sp_rg_frame: a masked job names a resource that is neither "
                  "wad(%d) nor zone(%d); those are the only two the Job IR "
                  "declares for masked columns", RES_WAD, RES_ZONE);
  if (rc == -3) return reject("sp_rg_frame: a masked job has a negative srcofs");

  /* ---- 2. the batch plan ------------------------------------------------- */
  int nplan = plan_batches(masked, (int)nmasked, W);
  if (nplan < 0)
    return reject("sp_rg_frame: more than %d masked batches in one frame",
                  MAX_BATCH);

  /* ---- 3. runtime K selection (E070 item 7 / E071 s3.7) ------------------ */
  int needO = slots_max_k(wall, (int)nwall, WC_NF, W);
  int needS = slots_max_k(span, (int)nspan, SP_NF, H);
  const entry_row_t *rowO = pick_row("opaque", needO);
  const entry_row_t *rowS = pick_row("span", needS);
  if (!rowO)
    return reject("sp_rg_frame: no opaque_columns row with k_max >= %d; the "
                  "table decides which kernels exist and this frame is not "
                  "covered", needO);
  if (!rowS)
    return reject("sp_rg_frame: no plane_spans row with k_max >= %d", needS);
  for (int i = 0; i < nplan; i++) {
    int need = mbatch_max_k(masked, (int)nmasked, &g_plan[i], W);
    g_rowM[i] = g_plan[i].fuzz ? pick_row("fuzz", 1) : pick_row("masked", need);
    if (!g_rowM[i])
      return reject("sp_rg_frame: no %s row with k_max >= %d for batch %d; the "
                    "overflow is NOT silently dropped",
                    g_plan[i].fuzz ? "fuzz_columns" : "masked_columns", need, i);
  }

  /* ---- 4. slots (still no upload; K overflow here is a REJECT too) ------- */
  if (build_slots(wall, (int)nwall, WC_NF, W, rowO->K, g_slots) != 0)
    return reject("check #13: the opaque bank does not fit K=%d slots per column",
                  rowO->K);
  /* opaque slots stay in g_slots until they are uploaded; the span and masked
   * builds reuse the same scratch, so upload each one right after it is built.
   * From here on the device is touched -- but the CALLER'S FRAMEBUFFER IS NOT,
   * until the readback at the very end. */

  if (sp_r_h2d(rowO->hslots, g_slots, (size_t)W * rowO->K * NPLANE * 4) != 0)
    return reject("sp_rg_frame: opaque slot h2d: %s", sp_r_last_error());

  if (build_slots(span, (int)nspan, SP_NF, H, rowS->K, g_slots) != 0)
    return reject("check #10: the span bank does not fit K=%d slots per scanline",
                  rowS->K);
  if (sp_r_h2d(rowS->hslots, g_slots, (size_t)H * rowS->K * NPLANE * 4) != 0)
    return reject("sp_rg_frame: span slot h2d: %s", sp_r_last_error());

  /* ---- 5. the background IS the caller's view rectangle ------------------ */
  for (int y = 0; y < H; y++)
    memcpy(g_fbstage + (size_t)y * W,
           fb + (size_t)(y + g_vwy) * g_SW + g_vwx, (size_t)W);
  if (sp_r_h2d(g_hbg, g_fbstage, (size_t)W * H) != 0)
    return reject("sp_rg_frame: background h2d: %s", sp_r_last_error());
  if (nwin && sp_r_h2d(g_hwin, g_win, (size_t)nwin * WIN_STRIDE) != 0)
    return reject("sp_rg_frame: window atlas h2d: %s", sp_r_last_error());

  /* ---- 6. the dispatch chain, over a framebuffer that stays on the device */
  int st = 0;                     /* how many stages have run */
  int64_t bg = g_hbg;
  int ndisp = 0;

  if (sp_r_dispatch_gather(rowO->row, rowO->ksig, rowO->entry, rowO->hslots,
                           g_hatlas, g_hcmap, bg, g_hfb[st & 1], W, H, rowO->K,
                           W) != 0)
    return reject("sp_rg_frame: opaque dispatch: %s", sp_r_last_error());
  bg = g_hfb[st & 1]; st++; ndisp++;

  if (sp_r_dispatch_gather(rowS->row, rowS->ksig, rowS->entry, rowS->hslots,
                           g_hflat, g_hcmap, bg, g_hfb[st & 1], W, H, rowS->K,
                           H) != 0)
    return reject("sp_rg_frame: span dispatch: %s", sp_r_last_error());
  bg = g_hfb[st & 1]; st++; ndisp++;

  for (int i = 0; i < nplan; i++) {
    const entry_row_t *r = g_rowM[i];
    if (build_mbatch_slots(masked, (int)nmasked, &g_plan[i], W, r->K, g_slots) != 0)
      return reject("check #%d: masked batch %d does not fit K=%d",
                    g_plan[i].fuzz ? 14 : 12, i, r->K);
    if (sp_r_h2d(r->hslots, g_slots, (size_t)W * r->K * NPLANE * 4) != 0)
      return reject("sp_rg_frame: masked slot h2d: %s", sp_r_last_error());
    if (sp_r_dispatch_gather(r->row, r->ksig, r->entry, r->hslots,
                             g_plan[i].fuzz ? g_hfoff : g_hwin, g_hcmap, bg,
                             g_hfb[st & 1], W, H, r->K, W) != 0)
      return reject("sp_rg_frame: %s dispatch (batch %d): %s", r->row, i,
                    sp_r_last_error());
    bg = g_hfb[st & 1]; st++; ndisp++;
  }

  /* ---- 7. the only write to the caller's buffer ------------------------- */
  if (sp_r_d2h(bg, g_fbstage, (size_t)W * H) != 0)
    return reject("sp_rg_frame: readback: %s", sp_r_last_error());
  for (int y = 0; y < H; y++)
    memcpy((char *)fb + (size_t)(y + g_vwy) * g_SW + g_vwx,
           g_fbstage + (size_t)y * W, (size_t)W);

  g_count[G_FRAMES]++;
  g_count[G_DISPATCH] = ndisp;
  g_count[G_NWIN] = nwin;
  g_count[G_NBATCH] = nplan;
  g_count[G_KOPAQUE] = rowO->K;
  g_count[G_KSPAN] = rowS->K;
  { int km = 0;
    for (int i = 0; i < nplan; i++)
      if (!g_plan[i].fuzz && g_rowM[i]->K > km) km = g_rowM[i]->K;
    g_count[G_KMASKED] = km; }
  return 0;
}
