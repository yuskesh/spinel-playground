/* tools/wasm/reactor.c -- the --mode reactor entry point (E011 Part 2).
 *
 * A wasip1 *reactor* module has no `_start`: the host calls `_initialize`
 * (crt1-reactor.o) once at instantiation to run libc setup + C constructors,
 * and then calls exported functions as many times as it likes.  Spinel's
 * generated TU only exports `main(argc, argv)`, so the reactor entry is a
 * wrapper that calls `main` once per request with a freshly built argv.
 *
 * Calling main() from another function is legal C (it is not in C++), and
 * Spinel's main() is re-entrant *by construction* on the two axes that matter:
 *   - SP_GC_SAVE()  (lib/sp_gc.h:92) is `int __attribute__((cleanup)) _gc_saved
 *     = sp_gc_nroots`, so the root shadow-stack depth is restored on *every*
 *     exit path, including the normal `return 0` at the end of main.
 *   - sp_re_init()  (generated) only assigns hook function pointers and
 *     re-compiles the program's Regexp literals; assignments are idempotent,
 *     the re_compile is not (see results/E011/reactor_design.md §"leaks").
 *
 * ABI (all exports are wasm functions; strings live in the module's memory):
 *   sp_reactor_alloc(n)          -> ptr        malloc, for the argv blob
 *   sp_reactor_free(ptr)                       free
 *   sp_reactor_run(ptr, nargs)   -> int        argv blob = `nargs` NUL-
 *                                              terminated strings, laid out
 *                                              back to back.  Returns main()'s
 *                                              exit status.
 *   sp_reactor_calls()           -> int        how many times run() has been
 *                                              entered (probe/telemetry).
 *   sp_reactor_heap_pages()      -> int        __builtin_wasm_memory_size(0)
 *   sp_reactor_gc()                            force a full collection
 *   sp_reactor_gc_bytes()        -> double     live object-heap bytes
 *   sp_reactor_str_bytes()       -> double     live string-heap bytes
 *   sp_reactor_gc_roots()        -> int        sp_gc_nroots (must be 0 between
 *                                              calls; this is the proof that
 *                                              SP_GC_SAVE unwound)
 *
 * stdout: libc buffers it and, unlike a command module, nothing calls
 * __wasm_call_dtors on the way out -- so sp_reactor_run() fflush(NULL)s before
 * returning.  The host sees one fd_write burst per call.
 *
 * ---- what has to be reset between calls -----------------------------------
 * main() is *almost* re-entrant.  The one piece of process-lifetime state that
 * makes a second call wrong rather than merely wasteful is the ARGV cache:
 *
 *   lib/sp_cold.c:2458  sp_StrArray *sp_get_ARGV(void) {
 *                         if (!sp_argv_array_cache) { ...build from sp_argv... }
 *                         return sp_argv_array_cache; }
 *
 * main() does re-fill `sp_argv` on every entry, but the *materialized*
 * StrArray that Ruby's `ARGV` actually reads is cached forever.  Without the
 * reset below, call 2..N of a reactor silently reuse call 1's arguments (E011
 * measured exactly that: 950/1000 wrong answers, exit 0, no diagnostic).
 * sp_argv.data itself is malloc'd fresh by main() on every entry, so the
 * previous one is freed here too.
 */
#include <setjmp.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "sp_types.h"
#include "sp_gc.h"
#include "sp_alloc.h"
#include "sp_argf.h"

#define SP_REACTOR_MAX_ARGS 64

int main(int argc, char **argv);

static int sp_reactor_call_count = 0;

__attribute__((export_name("sp_reactor_alloc")))
void *sp_reactor_alloc(unsigned long n) { return malloc((size_t)n); }

__attribute__((export_name("sp_reactor_free")))
void sp_reactor_free(void *p) { free(p); }

__attribute__((export_name("sp_reactor_calls")))
int sp_reactor_calls(void) { return sp_reactor_call_count; }

__attribute__((export_name("sp_reactor_heap_pages")))
int sp_reactor_heap_pages(void) { return (int)__builtin_wasm_memory_size(0); }

__attribute__((export_name("sp_reactor_gc")))
void sp_reactor_gc(void) { sp_gc_collect_request(); }

__attribute__((export_name("sp_reactor_gc_bytes")))
double sp_reactor_gc_bytes(void) { return (double)sp_gc_bytes; }

__attribute__((export_name("sp_reactor_str_bytes")))
double sp_reactor_str_bytes(void) { return (double)(sp_str_heap_bytes + sp_str_old_bytes); }

__attribute__((export_name("sp_reactor_gc_roots")))
int sp_reactor_gc_roots(void) { return sp_gc_nroots; }

/* Drop the per-request ARGV state so the next main() rebuilds it. */
static void sp_reactor_reset_argv(void) {
  const char **old = sp_argv.data;
  sp_argv.len = 0;                 /* stop the GC root scan reading it first */
  sp_argv.data = NULL;
  free((void *)old);               /* malloc'd by the previous main() entry */
  sp_argv_array_cache = NULL;      /* the actual correctness bug (see header) */
  /* ARGF has no index of its own: it takes each file off ARGV as it opens
     it (upstream ed6c19a16), so rebuilding ARGV resets its position. */
  sp_argf_obj.cur = NULL;
  sp_argf_obj.started = 0;
  sp_argf_obj.fname = NULL;
}

