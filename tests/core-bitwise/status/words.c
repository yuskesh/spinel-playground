/* tests/core-bitwise/status/words.c -- decision 0042 stage 4: the 64-bit
 * status kernels of status/src/words.rb.
 *
 *   words      reads rows "op A B" on stdin (words.tsv's op names) and prints
 *              "op A B R": R is the result, `fail` for ARITHMETIC with the
 *              result word untouched, and anything else is printed as it is
 *              so that it differs.
 *   checksums  prints "name input R" for FNV-1a 32, FNV-1a 64 and CRC-32
 *              over the published check strings, iterating the kernels'
 *              steps over the bytes. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "w_w32_add.h"
#include "w_w32_sub.h"
#include "w_w32_mul.h"
#include "w_w32_neg.h"
#include "w_w32_shl.h"
#include "w_u32_lt.h"
#include "w_u32_le.h"
#include "w_u32_gt.h"
#include "w_u32_ge.h"
#include "w_u32_shr.h"
#include "w_fixed_mul.h"
#include "w_fixed_div.h"
#include "w_u32lit.h"
#include "w_w64_add.h"
#include "w_w64_sub.h"
#include "w_w64_mul.h"
#include "w_w64_neg.h"
#include "w_w64_shl.h"
#include "w_u64_lt.h"
#include "w_u64_le.h"
#include "w_u64_gt.h"
#include "w_u64_ge.h"
#include "w_u64_shr.h"
#include "fnv32_seed.h"
#include "fnv32_step.h"
#include "fnv64_step.h"
#include "crc32_step.h"
typedef int32_t (*fn_t)(int64_t, int64_t, int64_t *);
static const struct { const char *op; fn_t fn; } table[] = {
  {"w32_add", spinel_core_w_w32_add},
  {"w32_sub", spinel_core_w_w32_sub},
  {"w32_mul", spinel_core_w_w32_mul},
  {"w32_neg", spinel_core_w_w32_neg},
  {"w32_shl", spinel_core_w_w32_shl},
  {"u32_lt", spinel_core_w_u32_lt},
  {"u32_le", spinel_core_w_u32_le},
  {"u32_gt", spinel_core_w_u32_gt},
  {"u32_ge", spinel_core_w_u32_ge},
  {"u32_shr", spinel_core_w_u32_shr},
  {"fixed_mul", spinel_core_w_fixed_mul},
  {"fixed_div", spinel_core_w_fixed_div},
  {"u32lit", spinel_core_w_u32lit},
  {"w64_add", spinel_core_w_w64_add},
  {"w64_sub", spinel_core_w_w64_sub},
  {"w64_mul", spinel_core_w_w64_mul},
  {"w64_neg", spinel_core_w_w64_neg},
  {"w64_shl", spinel_core_w_w64_shl},
  {"u64_lt", spinel_core_w_u64_lt},
  {"u64_le", spinel_core_w_u64_le},
  {"u64_gt", spinel_core_w_u64_gt},
  {"u64_ge", spinel_core_w_u64_ge},
  {"u64_shr", spinel_core_w_u64_shr},
};
static fn_t pick(const char *op) {
  for (size_t i = 0; i < sizeof table / sizeof table[0]; ++i)
    if (strcmp(table[i].op, op) == 0) return table[i].fn;
  return NULL;
}
/* A step that does not answer OK ends the run: the checksum would be wrong. */
static int64_t step(fn_t fn, int64_t a, int64_t b) {
  int64_t r = 0;
  int32_t st = fn(a, b, &r);
  if (st != 0) {
    printf("status %d\n", (int)st);
    exit(1);
  }
  return r;
}
static void checksums(void) {
  static const char *fnv[] = {"a", "foobar"};
  for (int s = 0; s < 2; ++s) {
    int64_t h32 = step(spinel_core_fnv32_seed, 0, 0);
    int64_t h64 = -3750763034362895579; /* 0xcbf29ce484222325 */
    for (const char *p = fnv[s]; *p; ++p) {
      h32 = step(spinel_core_fnv32_step, h32, (unsigned char)*p);
      h64 = step(spinel_core_fnv64_step, h64, (unsigned char)*p);
    }
    printf("fnv32 %s %" PRId64 "\n", fnv[s], h32);
    printf("fnv64 %s %" PRId64 "\n", fnv[s], h64);
  }
  int64_t c = -1;
  for (const char *p = "123456789"; *p; ++p)
    c = step(spinel_core_crc32_step, c, (unsigned char)*p);
  printf("crc32 123456789 %" PRId64 "\n", ~c);
}
int main(int argc, char **argv) {
  if (argc > 1 && strcmp(argv[1], "checksums") == 0) {
    checksums();
    return 0;
  }
  char op[16];
  int64_t a, b;
  while (scanf("%15s %" SCNd64 " %" SCNd64, op, &a, &b) == 3) {
    printf("%s %" PRId64 " %" PRId64 " ", op, a, b);
    fn_t fn = pick(op);
    if (!fn) { printf("unknown\n"); continue; }
    const int64_t sentinel = -1234567890123;
    int64_t r = sentinel;
    int32_t st = fn(a, b, &r);
    if (st == 0)
      printf("%" PRId64 "\n", r);
    else if (st == SPINEL_CORE_ARITHMETIC && r == sentinel)
      printf("fail\n");
    else
      printf("status %d %s\n", (int)st, r == sentinel ? "untouched" : "TOUCHED");
  }
  return 0;
}
