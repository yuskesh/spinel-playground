/* The C harness for tests/core-boundary/capabilities.sh, and for the adapter
 * lane in tests/core-boundary/artifacts.sh.
 *
 * One helper and its arguments per run; prints the value the CORE kernel
 * produced. The expectations come from the original Full helper under CRuby,
 * not from here.
 *
 * TWO BACK ENDS, ONE COMPARISON. Built plainly it calls the CORE entry
 * directly, which is how a C consumer uses it. Built with
 * -DSPINEL_VIA_ADAPTER it goes through the Full adapter instead -- the
 * registry, an allocation for the result, `invoke`, a `load`, a release -- and
 * prints the same line. That decision 0007 task 5 asks for both is the reason
 * they are one file: the printing and the parsing are the same source either
 * way, so a difference in the output is a difference in the BOUNDARY and not
 * in two harnesses that drifted.
 */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

#ifdef SPINEL_VIA_ADAPTER
#include "spinel_adapter_fixed_to_i32.h"
#include "spinel_adapter_fixed_mul.h"
#include "spinel_adapter_fixed_cdiv.h"
#include "spinel_adapter_fixed_div.h"
#include "spinel_adapter_fixed_bam.h"
#include "spinel_adapter_registry.h"

/* The result of every helper here is one i32 cell. The adapter publishes into
 * storage the caller owns, so the caller makes one, reads it and gives it
 * back; `load` answers the unsigned 32-bit pattern or a negative status, and
 * an i32 pattern at or above 2^31 is that value less 2^32. */
static int adapter_result(int32_t id, int32_t *out) {
  int64_t v = spinel_adapter_registry_load(id, 0);
  if (v < 0) return (int)v;
  *out = (int32_t)(v >= 2147483648LL ? v - 4294967296LL : v);
  return 0;
}
#else
#include "spinel_core_fixed_to_i32.h"
#include "spinel_core_fixed_mul.h"
#include "spinel_core_fixed_cdiv.h"
#include "spinel_core_fixed_div.h"
#include "spinel_core_fixed_bam.h"
#endif

int main(int argc, char **argv) {
  if (argc < 3) return 99;
  const char *helper = argv[1];
  int32_t r = 0;
  int64_t w = 0;
  int wide = 0;      /* the angle helper answers i64, the others i32 */
  int32_t st = -1;

#ifdef SPINEL_VIA_ADAPTER
  if (spinel_adapter_registry_startup() != 0) { printf("startup failed\n"); return 97; }
  int32_t out = spinel_adapter_registry_allocate(2 /* ELEM_I32 */, 1);
  int32_t out_w = spinel_adapter_registry_allocate(4 /* ELEM_I64 */, 1);
  int32_t words = spinel_adapter_registry_allocate(3 /* ELEM_U32 */, 2);
  if (out <= 0 || out_w <= 0 || words <= 0) { printf("allocate failed\n"); return 96; }

  if (strcmp(helper, "fixed_to_i32") == 0 && argc == 3) {
    st = spinel_adapter_fixed_to_i32_invoke(strtoll(argv[2], 0, 10), out);
  } else if (strcmp(helper, "fixed_mul") == 0 && argc == 4) {
    st = spinel_adapter_fixed_mul_invoke(strtoll(argv[2], 0, 10),
                                         strtoll(argv[3], 0, 10), out);
  } else if (strcmp(helper, "fixed_cdiv") == 0 && argc == 4) {
    st = spinel_adapter_fixed_cdiv_invoke(strtoll(argv[2], 0, 10),
                                          strtoll(argv[3], 0, 10), out);
  } else if (strcmp(helper, "fixed_div") == 0 && argc == 4) {
    st = spinel_adapter_fixed_div_invoke(strtoll(argv[2], 0, 10),
                                         strtoll(argv[3], 0, 10), out);
  } else if (strcmp(helper, "fixed_bam") == 0 && argc == 3) {
    wide = 1;
    st = spinel_adapter_fixed_bam_invoke(strtoll(argv[2], 0, 10), out_w);
  } else {
    printf("unknown-helper\n");
    return 98;
  }
  if (st == 0) {
    if (wide) {
      /* i64 storage refuses the ordinary load on purpose, so the answer comes
       * back as two unsigned words. */
      if (spinel_adapter_registry_load_i64_words(out_w, 0, words, 0, 1) != 0) {
        printf("load words failed\n"); return 95;
      }
      int64_t lo = spinel_adapter_registry_load(words, 0);
      int64_t hi = spinel_adapter_registry_load(words, 1);
      if (lo < 0 || hi < 0) { printf("load word failed\n"); return 95; }
      w = (int64_t)(((uint64_t)hi << 32) | (uint64_t)lo);
    } else {
      int bad = adapter_result(out, &r);
      if (bad) { printf("load %d\n", bad); return 95; }
    }
  }
  if (spinel_adapter_registry_release(out) != 0) { printf("release failed\n"); return 94; }
  if (spinel_adapter_registry_release(out_w) != 0) { printf("release failed\n"); return 94; }
  if (spinel_adapter_registry_release(words) != 0) { printf("release failed\n"); return 94; }
#else
  if (strcmp(helper, "fixed_to_i32") == 0 && argc == 3) {
    st = spinel_core_fixed_to_i32(strtoll(argv[2], 0, 10), &r);
  } else if (strcmp(helper, "fixed_mul") == 0 && argc == 4) {
    st = spinel_core_fixed_mul((int32_t)strtoll(argv[2], 0, 10),
                               (int32_t)strtoll(argv[3], 0, 10), &r);
  } else if (strcmp(helper, "fixed_cdiv") == 0 && argc == 4) {
    st = spinel_core_fixed_cdiv(strtoll(argv[2], 0, 10),
                                strtoll(argv[3], 0, 10), &r);
  } else if (strcmp(helper, "fixed_div") == 0 && argc == 4) {
    st = spinel_core_fixed_div((int32_t)strtoll(argv[2], 0, 10),
                               (int32_t)strtoll(argv[3], 0, 10), &r);
  } else if (strcmp(helper, "fixed_bam") == 0 && argc == 3) {
    /* The angle helper answers 0..4294967295, which is not an i32, so its
     * result is an i64 and is printed as one. */
    st = spinel_core_fixed_bam(strtoll(argv[2], 0, 10), &w);
    wide = 1;
  } else {
    printf("unknown-helper\n");
    return 98;
  }
#endif
  if (st != 0) {
    /* A status here is a real answer and not a excuse: the original helper
     * never fails, so a failing kernel is a disagreement with it. */
    printf("status %d\n", (int)st);
    return 0;
  }
  if (wide) {
    printf("%lld\n", (long long)w);
  } else {
    printf("%ld\n", (long)r);
  }
  return 0;
}