/* ---- re_compile memoization (linked with --wrap=re_compile) ---------------
 * The other half of re-entering main() is sp_re_init(), which re-compiles
 * every Regexp *literal* in the program on every entry:
 *
 *   sp_re_pat_0 = re_compile("[0-9]", 5, 0);      // generated TU, `static`
 *
 * re_compile mallocs the pattern, its prefix, its source copy and two thread
 * caches (lib/regexp/re_compile.c:1585-1658) -- none of it on the GC heap, and
 * *nothing in the tree ever calls re_free*, because in a command process one
 * compile per literal is one compile per process.  In a reactor that becomes a
 * per-request leak: E011 measured ~1.1 KB per literal per call, unbounded
 * (148 pages after 8000 calls vs 17 with no literal).  The pattern pointers are
 * `static` in the generated TU, so nothing outside can free them.
 *
 * The fix that needs no vendor change: memoize on (address, length, flags,
 * bytes).  Literals live in rodata, so the address is stable across calls; the
 * memcmp keeps a recycled heap address (Regexp.new) from aliasing a stale
 * entry.  Reuse is safe because a compiled pattern is already shared across all
 * matches within one run, and nobody frees it.  Dynamic regexps beyond the
 * table size fall through to the real compiler, i.e. back to leaking. */
#define SP_REACTOR_RE_CACHE 64

typedef struct mrb_regexp_pattern mrb_regexp_pattern;
mrb_regexp_pattern *__real_re_compile(const char *pattern, mrb_int len, unsigned int flags);

static struct {
  const char *src; mrb_int len; unsigned int flags; mrb_regexp_pattern *pat;
} sp_re_memo[SP_REACTOR_RE_CACHE];
static int sp_re_memo_n = 0;

mrb_regexp_pattern *__wrap_re_compile(const char *pattern, mrb_int len, unsigned int flags) {
  for (int i = 0; i < sp_re_memo_n; i++) {
    if (sp_re_memo[i].len == len && sp_re_memo[i].flags == flags &&
        (sp_re_memo[i].src == pattern ||
         memcmp(sp_re_memo[i].src, pattern, (size_t)len) == 0)) {
      return sp_re_memo[i].pat;
    }
  }
  mrb_regexp_pattern *pat = __real_re_compile(pattern, len, flags);
  if (pat && sp_re_memo_n < SP_REACTOR_RE_CACHE) {
    sp_re_memo[sp_re_memo_n].src = pattern;
    sp_re_memo[sp_re_memo_n].len = len;
    sp_re_memo[sp_re_memo_n].flags = flags;
    sp_re_memo[sp_re_memo_n].pat = pat;
    sp_re_memo_n++;
  }
  return pat;
}

__attribute__((export_name("sp_reactor_re_cached")))
int sp_reactor_re_cached(void) { return sp_re_memo_n; }

/* ---- exit() interception (linked with --wrap=exit) ------------------------
 * An uncaught Ruby exception ends in `fprintf(stderr, ...); exit(1)`
 * (lib/spinel_rt.h:6726), and Kernel#exit with no handler in scope in
 * `exit(status)` (:6915).  In a *command* module that is the end of the story.
 * In a reactor it is a disaster if it reaches WASI's proc_exit, because the
 * host can only get control back by throwing, which abandons the wasm frames
 * without running any epilogue.  E011 measured the consequence: after 60
 * exception-terminated calls sp_gc_nroots had climbed 24 -> 840 (about +14 per
 * call, never released -- every stale slot is an address the GC will keep
 * dereferencing), and `__stack_pointer` was never restored either, so a few
 * thousand calls later the instance died with `memory access out of bounds`
 * inside printf.  Answers stayed correct right up to the trap.
 *
 * Turning exit() into a longjmp back into sp_reactor_run fixes both: the wasm
 * sjlj lowering restores __stack_pointer through the landing pad, and the
 * wrapper restores sp_gc_nroots explicitly.  The call still reports its
 * status; only the *process* death is cancelled. */
static jmp_buf sp_reactor_exit_jmp;
static volatile int sp_reactor_in_call = 0;
static volatile int sp_reactor_exit_status = 0;

_Noreturn void __real_exit(int code);

_Noreturn void __wrap_exit(int code) {
  if (sp_reactor_in_call) {
    sp_reactor_exit_status = code;
    longjmp(sp_reactor_exit_jmp, 1);
  }
  __real_exit(code);
}

__attribute__((export_name("sp_reactor_run")))
int sp_reactor_run(char *blob, int nargs) {
  char *argv[SP_REACTOR_MAX_ARGS + 2];
  volatile int argc = 1;
  volatile int rc;
  volatile int saved_roots = sp_gc_nroots;

  sp_reactor_call_count++;
  sp_reactor_reset_argv();
  argv[0] = (char *)"spinel";                 /* argv[0]; Spinel drops it */
  if (nargs > SP_REACTOR_MAX_ARGS) nargs = SP_REACTOR_MAX_ARGS;
  for (int i = 0; i < nargs && blob; i++) {
    argv[argc++] = blob;
    while (*blob) blob++;                     /* skip to the NUL ... */
    blob++;                                   /* ... and past it */
  }
  argv[argc] = NULL;

  sp_reactor_in_call = 1;
  if (setjmp(sp_reactor_exit_jmp) == 0) {
    rc = main(argc, argv);                    /* normal return: SP_GC_SAVE ran */
  } else {
    rc = sp_reactor_exit_status;              /* exit() was called; see above */
  }
  sp_reactor_in_call = 0;
  sp_gc_nroots = saved_roots;                 /* the exit path skipped cleanup */
  fflush(NULL);                               /* no __wasm_call_dtors here */
  return rc;
}
