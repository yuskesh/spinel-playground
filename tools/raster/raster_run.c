/* raster_run.c -- the host loop for the Job IR GPU path.
 *
 * E061 (P005 Phase 3): wall columns.  E070 (P005 Phase 4): plane spans, and the
 * two of them composed into one frame.
 *
 *   raster_run --vmfb K.vmfb --entry NAME --ksig HEX --device metal \
 *              --jobs <dumpdir> --W 320 --H 168 --K 16 [--kind wall|span|both] \
 *              [--entry2 NAME --ksig2 HEX --K2 N]  (--kind both) \
 *              [--reps N] [--slots-out F] [--fb-out F] [--tsv F] [--tag T]
 *
 * What it demonstrates, in this order:
 *
 *   1. RESIDENCY.  The texture atlas (1.3 MB), the flat atlas (229 KB) and the
 *      colormap (8.5 KB) go up ONCE, before the loop.  Per frame only the job
 *      slots move (E030's pattern; both atlases are static because they are
 *      permutations of texdata/flatdata -- E057 T-atlas).
 *   2. SLOT BUILDING IS HOST PLUMBING, not part of the Job IR.  The Job IR that
 *      dump_jobs exports is `wall0_soa.bin` / `span1_soa.bin`: the jobs of one
 *      phase in planar SoA, exactly as `Jobs#pack` wrote them.  Turning them
 *      into slots is a scatter by the cut axis (x for walls, **y for spans**)
 *      that the host does; it is written here (not in Ruby) because it is the
 *      GPU path's business, and it is timed separately.
 *   3. ZERO PER-FRAME ALLOCATION on our side of the seam (checker #9): the
 *      shim's alloc counter must not move once the loop starts.
 *   4. BIT-EXACTNESS against the CPU oracle: the framebuffer read back must
 *      equal the file the Spinel-compiled `Doom::JobExecutor` produced from the
 *      same jobs (`wallfb_all.bin` / `spanfb_all.bin` / `compfb.bin`).
 *
 * ★ E071 adds `--kind opaque | masked | fuzz | full`.  `--kind full` is the whole
 * 3-D view on the GPU: ONE module with FOUR entries and a per-frame DISPATCH PLAN
 *
 *     opaque_gather   all wall-bank jobs (phase 0 walls AND the phase 1 sky)
 *     plane_gather    the spans
 *     masked_gather   one dispatch per non-fuzz masked BATCH
 *     fuzz_gather     one dispatch per (fuzz batch, slot index) pair
 *
 * over a framebuffer that never leaves the device.  The plan is derived here, from
 * the masked bank alone, by two rules:
 *
 *   (1) cut the masked schedule wherever it switches between fuzz and non-fuzz --
 *       a fuzz job reads the framebuffer, so it cannot share a dispatch with a
 *       masked job that was issued after it;
 *   (2) split every fuzz batch by SLOT INDEX, so that one dispatch never holds two
 *       fuzz jobs of the same column.  Two fuzz jobs of one column can be
 *       read-after-write dependent (measured: 54 pairs over all 10 996 frames);
 *       two fuzz jobs of DIFFERENT columns never touch each other's pixels.
 *
 * Rule (2) is why the fuzz kernel's K is 1: it is a contract the host satisfies by
 * construction, not a property of the data.
 *
 * ★ `--kind both` is the composite (E070 s3.5): ONE module with two entries,
 * ONE device scope, and TWO dispatches over a framebuffer that stays on the
 * device -- the wall stage writes it, the span stage reads it as `bg` and
 * writes it again.  There is no framebuffer copy between the stages, because
 * IREE ties the `outs` operand (R009 s10 hypothesis 4, measured in E061 s3.6).
 */

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

enum { SP_R_I8 = 0, SP_R_I32 = 1 };
enum { C_H2D = 0, C_D2H = 1, C_INVOKE = 2, C_ALLOC = 3, C_FREE = 4 };

int sp_r_open(const char *vmfb_path, const char *device_uri);
void sp_r_close(void);
const char *sp_r_last_error(void);
int64_t sp_r_alloc(int64_t d0, int64_t d1, int rank, int dt);
void sp_r_free(int64_t h);
int sp_r_h2d(int64_t h, const void *src, size_t nbytes);
int sp_r_d2h(int64_t h, void *dst, size_t nbytes);
int sp_r_dispatch(const char *kind, uint64_t ksig, const char *entry,
                  int64_t hjobs, int64_t htex, int64_t hcmap, int64_t hbg,
                  int64_t hout, int W, int H, int K);
int sp_r_dispatch_gather(const char *kind, uint64_t ksig, const char *entry,
                         int64_t hjobs, int64_t hres, int64_t hcmap, int64_t hbg,
                         int64_t hout, int W, int H, int K, int slotdim);
int64_t sp_r_counter(int i);

#define NPLANE 6            /* wall: yl,yh,iscale,texmid,srcofs,cmap           */
                            /* span: x1,x2,position,step,srcofs,cmap           */
#define NFIELD 7            /* the Job IR wall column / plane span             */
/* Field 0 is the axis the slots are cut by (wall: x, span: y) and fields 1..2
 * are the closed interval on the OTHER axis.  The two job kinds agree on that
 * shape, which is why one slot builder serves both. */
#define F_AXIS 0
#define F_LO 1
#define F_HI 2

static double now_ms(void) {
  struct timespec t;
  clock_gettime(CLOCK_MONOTONIC, &t);
  return t.tv_sec * 1e3 + t.tv_nsec / 1e6;
}

static void *slurp(const char *path, size_t *n) {
  FILE *f = fopen(path, "rb");
  if (!f) { fprintf(stderr, "raster_run: cannot open %s\n", path); exit(2); }
  fseek(f, 0, SEEK_END);
  long len = ftell(f);
  fseek(f, 0, SEEK_SET);
  void *p = malloc((size_t)len ? (size_t)len : 1);
  if (fread(p, 1, (size_t)len, f) != (size_t)len) {
    fprintf(stderr, "raster_run: short read on %s\n", path);
    exit(2);
  }
  fclose(f);
  *n = (size_t)len;
  return p;
}

static long meta_get(const char *dir, const char *key) {
  char path[1024];
  snprintf(path, sizeof path, "%s/meta.tsv", dir);
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "raster_run: cannot open %s\n", path); exit(2); }
  char line[512];
  long v = -1;
  while (fgets(line, sizeof line, f)) {
    char *tab = strchr(line, '\t');
    if (!tab) continue;
    *tab = 0;
    if (strcmp(line, key) == 0) { v = strtol(tab + 1, NULL, 10); break; }
  }
  fclose(f);
  if (v < 0) { fprintf(stderr, "raster_run: no meta key %s\n", key); exit(2); }
  return v;
}

/* Build the slotdim*K planar-SoA gather slots from the Job IR planar SoA.
 *
 * The Job IR arrives as 7 planes of `n` i32 (`Jobs#pack` with LAYOUT_PLANAR_SOA);
 * the kernel wants 6 planes of slotdim*K.  Empty slots get lo=1, hi=0 (an empty
 * interval) and legal indices, because the kernel evaluates `tensor.extract` on
 * every slot and selects afterwards (R009 s3.1-3) -- that is also why the cost
 * scales with the DECLARED K and not with max_k (E061 s3.7).
 * K overflow is LOUD (checker #5 for walls, #10 for spans). */
