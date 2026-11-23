/* tools/gcviz/gcviz_mark.c -- binds the Ruby method gcviz_mark(id) to the
 * events runtime's mark (vendor lib/sp_slab.c, SP_GC_EVENTS). Patch 1
 * (SPINEL_EXTERN_METHODS) compiles `gcviz_mark` as a call to
 * `sp_int sp_gcviz_mark(sp_int)`, and sp_int is intptr_t. */
#include <stdint.h>
void sp_gc_events_mark(long id);
intptr_t sp_gcviz_mark(intptr_t id) {
  sp_gc_events_mark((long)id);
  return id;
}
