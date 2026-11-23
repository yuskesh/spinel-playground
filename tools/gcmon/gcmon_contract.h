/* gcmon_contract.h — the WHOLE read surface gcmon holds on vendor/spinel.
 *
 * The probe includes no vendor header. It lists the symbols it depends on here
 * and nowhere else, so the surface an upstream sync can break sits in one file
 * and "what does it depend on" is one grep.
 *
 * The types must match vendor/spinel's definitions (checked 2026-09-23 at pin
 * 573aa44c): lib/sp_gc.c:49,50,51,150,158,564 and lib/sp_alloc.c:178.
 *
 * Under an SP_THREADS build these counters are updated with relaxed atomics
 * (the SP_GC_CTR_* macros, lib/sp_gc.h:282-291). This version is
 * SINGLE-THREADED: it reads them plainly. Measuring a threaded build needs the
 * same relaxed loads. */
#ifndef GCMON_CONTRACT_H
#define GCMON_CONTRACT_H

#include <stddef.h>
#include <stdint.h>

/* The integer type of Patch 1's (SPINEL_EXTERN_METHODS) canonical value ABI:
   at pin 573aa44c, src/codegen.c's emit_method_signature declares
   `extern sp_int sp_<name>(sp_int lv_<param>)`, and lib/sp_types.h:90 defines
   sp_int as intptr_t. (spinel-llvm's fork used mrb_int, int64_t.) */
typedef intptr_t gcmon_int;

/* ---- heap state ---- */
extern size_t sp_gc_bytes;       /* GC heap in use (the string heap is not included) */
extern size_t sp_gc_old_bytes;   /* bytes in the old generation */
extern size_t sp_gc_threshold;   /* collection trigger (its value after retuning) */

/* ---- collections ---- */
extern int sp_gc_cycle;          /* collections, cumulative */
extern int sp_gc_full_runs;      /* major collections, cumulative */

/* ---- remembered set ---- */
extern int sp_gc_nremembered;
extern int sp_gc_rem_peak;

/* Deliberately NOT read: the walk of sp_str_heap / sp_str_old behind GC.stat's
 * str_bytes/str_count. It is O(n) and takes the heap lock, so calling it from a
 * section probe would disturb what it measures. Read it through GC.stat when
 * process granularity is enough. */

#endif /* GCMON_CONTRACT_H */