static int build_slots(const uint32_t *jobs, int n, int stride, int slotdim, int K,
                       uint32_t *out, int *max_k) {
  int *cnt = calloc((size_t)slotdim, sizeof(int));
  size_t wk = (size_t)slotdim * (size_t)K;
  for (size_t f = 0; f < NPLANE; f++)
    for (size_t s = 0; s < wk; s++)
      out[f * wk + s] = (f == 0) ? 1u : 0u;   /* lo=1, hi=0 -> empty */
  int mk = 0, over = 0;
  for (int i = 0; i < n; i++) {
    int32_t a = (int32_t)jobs[(size_t)F_AXIS * stride + i];
    int32_t lo = (int32_t)jobs[(size_t)F_LO * stride + i];
    int32_t hi = (int32_t)jobs[(size_t)F_HI * stride + i];
    if (lo > hi) continue;                    /* paints nothing */
    if (a < 0 || a >= slotdim) { over = -1; break; }
    int k = cnt[a]++;
    if (k >= K) { over = 1; break; }
    size_t s = (size_t)a * K + k;
    for (int f = 0; f < NPLANE; f++)
      out[(size_t)f * wk + s] = jobs[(size_t)(f + 1) * stride + i];
    if (cnt[a] > mk) mk = cnt[a];
  }
  free(cnt);
  *max_k = mk;
  return over;
}

/* One gather stage: which Job IR file, which resource, which axis the slots are
 * cut by, and which table row names the contract. */
typedef struct {
  const char *jobs_file;    /* planar SoA of one phase                         */
  const char *njob_key;     /* meta.tsv key holding its job count              */
  const char *res_file;     /* the resource the kernel reads                   */
  const char *table_kind;   /* the sp_job_table.h row name (checked by #8)     */
  int slot_axis;            /* 0 = cut by x (W), 1 = cut by y (H)              */
} stage_def_t;

/* ------------------------------------------------------- E071: masked & fuzz */

#define MC_NFIELD 9      /* x,yl,yh,iscale,texmid,srcres,srcofs,cmap,fuzz */
#define MC_X 0
#define MC_YL 1
#define MC_YH 2
#define MC_ISCALE 3
#define MC_TEXMID 4
#define MC_SRCRES 5
#define MC_SRCOFS 6
#define MC_CMAP 7
#define MC_FUZZ 8

/* The per-frame window atlas capacity is the Job IR ring CAP_MASKED.  It is FIXED
 * because the kernel's ksig folds in the resource size: a per-frame size would
 * make the kernel depend on the frame, which every stage so far has avoided. */
#define WIN_SLOTS 8192
#define WIN_STRIDE 128
#define WIN_BYTES ((size_t)WIN_SLOTS * WIN_STRIDE)
#define FUZZOFF_N 50
#define MAX_BATCH 64

typedef struct {
  int fuzz;      /* 0 = masked batch, 1 = fuzz batch                        */
  int lo, hi;    /* masked-bank index range (half open)                     */
  int slot;      /* fuzz only: which per-column slot this dispatch takes    */
  int njob;      /* jobs actually placed                                    */
  int max_k;     /* slots used per column                                   */
} mbatch_t;

static int32_t mfield(const uint32_t *m, int n, int f, int i) {
  return (int32_t)m[(size_t)f * n + i];
}

/* Build the per-frame 128-byte window atlas from the two masked resources and
 * rewrite each job's srcofs to slot*128.  Deduplicated by (srcres, srcofs): the
 * same post window is usually read by many columns of one sprite. */
