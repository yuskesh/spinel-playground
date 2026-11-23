/* examples/doom/native/sp_rg_stub.c — the no-device answer for the GPU raster
 * interface that lib/doom/render_gpu.rb declares.
 *
 * render_gpu.rb declares nine `ffi_func`s, so every program whose closure
 * reaches it -- bin/doom.rb does -- needs those nine symbols at link time even
 * when nothing will ever call them.  This provides them and no more.  It pulls
 * in no IREE, no GPU kernels and no MLIR: decision 0006's task 4 is a CPU
 * import, and a stub that dragged in a device stack would defeat the point of
 * being a stub.
 *
 * The contract render_gpu.rb relies on is that `sp_rg_available()` answers 0,
 * at which point the Ruby side takes its CPU path and never calls the rest.
 * The rest are present, fail, and say why -- rather than being absent and
 * turning a mistaken call into a link error, or present and silently doing
 * nothing, which would look like a working device that renders black.
 *
 * On the diagnostic: it says this build has no GPU backend and stops there.  It
 * deliberately does NOT tell the reader to run some GPU build recipe -- Spinel
 * Extended has no such recipe, and a message naming one would send whoever read
 * it looking for something that does not exist.  The predecessor's shim was
 * written against an IREE experiment that is not imported here.
 */

#include <stddef.h>
#include <stdint.h>

static const char *SP_RG_NO_DEVICE =
    "no GPU raster backend in this build: examples/doom is the CPU import "
    "(decision 0006 task 4), and sp_rg_available() answers 0 so the renderer "
    "takes its CPU path";

int      sp_rg_available(void)   { return 0; }
const char *sp_rg_error(void)    { return SP_RG_NO_DEVICE; }
void     sp_rg_close(void)       { }
void     sp_rg_counters_reset(void) { }
int64_t  sp_rg_counter(int which) { (void)which; return 0; }

/* Failure is -1 for the int-returning entry points, which is what render_gpu.rb
 * treats as "did not happen"; sp_rg_error() then carries the text. */
int sp_rg_open(const char *a, const char *b, const char *c)
{
    (void)a; (void)b; (void)c;
    return -1;
}

int sp_rg_geometry(int a, int b, int c, int d, int e, int f)
{
    (void)a; (void)b; (void)c; (void)d; (void)e; (void)f;
    return -1;
}

int sp_rg_resident(const char *a, size_t an, const char *b, size_t bn,
                   const char *c, size_t cn, const char *d, size_t dn)
{
    (void)a; (void)an; (void)b; (void)bn;
    (void)c; (void)cn; (void)d; (void)dn;
    return -1;
}

/* The prototypes are taken from the generated C itself rather than transcribed
 * from render_gpu.rb's ffi_func list: sp_rg_frame has three (int64_t*, size_t)
 * banks followed by three (const char*, size_t) buffers, which is twelve
 * parameters, and reading the declaration is how that is got right. */
int sp_rg_frame(const int64_t *a, size_t an, const int64_t *b, size_t bn,
                const int64_t *c, size_t cn, const char *d, size_t dn,
                const char *e, size_t en, const char *f, size_t fn)
{
    (void)a; (void)an; (void)b; (void)bn; (void)c; (void)cn;
    (void)d; (void)dn; (void)e; (void)en; (void)f; (void)fn;
    return -1;
}
