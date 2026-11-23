/* tests/core-bitwise/status/drive.c -- the 64-bit status kernels of
 * status/src/shifts.rb. Reads rows "shl A N" or "shr A N" on stdin and prints
 * "op A N R" for each: R is the result, `fail` for ARITHMETIC with the result
 * word untouched, and anything else is printed as it is so that it differs. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "shl.h"
#include "shr.h"
int main(void) {
  char op[8];
  int64_t a, n;
  while (scanf("%7s %" SCNd64 " %" SCNd64, op, &a, &n) == 3) {
    const int64_t sentinel = -1234567890123;
    int64_t r = sentinel;
    int32_t st = strcmp(op, "shl") == 0 ? spinel_core_shl(a, n, &r)
                                        : spinel_core_shr(a, n, &r);
    printf("%s %" PRId64 " %" PRId64 " ", op, a, n);
    if (st == 0)
      printf("%" PRId64 "\n", r);
    else if (st == SPINEL_CORE_ARITHMETIC && r == sentinel)
      printf("fail\n");
    else
      printf("status %d %s\n", (int)st, r == sentinel ? "untouched" : "TOUCHED");
  }
  return 0;
}