static int build_windows(const uint32_t *m, int n, const unsigned char *res1,
                         size_t n1, const unsigned char *res2, size_t n2,
                         unsigned char *win, int32_t *newofs, int *nwin) {
  /* open addressing on (res,ofs); WIN_SLOTS is a power of two */
  static int32_t kres[WIN_SLOTS * 2], kofs[WIN_SLOTS * 2], kval[WIN_SLOTS * 2];
  const int M = WIN_SLOTS * 2;
  for (int i = 0; i < M; i++) kval[i] = -1;
  int cnt = 0;
  for (int i = 0; i < n; i++) {
    newofs[i] = 0;
    if (mfield(m, n, MC_FUZZ, i) >= 0) continue;
    if (mfield(m, n, MC_YL, i) > mfield(m, n, MC_YH, i)) continue;
    int32_t r = mfield(m, n, MC_SRCRES, i);
    int32_t o = mfield(m, n, MC_SRCOFS, i);
    uint32_t h = ((uint32_t)r * 2654435761u + (uint32_t)o * 2246822519u) & (uint32_t)(M - 1);
    while (kval[h] >= 0 && !(kres[h] == r && kofs[h] == o)) h = (h + 1) & (uint32_t)(M - 1);
    if (kval[h] < 0) {
      if (cnt >= WIN_SLOTS) return -1;
      const unsigned char *src = (r == 2) ? res2 : res1;
      size_t cap = (r == 2) ? n2 : n1;
      unsigned char *dst = win + (size_t)cnt * WIN_STRIDE;
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
    newofs[i] = kval[h];
  }
  *nwin = cnt;
  return 0;
}

/* The dispatch plan: cut at every fuzz/non-fuzz transition, then split each fuzz
 * run by slot index.  This function IS the ordering argument of E071 s3.3. */
static int plan_batches(const uint32_t *m, int n, int W, mbatch_t *out, int cap) {
  int nb = 0, i = 0;
  int *cnt = calloc((size_t)W, sizeof(int));
  while (i < n) {
    while (i < n && mfield(m, n, MC_YL, i) > mfield(m, n, MC_YH, i)) i++;
    if (i >= n) break;
    int fz = mfield(m, n, MC_FUZZ, i) >= 0;
    int lo = i;
    while (i < n) {
      if (mfield(m, n, MC_YL, i) <= mfield(m, n, MC_YH, i) &&
          (mfield(m, n, MC_FUZZ, i) >= 0) != fz)
        break;
      i++;
    }
    if (!fz) {
      if (nb >= cap) { free(cnt); return -1; }
      out[nb].fuzz = 0; out[nb].lo = lo; out[nb].hi = i; out[nb].slot = -1;
      nb++;
    } else {
      memset(cnt, 0, (size_t)W * sizeof(int));
      int mx = 0;
      for (int j = lo; j < i; j++) {
        if (mfield(m, n, MC_YL, j) > mfield(m, n, MC_YH, j)) continue;
        int x = mfield(m, n, MC_X, j);
        if (x < 0 || x >= W) continue;
        if (++cnt[x] > mx) mx = cnt[x];
      }
      for (int sl = 0; sl < mx; sl++) {
        if (nb >= cap) { free(cnt); return -1; }
        out[nb].fuzz = 1; out[nb].lo = lo; out[nb].hi = i; out[nb].slot = sl;
        nb++;
      }
    }
  }
  free(cnt);
  return nb;
}

/* The per-column count this batch needs, WITHOUT building the slots -- the host
 * has to know it before it can choose which declared K to dispatch. */
static int mbatch_max_k(const uint32_t *m, int n, const mbatch_t *b, int W) {
  int *cnt = calloc((size_t)W, sizeof(int));
  int mk = 0;
  for (int i = b->lo; i < b->hi; i++) {
    if (mfield(m, n, MC_YL, i) > mfield(m, n, MC_YH, i)) continue;
    if ((mfield(m, n, MC_FUZZ, i) >= 0) != b->fuzz) continue;
    int x = mfield(m, n, MC_X, i);
    if (x < 0 || x >= W) continue;
    int k = ++cnt[x];
    if (b->fuzz) k = 1;                 /* one slot per column by construction */
    if (k > mk) mk = k;
  }
  free(cnt);
  return b->fuzz ? (mk ? 1 : 0) : mk;
}

static int slots_max_k(const uint32_t *j, int n, int slotdim) {
  int *cnt = calloc((size_t)slotdim, sizeof(int));
  int mk = 0;
  for (int i = 0; i < n; i++) {
    if ((int32_t)j[(size_t)F_LO * n + i] > (int32_t)j[(size_t)F_HI * n + i]) continue;
    int a = (int32_t)j[(size_t)F_AXIS * n + i];
    if (a < 0 || a >= slotdim) continue;
    if (++cnt[a] > mk) mk = cnt[a];
  }
  free(cnt);
  return mk;
}

/* Slots for one masked batch.  ★ The order the slots are packed in IS the
 * schedule order, and the kernel's max-by-key uses k as the key -- packing them
 * in any other order silently draws a different picture (checker #12). */
static int build_mbatch_slots(const uint32_t *m, int n, const int32_t *newofs,
                              const mbatch_t *b, int W, int K, uint32_t *out,
                              int *njob, int *max_k) {
  int *cnt = calloc((size_t)W, sizeof(int));
  size_t wk = (size_t)W * (size_t)K;
  for (size_t f = 0; f < NPLANE; f++)
    for (size_t s = 0; s < wk; s++) out[f * wk + s] = (f == 0) ? 1u : 0u;
  int mk = 0, nj = 0, over = 0;
  for (int i = b->lo; i < b->hi && !over; i++) {
    if (mfield(m, n, MC_YL, i) > mfield(m, n, MC_YH, i)) continue;
    int isfz = mfield(m, n, MC_FUZZ, i) >= 0;
    if (isfz != b->fuzz) continue;
    int x = mfield(m, n, MC_X, i);
    if (x < 0 || x >= W) { over = -1; break; }
    int k = cnt[x]++;
    if (b->fuzz) {
      if (k != b->slot) continue;      /* this dispatch takes one slot only */
      k = 0;
    }
    if (k >= K) { over = 1; break; }
    size_t s = (size_t)x * K + k;
    out[0 * wk + s] = m[(size_t)MC_YL * n + i];
    out[1 * wk + s] = m[(size_t)MC_YH * n + i];
    if (b->fuzz) {
      out[2 * wk + s] = m[(size_t)MC_FUZZ * n + i];
    } else {
      out[2 * wk + s] = m[(size_t)MC_ISCALE * n + i];
      out[3 * wk + s] = m[(size_t)MC_TEXMID * n + i];
      out[4 * wk + s] = (uint32_t)newofs[i];
      out[5 * wk + s] = m[(size_t)MC_CMAP * n + i];
    }
    nj++;
    if (k + 1 > mk) mk = k + 1;
  }
  free(cnt);
  *njob = nj;
  *max_k = mk;
  return over;
}

/* ★ E071: the entry table the generator emitted for `--kind every`.
 *
 * One .vmfb holds EVERY gather row of the table -- both plane_spans K's and all
 * three masked_columns K's -- so the host can pick the row that fits this frame
 * without loading another module.  That is E070's item 7 ("keep both .vmfb
 * resident and switch on max_kx") done as one module with several entries: the
 * session is one, the load is once, and the switch is a name. */
typedef struct {
  char row[64];
  char kind[16];
  char entry[128];
  uint64_t ksig;
  int K;
} entry_row_t;

#define MAX_ENTRIES 32
static entry_row_t g_ent[MAX_ENTRIES];
static int g_nent = 0;

static int load_entries(const char *path) {
  FILE *f = fopen(path, "r");
  if (!f) { fprintf(stderr, "raster_run: cannot open %s\n", path); return -1; }
  char line[512];
  while (fgets(line, sizeof line, f)) {
    if (line[0] == '#') continue;
    if (g_nent >= MAX_ENTRIES) break;
    entry_row_t *e = &g_ent[g_nent];
    char ks[64], sd[8];
    if (sscanf(line, "%63s %15s %d %127s %63s %7s", e->row, e->kind, &e->K,
               e->entry, ks, sd) < 5) continue;
    e->ksig = strtoull(ks, NULL, 16);
    g_nent++;
  }
  fclose(f);
  return g_nent;
}

/* The smallest declared K of `kind` that covers `need`.  Refusing (returning
 * NULL) is the right answer when nothing covers it: the table decides which
 * kernels exist, so an uncovered frame is a REJECT, never a silent truncation. */
static const entry_row_t *pick_row(const char *kind, int need) {
  const entry_row_t *best = NULL;
  for (int i = 0; i < g_nent; i++)
    if (strcmp(g_ent[i].kind, kind) == 0 && g_ent[i].K >= need &&
        (!best || g_ent[i].K < best->K))
      best = &g_ent[i];
  return best;
}

/* ★ E071: the full-screen frame (and the single-stage masked/fuzz/opaque runs).
 *
 * Everything resident goes up ONCE.  Per frame the host uploads: the opaque slots,
 * the span slots, the per-frame window atlas, and -- per masked batch -- one slot
 * buffer.  The framebuffer is threaded through every dispatch ON THE DEVICE. */
static int run_e071(const char *kind, const char *vmfb, const char *device,
                    const char *jobs_dir, const char *const *entries,
                    const uint64_t *ksigs, const int *Ks, int W, int H, int reps,
                    const char *oracle_name, const char *fb_out, const char *tsv,
                    const char *tag, int want_fail, int njob_limit,
                    const char *plan_out, int autok, const char *ksel_out) {
  enum { S_OPAQUE = 0, S_SPAN = 1, S_MASKED = 2, S_FUZZ = 3 };
  int do_opaque = strcmp(kind, "full") == 0 || strcmp(kind, "opaque") == 0;
  int do_span = strcmp(kind, "full") == 0;
  int do_masked = strcmp(kind, "full") == 0 || strcmp(kind, "masked") == 0;
  char path[1024];
  size_t nb;

  snprintf(path, sizeof path, "%s/cmap.bin", jobs_dir);
  size_t cmap_n; void *cmap = slurp(path, &cmap_n);
  snprintf(path, sizeof path, "%s/atlas.bin", jobs_dir);
  size_t atlas_n; void *atlas = slurp(path, &atlas_n);
  snprintf(path, sizeof path, "%s/flat.bin", jobs_dir);
  size_t flat_n; void *flat = slurp(path, &flat_n);
  snprintf(path, sizeof path, "%s/fuzzoff.bin", jobs_dir);
  size_t foff_n; void *foff = slurp(path, &foff_n);
  snprintf(path, sizeof path, "%s/mres_1.bin", jobs_dir);
  size_t r1_n; unsigned char *res1 = slurp(path, &r1_n);
  snprintf(path, sizeof path, "%s/mres_2.bin", jobs_dir);
  size_t r2_n; unsigned char *res2 = slurp(path, &r2_n);

  int nmasked = (int)meta_get(jobs_dir, "nmasked");
  snprintf(path, sizeof path, "%s/masked_soa.bin", jobs_dir);
  uint32_t *mj = slurp(path, &nb);
  int nwall = (int)meta_get(jobs_dir, "nwall");
  snprintf(path, sizeof path, "%s/wallall_soa.bin", jobs_dir);
  uint32_t *wj = slurp(path, &nb);
  int nspan = (int)meta_get(jobs_dir, "nspan");
  snprintf(path, sizeof path, "%s/span1_soa.bin", jobs_dir);
  uint32_t *sj = slurp(path, &nb);

  double t_slots = 0, t0 = now_ms();
  /* window atlas + srcofs rewrite */
  unsigned char *win = malloc(WIN_BYTES);
  memset(win, 0, WIN_BYTES);
  int32_t *newofs = calloc((size_t)(nmasked > 0 ? nmasked : 1), sizeof(int32_t));
  int nwin = 0;
  if (build_windows(mj, nmasked, res1, r1_n, res2, r2_n, win, newofs, &nwin) != 0) {
    fprintf(stderr, "raster_run: more than %d distinct masked windows in one frame\n",
            WIN_SLOTS);
    return 3;
  }
  /* the dispatch plan */
  mbatch_t plan[MAX_BATCH];
  int nplan = plan_batches(mj, nmasked, W, plan, MAX_BATCH);
  if (nplan < 0) { fprintf(stderr, "raster_run: more than %d masked batches\n", MAX_BATCH); return 3; }
  if (!do_masked) nplan = 0;
  if (strcmp(kind, "masked") == 0) {
    /* the masked-only oracle takes the NON-FUZZ batches only */
    int k = 0;
    for (int i = 0; i < nplan; i++) if (!plan[i].fuzz) plan[k++] = plan[i];
    nplan = k;
    if (njob_limit >= 0 && nplan > 0) {
      /* the completion condition "a single masked column": keep the first job */
      nplan = 1;
      int seen = 0, hi = plan[0].lo;
      for (int i = plan[0].lo; i < plan[0].hi; i++) {
        if (mfield(mj, nmasked, MC_YL, i) > mfield(mj, nmasked, MC_YH, i)) continue;
        if (mfield(mj, nmasked, MC_FUZZ, i) >= 0) continue;
        hi = i + 1;
        if (++seen >= njob_limit) break;
      }
      plan[0].hi = hi;
    }
  }

  /* ★ E071: runtime K selection.  Nothing about the frame is baked into the
   * module -- the host measures this frame's per-column counts and asks the table
   * which declared kernel covers them (E070 item 7). */
  int Kloc[4] = {Ks[0], Ks[1], Ks[2], Ks[3]};
  const entry_row_t *rowO = NULL, *rowS = NULL, *rowF = NULL;
  const entry_row_t *rowM[MAX_BATCH];
  if (autok) {
    int needO = do_opaque ? slots_max_k(wj, nwall, W) : 0;
    int needS = do_span ? slots_max_k(sj, nspan, H) : 0;
    rowO = pick_row("opaque", needO);
    rowS = pick_row("span", needS);
    rowF = pick_row("fuzz", 1);
    if (do_opaque && !rowO) {
      fprintf(stderr, "raster_run: no opaque_columns row with k_max >= %d; the table "
                      "decides which kernels exist and this frame is not covered\n", needO);
      return 3;
    }
    if (do_span && !rowS) {
      fprintf(stderr, "raster_run: no plane_spans row with k_max >= %d\n", needS);
      return 3;
    }
    if (rowO) Kloc[S_OPAQUE] = rowO->K;
    if (rowS) Kloc[S_SPAN] = rowS->K;
    for (int i = 0; i < nplan; i++) {
      int need = mbatch_max_k(mj, nmasked, &plan[i], W);
      rowM[i] = plan[i].fuzz ? rowF : pick_row("masked", need);
      if (!rowM[i]) {
        fprintf(stderr, "raster_run: no masked_columns row with k_max >= %d for batch "
                        "%d; the overflow is NOT silently dropped\n", need, i);
        return 3;
      }
    }
    if (ksel_out) {
      FILE *f = fopen(ksel_out, "w");
      fprintf(f, "#stage\trow\tneed\tK\tentry\n");
      if (rowO) fprintf(f, "opaque\t%s\t%d\t%d\t%s\n", rowO->row, needO, rowO->K, rowO->entry);
      if (rowS) fprintf(f, "span\t%s\t%d\t%d\t%s\n", rowS->row, needS, rowS->K, rowS->entry);
      for (int i = 0; i < nplan; i++)
        fprintf(f, "%s%d\t%s\t%d\t%d\t%s\n", plan[i].fuzz ? "fuzz" : "masked", i,
                rowM[i]->row, mbatch_max_k(mj, nmasked, &plan[i], W), rowM[i]->K,
                rowM[i]->entry);
      fclose(f);
    }
  }
  Ks = Kloc;


  /* opaque / span slots */
  size_t wkO = (size_t)W * (size_t)Ks[S_OPAQUE], wkS = (size_t)H * (size_t)Ks[S_SPAN];
  uint32_t *slotO = malloc(wkO * NPLANE * 4), *slotS = malloc(wkS * NPLANE * 4);
  int mkO = 0, mkS = 0;
  if (do_opaque && build_slots(wj, nwall, nwall, W, Ks[S_OPAQUE], slotO, &mkO)) {
    fprintf(stderr, "raster_run: check #13 violated building opaque slots (K=%d)\n", Ks[S_OPAQUE]);
    return 3;
  }
  if (do_span && build_slots(sj, nspan, nspan, H, Ks[S_SPAN], slotS, &mkS)) {
    fprintf(stderr, "raster_run: check #10 violated building span slots (K=%d)\n", Ks[S_SPAN]);
    return 3;
  }
  size_t wkM = (size_t)W * (size_t)40, wkF = (size_t)W * (size_t)Ks[S_FUZZ];
  uint32_t *slotM = malloc((wkM > wkF ? wkM : wkF) * NPLANE * 4);
  t_slots = now_ms() - t0;

  if (plan_out) {
    FILE *f = fopen(plan_out, "w");
    fprintf(f, "#batch\tfuzz\tlo\thi\tslot\tnjob\tmax_k\n");
    for (int i = 0; i < nplan; i++) {
      int nj = 0, mk = 0;
      build_mbatch_slots(mj, nmasked, newofs, &plan[i], W,
                         plan[i].fuzz ? Ks[S_FUZZ] : Ks[S_MASKED], slotM, &nj, &mk);
      fprintf(f, "%d\t%d\t%d\t%d\t%d\t%d\t%d\n", i, plan[i].fuzz, plan[i].lo,
              plan[i].hi, plan[i].slot, nj, mk);
    }
    fclose(f);
  }

  /* ---------------------------------------------------------- device scope */
  double t_open0 = now_ms();
  if (sp_r_open(vmfb, device) != 0) {
    fprintf(stderr, "raster_run: sp_r_open: %s\n", sp_r_last_error());
    /* The load-time refusal (E030 s5 INCOMPATIBLE) is a REJECT like any other:
     * report it on stdout in the same shape the dispatch path uses, so the
     * reject suite does not have to read exit codes (which also fire for a
     * missing argument -- that mistake was actually made). */
    if (want_fail) { printf("REJECT\t%s\t%s\n", tag, sp_r_last_error()); return 0; }
    return 4;
  }
  int64_t hcm = sp_r_alloc((int64_t)cmap_n, 0, 1, SP_R_I8);
  int64_t hat = sp_r_alloc((int64_t)atlas_n, 0, 1, SP_R_I8);
  int64_t hfl = sp_r_alloc((int64_t)flat_n, 0, 1, SP_R_I8);
  int64_t hwn = sp_r_alloc((int64_t)WIN_BYTES, 0, 1, SP_R_I8);
  int64_t hfo = sp_r_alloc((int64_t)FUZZOFF_N, 0, 1, SP_R_I8);
  int64_t hjO = sp_r_alloc((int64_t)(wkO * NPLANE), 0, 1, SP_R_I32);
  int64_t hjS = sp_r_alloc((int64_t)(wkS * NPLANE), 0, 1, SP_R_I32);
  int64_t hjM = sp_r_alloc((int64_t)(wkM * NPLANE), 0, 1, SP_R_I32);
  int64_t hjF = sp_r_alloc((int64_t)(wkF * NPLANE), 0, 1, SP_R_I32);
  /* ★ E071: with runtime K selection there is ONE SLOT BUFFER PER TABLE ROW.
   * The shim checks that the buffer holds EXACTLY slotdim*K*6 i32 (E070's guard
   * that caught `span_dispatch_k_table`); handing it an oversized buffer and
   * uploading a prefix would defeat that check, so we keep it honest and pay
   * ~1 MB for all seven rows. */
  int64_t hjr[MAX_ENTRIES];
  for (int i = 0; i < g_nent; i++) {
    int sd = strcmp(g_ent[i].kind, "span") == 0 ? H : W;
    hjr[i] = sp_r_alloc((int64_t)((size_t)sd * g_ent[i].K * NPLANE), 0, 1, SP_R_I32);
  }
  int64_t hbg = sp_r_alloc(H, W, 2, SP_R_I8);
  int nstage = (do_opaque ? 1 : 0) + (do_span ? 1 : 0) + nplan;
  if (nstage < 1) nstage = 1;
  int64_t hfb[MAX_BATCH + 4];
  for (int i = 0; i < nstage; i++) hfb[i] = sp_r_alloc(H, W, 2, SP_R_I8);
  if (!hcm || !hbg || !hwn || !hfo || !hjM) {
    fprintf(stderr, "raster_run: alloc: %s\n", sp_r_last_error());
    return 4;
  }
  if (sp_r_h2d(hcm, cmap, cmap_n) != 0 || sp_r_h2d(hat, atlas, atlas_n) != 0 ||
      sp_r_h2d(hfl, flat, flat_n) != 0 ||
      sp_r_h2d(hfo, foff, foff_n < FUZZOFF_N ? foff_n : FUZZOFF_N) != 0) {
    fprintf(stderr, "raster_run: resident h2d: %s\n", sp_r_last_error());
    return 4;
  }
  unsigned char *zero = calloc((size_t)H * W, 1);
  unsigned char *fb = malloc((size_t)H * W);
  double t_open = now_ms() - t_open0;

  int64_t a_before = sp_r_counter(C_ALLOC);
  double t_h2d = 0, t_disp = 0, t_d2h = 0, best = 1e30;
  int ndisp = 0, rc = 0;
  for (int r = 0; r < reps; r++) {
    double q0 = now_ms();
    if (sp_r_h2d(hbg, zero, (size_t)H * W) != 0) return 4;
    if (!autok && do_opaque && sp_r_h2d(hjO, slotO, wkO * NPLANE * 4) != 0) return 4;
    if (!autok && do_span && sp_r_h2d(hjS, slotS, wkS * NPLANE * 4) != 0) return 4;
    /* the window atlas: only the used prefix moves, the capacity is resident */
    if (nwin && sp_r_h2d(hwn, win, (size_t)nwin * WIN_STRIDE) != 0) return 4;
    double q1 = now_ms();
    int st = 0;
    ndisp = 0;
    if (do_opaque) {
      int64_t hj = rowO ? hjr[rowO - g_ent] : hjO;
      if (rowO && sp_r_h2d(hj, slotO, wkO * NPLANE * 4) != 0) return 4;
      rc = sp_r_dispatch_gather(rowO ? rowO->row : "opaque_columns_k16",
                                rowO ? rowO->ksig : ksigs[S_OPAQUE],
                                rowO ? rowO->entry : entries[S_OPAQUE],
                                hj, hat, hcm, hbg, hfb[st], W, H, Ks[S_OPAQUE], W);
      if (rc) goto disp_fail;
      st++; ndisp++;
    }
    if (do_span) {
      char row[64];
      snprintf(row, sizeof row, "plane_spans_k%d", Ks[S_SPAN]);
      int64_t hjs = rowS ? hjr[rowS - g_ent] : hjS;
      if (rowS && sp_r_h2d(hjs, slotS, wkS * NPLANE * 4) != 0) return 4;
      rc = sp_r_dispatch_gather(rowS ? rowS->row : row,
                                rowS ? rowS->ksig : ksigs[S_SPAN],
                                rowS ? rowS->entry : entries[S_SPAN], hjs, hfl, hcm,
                                st ? hfb[st - 1] : hbg, hfb[st], W, H, Ks[S_SPAN], H);
      if (rc) goto disp_fail;
      st++; ndisp++;
    }
    for (int i = 0; i < nplan; i++) {
      int nj = 0, mk = 0;
      int K = autok ? rowM[i]->K : (plan[i].fuzz ? Ks[S_FUZZ] : Ks[S_MASKED]);
      int over = build_mbatch_slots(mj, nmasked, newofs, &plan[i], W, K, slotM, &nj, &mk);
      if (over) {
        fprintf(stderr, "raster_run: check #%d violated in masked batch %d "
                        "(K=%d, max_k=%d)\n", plan[i].fuzz ? 14 : 12, i, K, mk);
        return 3;
      }
      int64_t hj = autok ? hjr[rowM[i] - g_ent] : (plan[i].fuzz ? hjF : hjM);
      if (sp_r_h2d(hj, slotM, (size_t)W * K * NPLANE * 4) != 0) return 4;
      char row[64];
      if (plan[i].fuzz) snprintf(row, sizeof row, "fuzz_columns_k%d", K);
      else snprintf(row, sizeof row, "masked_columns_k%d", K);
      rc = sp_r_dispatch_gather(autok ? rowM[i]->row : row,
                                autok ? rowM[i]->ksig
                                      : ksigs[plan[i].fuzz ? S_FUZZ : S_MASKED],
                                autok ? rowM[i]->entry
                                      : entries[plan[i].fuzz ? S_FUZZ : S_MASKED], hj,
                                plan[i].fuzz ? hfo : hwn, hcm,
                                st ? hfb[st - 1] : hbg, hfb[st], W, H, K, W);
      if (rc) goto disp_fail;
      st++; ndisp++;
    }
    double q2 = now_ms();
    if (st == 0) { fprintf(stderr, "raster_run: nothing to dispatch\n"); return 3; }
    if (sp_r_d2h(hfb[st - 1], fb, (size_t)H * W) != 0) return 4;
    double q3 = now_ms();
    if (r == 0 || q3 - q0 < best) best = q3 - q0;
    t_h2d += q1 - q0; t_disp += q2 - q1; t_d2h += q3 - q2;
    continue;
disp_fail:
    fprintf(stderr, "raster_run: dispatch: %s\n", sp_r_last_error());
    if (want_fail) { printf("REJECT\t%s\t%s\n", tag, sp_r_last_error()); return 0; }
    return 5;
  }
  if (want_fail) { printf("NOT-REJECTED\t%s\tthe dispatch went through\n", tag); return 6; }
  int64_t a_after = sp_r_counter(C_ALLOC);

  long cmp_n = -1, cmp_diff = -1;
  snprintf(path, sizeof path, "%s/%s", jobs_dir, oracle_name);
  FILE *of = fopen(path, "rb");
  if (of) {
    size_t sw = (size_t)meta_get(jobs_dir, "screen_w");
    size_t vwx = (size_t)meta_get(jobs_dir, "viewwindowx");
    size_t vwy = (size_t)meta_get(jobs_dir, "viewwindowy");
    fseek(of, 0, SEEK_END);
    size_t on = (size_t)ftell(of);
    fseek(of, 0, SEEK_SET);
    unsigned char *oracle = malloc(on);
    if (fread(oracle, 1, on, of) != on) { fprintf(stderr, "short oracle\n"); return 2; }
    cmp_n = 0; cmp_diff = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
        size_t oi = (size_t)(y + vwy) * sw + (size_t)x + vwx;
        cmp_n++;
        if (oi < on && oracle[oi] != fb[(size_t)y * W + x]) cmp_diff++;
      }
    free(oracle);
    fclose(of);
  }
  if (fb_out) {
    FILE *f = fopen(fb_out, "wb");
    size_t sw = (size_t)meta_get(jobs_dir, "screen_w");
    size_t sh = (size_t)meta_get(jobs_dir, "screen_h");
    size_t vwx = (size_t)meta_get(jobs_dir, "viewwindowx");
    size_t vwy = (size_t)meta_get(jobs_dir, "viewwindowy");
    unsigned char *scr = calloc(sw * sh, 1);
    for (int y = 0; y < H; y++)
      memcpy(scr + (size_t)(y + vwy) * sw + vwx, fb + (size_t)y * W, (size_t)W);
    fwrite(scr, 1, sw * sh, f);
    free(scr);
    fclose(f);
  }

  const char *hdr = "#tag\tdevice\tW\tH\tK\tnjob\tmax_k\tpx\tdiff\tverdict\treps\t"
                    "ms_best\tms_h2d\tms_dispatch\tms_d2h\tms_slots\tms_open\t"
                    "alloc_in_loop\th2d\td2h\tinvoke\tbg_clobbered\t"
                    "kind\tnstage\tK2\tnjob2\tmax_k2\tnwin\tnbatch\n";
  char row[1024];
  snprintf(row, sizeof row,
           "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%ld\t%ld\t%s\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t"
           "%.4f\t%.4f\t%lld\t%lld\t%lld\t%lld\t%d\t%s\t%d\t%d\t%d\t%d\t%d\t%d\n",
           tag, device, W, H, Ks[S_MASKED], nmasked, mkO, cmp_n, cmp_diff,
           cmp_diff == 0 ? "BITWISE" : (cmp_diff < 0 ? "NO-ORACLE" : "DIFFERS"),
           reps, best, t_h2d / reps, t_disp / reps, t_d2h / reps, t_slots, t_open,
           (long long)(a_after - a_before), (long long)sp_r_counter(C_H2D),
           (long long)sp_r_counter(C_D2H), (long long)sp_r_counter(C_INVOKE), 1,
           kind, ndisp, Ks[S_SPAN], nspan, mkS, nwin, nplan);
  fputs(hdr, stdout);
  fputs(row, stdout);
  if (tsv) { FILE *f = fopen(tsv, "a"); if (f) { fputs(row, f); fclose(f); } }
  sp_r_close();
  return cmp_diff > 0 ? 1 : 0;
}

