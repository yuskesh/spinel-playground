/* tools/wasm/stubs.c -- libc facilities wasm32-wasip1 does not have.
   Originally copied from docs/experiments/results/E009/repro/stubs.c (E009 §8).

   E012 split this file in two along the R003 §3-1 line:

     * a TRUE NO-OP may stay a stub -- the call means "do nothing" and the
       program cannot observe a return value that differs from native.
       backtrace() is the only one left here: `caller` is an empty Array on the
       native build too (R003 §3-2 measured it), so returning 0 frames is the
       same answer, not a different one.

     * anything whose ANSWER IS OBSERVED must raise.  fnmatch() used to return
       FNM_NOMATCH, which made `File.fnmatch("*.rb","a.rb")` answer *false* --
       silently the opposite of native.  It now raises a catchable Ruby
       NotImplementedError (R003 probe A); sp_raise_cls is declared in
       spinel_rt.h and defined by the generated TU, so a declaration is all
       this TU needs and the link closes against the program.

   The Ruby-level entry points (Dir.glob, File.fnmatch, Dir.home, Dir.pwd,
   sockets, Kernel#system) are wrapped in tools/wasm/raise_stubs.c; this file
   only covers the libc layer underneath them. */
#include <stddef.h>

__attribute__((noreturn)) void sp_raise_cls(const char *cls, const char *msg);

/* true no-op: native `caller` is empty too (R003 §3-2) */
int backtrace(void **buf, int sz) { (void)buf; (void)sz; return 0; }
char **backtrace_symbols(void *const *b, int n) { (void)b; (void)n; return NULL; }

/* observed answer: must not be faked.  Was `return 1;` (FNM_NOMATCH). */
int fnmatch(const char *p, const char *s, int f) {
  (void)p; (void)s; (void)f;
  sp_raise_cls("NotImplementedError",
               "File.fnmatch/Dir.glob are not available on the Cloudflare "
               "Workers target (wasm32-wasip1); fnmatch() is a stub in this "
               "profile, not an implementation");
}

/* ---- added in spinel-extended: what the pinned runtime needs that ---------
   spinel-llvm's older vendor tree (ecbd0f2a) did not call. Same rule as above:
   a true no-op may be a stub, an observed answer must not be faked, and a
   stub must keep the libc contract the caller relies on. */
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>

/* true no-op: a wasm instance has one thread, so there is no lock to take.
   The prototypes are wasi-libc's own (stdio.h), so the call sites match. */
void flockfile(FILE *f) { (void)f; }
void funlockfile(FILE *f) { (void)f; }

/* NOT a no-op for MADV_DONTNEED. lib/sp_slab.c hands a chunk back with it,
   clears the chunk's `touched` flag, and later relies on an untouched page
   reading as zero (sp_slab.c: "an untouched page reads as zero"). On Linux,
   DONTNEED on private anonymous memory gives exactly that; wasm memory cannot be
   returned, so the zeroing is done here. A plain `return 0` would hand out
   stale bytes behind a chunk the allocator believes is clean. The other
   advice values used (DONTDUMP, DODUMP, HUGEPAGE) are hints: no-ops. */
int madvise(void *addr, size_t len, int advice) {
  if (advice == MADV_DONTNEED) memset(addr, 0, len);
  return 0;
}

/* Scheduler and fiber hooks come from the regular runtime TUs. In this
 * profile no user fibers or threads can be created; marking an empty root
 * storage is still a no-op, while Thread.pass keeps upstream trap dispatch.
 * Queue/Mutex class-name refusals moved to raise_stubs.c link wrappers. */
