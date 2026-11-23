/* tools/wasm/snapshot.c -- what lets a host reuse one arena module instance
 * for many requests by writing its linear memory back (decision 0039).
 * Linked into an arena command module (--request-arena, or
 * `# spinel-tier: arena`) unless --no-snapshot is given, with
 * `--wrap=sbrk --export=__stack_pointer --export=spinel_snapshot_abi`
 * (tools/wasm/spinel-wasm).
 *
 * The host's contract (tools/wasm/wasi_shim.mjs, runModule):
 *   1. Instantiate once and copy the whole linear memory before `_start` runs.
 *   2. Before each request, write the copy back, zero every byte past it, and
 *      set the exported `__stack_pointer` to the value it had at step 1.
 *   3. Enter `_start`.
 * The request then starts from the bytes and the one mutable global a new
 * instance would have.  Linear memory cannot shrink, so a module that grew in
 * an earlier request keeps its pages; step 2 zeroes them, as memory.grow would
 * have handed them out.
 *
 * Why sbrk is replaced.  wasi-libc's sbrk keeps no break of its own: it
 * answers the current memory size and grows the memory for every increment.
 * After step 2 the allocator's state (in linear memory, written back) says the
 * heap ends where the copy ends, while the memory is still as large as an
 * earlier request left it, so the stock sbrk would hand out addresses past
 * pages the allocator does not know of.  This sbrk keeps the break in linear
 * memory, so step 2 resets it with everything else, and it grows the memory
 * only when the break passes its end -- which reuses the zeroed pages first.
 * For a module that is never reused it behaves as the stock one does.
 *
 * Nothing else in such a module changes outside linear memory: the generated
 * code, the runtime and wasi-libc keep no other mutable wasm global, and a
 * command module grows no table.  tests/edge/arena.sh checks the global
 * section of a built module for that. */
#include <errno.h>
#include <stdint.h>
#include <stddef.h>

/* The end of the memory the module starts with (wasm-ld defines it). */
extern unsigned char __heap_end;

static uintptr_t sp_snapshot_brk;   /* 0 until the first call */

void *__wrap_sbrk(intptr_t increment) {
  if (!sp_snapshot_brk) sp_snapshot_brk = (uintptr_t)&__heap_end;
  uintptr_t old = sp_snapshot_brk;
  if (increment < 0 && (uintptr_t)-increment > old) { errno = EINVAL; return (void *)-1; }
  uintptr_t want = old + (uintptr_t)increment;
  uintptr_t have = (uintptr_t)__builtin_wasm_memory_size(0) * 65536u;
  if (increment > 0 && want > have) {
    size_t pages = (size_t)((want - have + 65535u) / 65536u);
    if (__builtin_wasm_memory_grow(0, pages) == (size_t)-1) { errno = ENOMEM; return (void *)-1; }
  }
  sp_snapshot_brk = want;
  return (void *)old;
}

/* The marker a host looks for before it reuses an instance: the version of the
 * contract above.  A module without it is instantiated for every request. */
int spinel_snapshot_abi(void) { return 1; }