int main(int argc, char **argv) {
  const char *vmfb = NULL, *entry = NULL, *device = "local-sync", *jobs_dir = NULL;
  const char *slots_out = NULL, *fb_out = NULL, *tsv = NULL, *tag = "run";
  const char *slots_in = NULL, *oracle_name = NULL, *kind = "wall";
  const char *entry2 = NULL;
  int njob_limit = -1;
  const char *e3 = NULL, *e4 = NULL, *plan_out = NULL, *ksel_out = NULL;
  int autok = 0;
  uint64_t ksig = 0, ksig2 = 0, k3 = 0, k4 = 0;
  int W = 320, H = 168, K = 16, K2 = 16, K3 = 8, reps = 1, want_fail = 0;

  for (int i = 1; i < argc; i++) {
#define ARG(name) (strcmp(argv[i], name) == 0 && i + 1 < argc)
    if (ARG("--vmfb")) vmfb = argv[++i];
    else if (ARG("--entry")) entry = argv[++i];
    else if (ARG("--ksig")) ksig = strtoull(argv[++i], NULL, 16);
    else if (ARG("--entry2")) entry2 = argv[++i];
    else if (ARG("--ksig2")) ksig2 = strtoull(argv[++i], NULL, 16);
    else if (ARG("--entry3")) e3 = argv[++i];
    else if (ARG("--ksig3")) k3 = strtoull(argv[++i], NULL, 16);
    else if (ARG("--K3")) K3 = atoi(argv[++i]);
    else if (ARG("--entry4")) e4 = argv[++i];
    else if (ARG("--ksig4")) k4 = strtoull(argv[++i], NULL, 16);
    else if (ARG("--plan-out")) plan_out = argv[++i];
    else if (ARG("--entries")) { if (load_entries(argv[++i]) < 0) return 2; autok = 1; }
    else if (ARG("--ksel-out")) ksel_out = argv[++i];
    else if (ARG("--kind")) kind = argv[++i];
    else if (ARG("--device")) device = argv[++i];
    else if (ARG("--jobs")) jobs_dir = argv[++i];
    else if (ARG("--slots-in")) slots_in = argv[++i];
    else if (ARG("--slots-out")) slots_out = argv[++i];
    else if (ARG("--fb-out")) fb_out = argv[++i];
    else if (ARG("--tsv")) tsv = argv[++i];
    else if (ARG("--tag")) tag = argv[++i];
    else if (ARG("--W")) W = atoi(argv[++i]);
    else if (ARG("--H")) H = atoi(argv[++i]);
    else if (ARG("--K")) K = atoi(argv[++i]);
    else if (ARG("--K2")) K2 = atoi(argv[++i]);
    else if (ARG("--reps")) reps = atoi(argv[++i]);
    else if (ARG("--njob")) njob_limit = atoi(argv[++i]);
    else if (ARG("--oracle")) oracle_name = argv[++i];
    else if (strcmp(argv[i], "--expect-reject") == 0) want_fail = 1;
    else { fprintf(stderr, "raster_run: bad argument %s\n", argv[i]); return 2; }
#undef ARG
  }
  if (!vmfb || !entry || !jobs_dir) {
    fprintf(stderr, "usage: raster_run --vmfb F --entry N --ksig H --jobs DIR ...\n");
    return 2;
  }

  /* ★ E071: the masked / fuzz / full-screen path is its own driver. */
  if (strcmp(kind, "opaque") == 0 || strcmp(kind, "masked") == 0 ||
      strcmp(kind, "full") == 0) {
    const char *entries4[4] = {entry, entry2, e3, e4};
    uint64_t ksigs4[4] = {ksig, ksig2, k3, k4};
    int Ks4[4] = {K, K2, K3, 1};
    if (!oracle_name)
      oracle_name = strcmp(kind, "opaque") == 0 ? "opaquefb.bin"
                  : (strcmp(kind, "masked") == 0
                     ? (njob_limit >= 0 ? "mfb_one.bin" : "mfb_all.bin")
                     : "stagedfb.bin");
    return run_e071(kind, vmfb, device, jobs_dir, entries4, ksigs4, Ks4, W, H,
                    reps, oracle_name, fb_out, tsv, tag, want_fail, njob_limit,
                    plan_out, autok, ksel_out);
  }

  /* ------------------------------------------------------- what to dispatch */
  static const stage_def_t WALL_STAGE = {
      "wall0_soa.bin", "wall_phase0_n", "atlas.bin", "wall_columns", 0};
  static const stage_def_t SPAN_STAGE = {
      "span1_soa.bin", "nspan", "flat.bin", NULL /* filled in: plane_spans_k%d */, 1};
  stage_def_t sd[2];
  int Ks[2] = {K, K2};
  const char *entries[2] = {entry, entry2};
  uint64_t ksigs[2] = {ksig, ksig2};
  int nstage;
  char span_kind[64];

  if (strcmp(kind, "wall") == 0) {
    nstage = 1; sd[0] = WALL_STAGE;
    if (!oracle_name) oracle_name = "wallfb_all.bin";
  } else if (strcmp(kind, "span") == 0) {
    nstage = 1; sd[0] = SPAN_STAGE;
    snprintf(span_kind, sizeof span_kind, "plane_spans_k%d", K);
    sd[0].table_kind = span_kind;
    if (!oracle_name) oracle_name = "spanfb_all.bin";
  } else if (strcmp(kind, "both") == 0) {
    /* ★ the composite: wall stage then span stage, over one framebuffer that
     * never leaves the device (E070 s3.5).  The CPU oracle is compfb.bin =
     * JobExecutor#run_sel(jobs, fb, wall0=1, span=1, masked=0). */
    nstage = 2; sd[0] = WALL_STAGE; sd[1] = SPAN_STAGE;
    snprintf(span_kind, sizeof span_kind, "plane_spans_k%d", K2);
    sd[1].table_kind = span_kind;
    if (!entry2) { fprintf(stderr, "raster_run: --kind both needs --entry2/--ksig2\n"); return 2; }
    if (!oracle_name) oracle_name = "compfb.bin";
  } else {
    fprintf(stderr, "raster_run: --kind must be wall, span or both\n");
    return 2;
  }

  char path[1024];
  size_t nb;
  snprintf(path, sizeof path, "%s/cmap.bin", jobs_dir);
  void *cmap = slurp(path, &nb);
  size_t cmap_n = nb;

  void *res[2] = {NULL, NULL};
  size_t res_n[2] = {0, 0};
  uint32_t *slots[2] = {NULL, NULL};
  size_t slotv[2] = {0, 0};
  int njob[2] = {0, 0}, max_k[2] = {0, 0}, slotdim[2] = {0, 0};
  double t_slots = 0;

  for (int s = 0; s < nstage; s++) {
    snprintf(path, sizeof path, "%s/%s", jobs_dir, sd[s].res_file);
    res[s] = slurp(path, &res_n[s]);
    snprintf(path, sizeof path, "%s/%s", jobs_dir, sd[s].jobs_file);
    uint32_t *jb = slurp(path, &nb);
    int n_all = (int)meta_get(jobs_dir, sd[s].njob_key);
    /* --njob N takes the FIRST N jobs in issue order.  N=1 is the completion
     * condition "a single column / a single span is bit-exact" (P005 Phase 3/4);
     * the oracle for it is wallfb_one.bin / spanfb_one.bin, which the same Job
     * IR executor drew from job 0 alone. */
    njob[s] = n_all;
    if (njob_limit >= 0 && njob_limit < njob[s]) njob[s] = njob_limit;
    slotdim[s] = sd[s].slot_axis ? H : W;
    size_t wk = (size_t)slotdim[s] * (size_t)Ks[s];
    slotv[s] = wk * NPLANE;
    slots[s] = malloc(slotv[s] * sizeof(uint32_t));
    if (slots_in && nstage == 1) {
      /* the scale>1 perf variant: the slots were built by spinel-rastergen */
      size_t sn;
      void *p = slurp(slots_in, &sn);
      if (sn != slotv[s] * 4) {
        fprintf(stderr, "raster_run: %s is %zu B, expected %zu\n", slots_in, sn,
                slotv[s] * 4);
        return 2;
      }
      memcpy(slots[s], p, sn);
      free(p);
    } else {
      double t0 = now_ms();
      int over = build_slots(jb, njob[s], n_all, slotdim[s], Ks[s], slots[s], &max_k[s]);
      t_slots += now_ms() - t0;
      if (over) {
        fprintf(stderr, "raster_run: check #%d violated while building %s slots "
                        "(K=%d, njob=%d)\n",
                over > 0 ? (sd[s].slot_axis ? 10 : 5) : 1, sd[s].table_kind,
                Ks[s], njob[s]);
        return 3;
      }
    }
    free(jb);
    if (slots_out && s == 0) {
      FILE *f = fopen(slots_out, "wb");
      fwrite(slots[s], 1, slotv[s] * 4, f);
      fclose(f);
    }
  }

  /* ---------------------------------------------------------- device scope */
  double t_open0 = now_ms();
  if (sp_r_open(vmfb, device) != 0) {
    fprintf(stderr, "raster_run: sp_r_open: %s\n", sp_r_last_error());
    return want_fail ? 0 : 4;
  }
  int64_t hcm = sp_r_alloc((int64_t)cmap_n, 0, 1, SP_R_I8);
  int64_t hres[2] = {0, 0}, hjob[2] = {0, 0};
  for (int s = 0; s < nstage; s++) {
    hres[s] = sp_r_alloc((int64_t)res_n[s], 0, 1, SP_R_I8);
    hjob[s] = sp_r_alloc((int64_t)slotv[s], 0, 1, SP_R_I32);
  }
  int64_t hbg = sp_r_alloc(H, W, 2, SP_R_I8);
  int64_t hfb[2] = {0, 0};
  for (int s = 0; s < nstage; s++) hfb[s] = sp_r_alloc(H, W, 2, SP_R_I8);
  if (!hcm || !hbg) {
    fprintf(stderr, "raster_run: alloc: %s\n", sp_r_last_error());
    return 4;
  }
  for (int s = 0; s < nstage; s++)
    if (!hres[s] || !hjob[s] || !hfb[s]) {
      fprintf(stderr, "raster_run: alloc: %s\n", sp_r_last_error());
      return 4;
    }
  /* RESIDENT: uploaded once, outside the loop. */
  if (sp_r_h2d(hcm, cmap, cmap_n) != 0) {
    fprintf(stderr, "raster_run: resident h2d: %s\n", sp_r_last_error());
    return 4;
  }
  for (int s = 0; s < nstage; s++)
    if (sp_r_h2d(hres[s], res[s], res_n[s]) != 0) {
      fprintf(stderr, "raster_run: resident h2d: %s\n", sp_r_last_error());
      return 4;
    }
  unsigned char *zero = calloc((size_t)H * W, 1);
  unsigned char *fb = malloc((size_t)H * W);
  unsigned char *bgchk = malloc((size_t)H * W);
  double t_open = now_ms() - t_open0;

  int64_t a_before = sp_r_counter(C_ALLOC);
  double t_h2d = 0, t_disp = 0, t_d2h = 0, best = 1e30;
  int rc = 0;
  for (int r = 0; r < reps; r++) {
    double t0 = now_ms();
    if (sp_r_h2d(hbg, zero, (size_t)H * W) != 0) {
      fprintf(stderr, "raster_run: frame h2d: %s\n", sp_r_last_error());
      return 4;
    }
    for (int s = 0; s < nstage; s++)
      if (sp_r_h2d(hjob[s], slots[s], slotv[s] * 4) != 0) {
        fprintf(stderr, "raster_run: frame h2d: %s\n", sp_r_last_error());
        return 4;
      }
    double t1 = now_ms();
    /* ★ the framebuffer is threaded through the stages ON THE DEVICE: stage 0
     * writes hfb[0] from the zeroed background, stage 1 takes hfb[0] as its
     * background and writes hfb[1].  No copy, no readback in between. */
    for (int s = 0; s < nstage; s++) {
      int64_t bg = s == 0 ? hbg : hfb[s - 1];
      rc = sp_r_dispatch_gather(sd[s].table_kind, ksigs[s], entries[s], hjob[s],
                                hres[s], hcm, bg, hfb[s], W, H, Ks[s], slotdim[s]);
      if (rc != 0) {
        fprintf(stderr, "raster_run: dispatch: %s\n", sp_r_last_error());
        if (want_fail) { printf("REJECT\t%s\t%s\n", tag, sp_r_last_error()); return 0; }
        return 5;
      }
    }
    double t2 = now_ms();
    if (sp_r_d2h(hfb[nstage - 1], fb, (size_t)H * W) != 0) {
      fprintf(stderr, "raster_run: d2h: %s\n", sp_r_last_error());
      return 4;
    }
    double t3 = now_ms();
    if (r == 0 || t3 - t0 < best) best = t3 - t0;
    t_h2d += t1 - t0;
    t_disp += t2 - t1;
    t_d2h += t3 - t2;
  }
  if (want_fail) {
    printf("NOT-REJECTED\t%s\tthe dispatch went through\n", tag);
    return 6;
  }
  int64_t a_after = sp_r_counter(C_ALLOC);

  /* Hypothesis 4 (R009 s10): did IREE tie the operand and write into bg? */
  int bg_clobbered = -1;
  if (sp_r_d2h(hbg, bgchk, (size_t)H * W) == 0) {
    bg_clobbered = 0;
    for (size_t i = 0; i < (size_t)H * W; i++)
      if (bgchk[i] != 0) { bg_clobbered = 1; break; }
  }

  /* ------------------------------------------------------------- oracle */
  long cmp_n = -1, cmp_diff = -1;
  snprintf(path, sizeof path, "%s/%s", jobs_dir, oracle_name);
  FILE *of = fopen(path, "rb");
  if (of && (size_t)W == (size_t)meta_get(jobs_dir, "view_w")) {
    size_t sw = (size_t)meta_get(jobs_dir, "screen_w");
    size_t vwx = (size_t)meta_get(jobs_dir, "viewwindowx");
    size_t vwy = (size_t)meta_get(jobs_dir, "viewwindowy");
    fseek(of, 0, SEEK_END);
    size_t on = (size_t)ftell(of);
    fseek(of, 0, SEEK_SET);
    unsigned char *oracle = malloc(on);
    if (fread(oracle, 1, on, of) != on) { fprintf(stderr, "short oracle\n"); return 2; }
    cmp_n = 0;
    cmp_diff = 0;
    for (int y = 0; y < H; y++)
      for (int x = 0; x < W; x++) {
        size_t oi = (size_t)(y + vwy) * sw + (size_t)x + vwx;
        cmp_n++;
        if (oi < on && oracle[oi] != fb[(size_t)y * W + x]) cmp_diff++;
      }
    free(oracle);
    fclose(of);
  }

  if (fb_out) {
    FILE *f = fopen(fb_out, "wb");
    /* ★ the composite writes a full 320x200 screen so that the CPU can paint
     * the masked stage on top of it (the hybrid oracle of E070 s3.6).  The
     * view rectangle is placed exactly where the executor would have put it. */
    size_t sw = (size_t)meta_get(jobs_dir, "screen_w");
    size_t sh = (size_t)meta_get(jobs_dir, "screen_h");
    if ((size_t)W == (size_t)meta_get(jobs_dir, "view_w")) {
      size_t vwx = (size_t)meta_get(jobs_dir, "viewwindowx");
      size_t vwy = (size_t)meta_get(jobs_dir, "viewwindowy");
      unsigned char *scr = calloc(sw * sh, 1);
      for (int y = 0; y < H; y++)
        memcpy(scr + (size_t)(y + vwy) * sw + vwx, fb + (size_t)y * W, (size_t)W);
      fwrite(scr, 1, sw * sh, f);
      free(scr);
    } else {
      fwrite(fb, 1, (size_t)H * W, f);
    }
    fclose(f);
  }

  const char *hdr = "#tag\tdevice\tW\tH\tK\tnjob\tmax_k\tpx\tdiff\tverdict\treps\t"
                    "ms_best\tms_h2d\tms_dispatch\tms_d2h\tms_slots\tms_open\t"
                    "alloc_in_loop\th2d\td2h\tinvoke\tbg_clobbered\t"
                    "kind\tnstage\tK2\tnjob2\tmax_k2\n";
  char row[1024];
  snprintf(row, sizeof row,
           "%s\t%s\t%d\t%d\t%d\t%d\t%d\t%ld\t%ld\t%s\t%d\t%.4f\t%.4f\t%.4f\t%.4f\t"
           "%.4f\t%.4f\t%lld\t%lld\t%lld\t%lld\t%d\t%s\t%d\t%d\t%d\t%d\n",
           tag, device, W, H, K, njob[0], max_k[0], cmp_n, cmp_diff,
           cmp_diff == 0 ? "BITWISE" : (cmp_diff < 0 ? "NO-ORACLE" : "DIFFERS"),
           reps, best, t_h2d / reps, t_disp / reps, t_d2h / reps, t_slots, t_open,
           (long long)(a_after - a_before), (long long)sp_r_counter(C_H2D),
           (long long)sp_r_counter(C_D2H), (long long)sp_r_counter(C_INVOKE),
           bg_clobbered, kind, nstage, nstage > 1 ? K2 : 0,
           nstage > 1 ? njob[1] : 0, nstage > 1 ? max_k[1] : 0);
  fputs(hdr, stdout);
  fputs(row, stdout);
  if (tsv) {
    FILE *f = fopen(tsv, "a");
    if (f) { fputs(row, f); fclose(f); }
  }
  sp_r_close();
  return cmp_diff > 0 ? 1 : 0;
}
