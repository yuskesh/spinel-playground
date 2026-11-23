/* tools/wasm/arena_env.c -- the arena build's defaults for the runtime's
 * environment switches.  Linked into an arena module only, with
 * `--wrap=getenv` (tools/wasm/spinel-wasm).
 *
 * The pinned runtime decides whether to use its slab allocator from
 * SPINEL_GC_SLAB when the first block is allocated (lib/sp_slab.c,
 * sp_slab_init); unset means on.  On wasi, "on" takes 64 MB of linear memory
 * with one posix_memalign (sp_slab_reserve), whether or not a collector is
 * built in.  Under the process-lifetime arena that --gc=none replaced, the
 * slab still served container payloads (sp_pl_* -> sp_slab_alloc_raw), and an
 * arena module that left it on grew to about 70 MB on its first request.
 * The vendor has no compile-time default for the switch, so the default is
 * given here: an arena module reads SPINEL_GC_SLAB as "0" unless the host
 * sets it.  An explicit setting still wins, because the wrapped getenv is
 * consulted first.
 *
 * Why off is safe without a collector: with the slab off every payload is a
 * malloc and sp_slab_free/sp_pl_realloc hand a block they do not own to
 * free/realloc (sp_slab_owns is false for every address); that is the
 * vendor's own SPINEL_GC_SLAB=0 path, which it documents and supports. */
#include <string.h>

char *__real_getenv(const char *name);

char *__wrap_getenv(const char *name) {
  char *v = __real_getenv(name);
  if (v == NULL && name != NULL && strcmp(name, "SPINEL_GC_SLAB") == 0)
    return (char *)"0";
  return v;
}
