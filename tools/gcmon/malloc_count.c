/* malloc_count.c — counts malloc/calloc/realloc/free calls by DYLD
 * interposition (macOS only). SPINEL_ALLOC_REPORT counts only GC-heap objects
 * and misses direct mallocs such as an Array's element storage, so a claim of
 * zero allocation in a frame loop needs this counter as well.
 *   $CC -dynamiclib -o malloc_count.dylib malloc_count.c
 *   DYLD_INSERT_LIBRARIES=./malloc_count.dylib ./app
 * At exit it writes "mallocs=N callocs=N reallocs=N frees=N bytes=N" to
 * R007_MALLOC_REPORT, or to stderr when that is unset.
 *
 * Imported from spinel-llvm docs/researches/r007_probes/malloc_count.c
 * (docs/provenance.md); only this comment is changed. */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static long n_malloc, n_calloc, n_realloc, n_free, n_bytes;

#define DYLD_INTERPOSE(_repl, _repl_ee) \
  __attribute__((used)) static struct { const void *repl; const void *repl_ee; } \
  _interpose_##_repl __attribute__((section("__DATA,__interpose"))) = \
  { (const void *)(unsigned long)&_repl, (const void *)(unsigned long)&_repl_ee };

static void *my_malloc(size_t n)  { n_malloc++;  n_bytes += n; return malloc(n); }
static void *my_calloc(size_t a, size_t b) { n_calloc++; n_bytes += a*b; return calloc(a,b); }
static void *my_realloc(void *p, size_t n) { n_realloc++; n_bytes += n; return realloc(p,n); }
static void  my_free(void *p) { if (p) n_free++; free(p); }

DYLD_INTERPOSE(my_malloc, malloc)
DYLD_INTERPOSE(my_calloc, calloc)
DYLD_INTERPOSE(my_realloc, realloc)
DYLD_INTERPOSE(my_free, free)

__attribute__((destructor)) static void report(void) {
  const char *f = getenv("R007_MALLOC_REPORT");
  FILE *o = stderr;
  if (f && *f) { FILE *g = fopen(f, "w"); if (g) o = g; }
  fprintf(o, "mallocs=%ld callocs=%ld reallocs=%ld frees=%ld bytes=%ld\n",
          n_malloc, n_calloc, n_realloc, n_free, n_bytes);
  if (o != stderr) fclose(o);
}
