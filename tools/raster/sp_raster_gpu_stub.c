/* sp_raster_gpu_stub.c -- E073 (P005 Phase 6): the "no GPU backend in this
 * build" leg of the Ruby-facing raster seam.
 *
 * `doom/bin/doom.rb` declares the seam with `ffi_func`, so the symbols must
 * EXIST at link time whether or not this machine has IREE, Metal, or a device
 * at all.  Linking this TU instead of sp_raster_gpu.c gives a binary that
 *
 *   - builds with nothing but a C compiler (no IREE runtime, no frameworks),
 *   - answers `sp_rg_available() == 0`, and
 *   - refuses every call loudly, with a message that says what to do.
 *
 * That is not a mock: it is Phase 6's "device absent" case realised as a build
 * configuration, and it is why `-gpu` on a stub build is a one-line log plus a
 * CPU frame rather than a crash.  The fallback path is therefore exercised on
 * every ordinary `doom` build, not only when a GPU is missing.
 */

#include <stdint.h>
#include <stddef.h>

static const char *const MSG =
    "this binary was built without a GPU raster backend "
    "(tools/raster/sp_raster_gpu_stub.c). Rebuild with RASTER_GPU=1 "
    "doom/tools/build.sh to link the IREE seam.";

int sp_rg_available(void) { return 0; }
const char *sp_rg_error(void) { return MSG; }
int sp_rg_open(const char *v, const char *d, const char *e) {
  (void)v; (void)d; (void)e;
  return -1;
}
void sp_rg_close(void) {}
void sp_rg_counters_reset(void) {}
int sp_rg_geometry(int W, int H, int sw, int sh, int vwx, int vwy) {
  (void)W; (void)H; (void)sw; (void)sh; (void)vwx; (void)vwy;
  return -1;
}
int sp_rg_resident(const char *a, size_t na, const char *f, size_t nf,
                   const char *c, size_t nc, const char *z, size_t nz) {
  (void)a; (void)na; (void)f; (void)nf; (void)c; (void)nc; (void)z; (void)nz;
  return -1;
}
int sp_rg_frame(const int64_t *w, size_t nw, const int64_t *s, size_t ns,
                const int64_t *m, size_t nm, char *z, size_t nz,
                const char *d, size_t nd, char *fb, size_t nfb) {
  (void)w; (void)nw; (void)s; (void)ns; (void)m; (void)nm;
  (void)z; (void)nz; (void)d; (void)nd; (void)fb; (void)nfb;
  return -1;
}
int64_t sp_rg_counter(int i) { (void)i; return 0; }
