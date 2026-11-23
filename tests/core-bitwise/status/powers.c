/* tests/core-bitwise/status/powers.c -- the 64-bit status kernels of
 * status/src/powers.rb. Reads rows "abs A N", "pow A N" or "powk A E" on
 * stdin and prints "op A N R" for each: R is the result, `fail` for
 * ARITHMETIC with the result word untouched, and anything else is printed as
 * it is so that it differs. (The status ABI has one code for both failures,
 * so run.sh reads the table's `negative` as `fail` here.) */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "ab.h"
#include "pw.h"
#include "pk0.h"
#include "pk1.h"
#include "pk2.h"
#include "pk31.h"
#include "pk63.h"
typedef int32_t (*fn_t)(int64_t, int64_t, int64_t *);
static fn_t pick(const char *op, int64_t n) {
  if (strcmp(op, "abs") == 0) return spinel_core_ab;
  if (strcmp(op, "pow") == 0) return spinel_core_pw;
  if (strcmp(op, "powk") != 0) return NULL;
  switch (n) {
  case 0: return spinel_core_pk0;
  case 1: return spinel_core_pk1;
  case 2: return spinel_core_pk2;
  case 31: return spinel_core_pk31;
  case 63: return spinel_core_pk63;
  default: return NULL;
  }
}
int main(void) {
  char op[8];
  int64_t a, n;
  while (scanf("%7s %" SCNd64 " %" SCNd64, op, &a, &n) == 3) {
    printf("%s %" PRId64 " %" PRId64 " ", op, a, n);
    fn_t fn = pick(op, n);
    if (!fn) {
      printf("unknown\n");
      continue;
    }
    const int64_t sentinel = -1234567890123;
    int64_t r = sentinel;
    int32_t st = fn(a, n, &r);
    if (st == 0)
      printf("%" PRId64 "\n", r);
    else if (st == SPINEL_CORE_ARITHMETIC && r == sentinel)
      printf("fail\n");
    else
      printf("status %d %s\n", (int)st, r == sentinel ? "untouched" : "TOUCHED");
  }
  return 0;
}
