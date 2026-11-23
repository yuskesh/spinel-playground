/* tests/core-bitwise/fs/shifts.c -- the shifts of fs/k.rb at 64 bits. argv[1]
 * is `trap` (spinel_shl, spinel_shr) or `wrap` (spinel_shl_w, spinel_shr_w).
 * Reads rows "shl A N" or "shr A N" on stdin and prints "op A N R": R is the
 * result, or `fail` when the trap hook is called with the overflow code 1.
 * The hook does not return to the kernel; it jumps back here for the next
 * row. */
#include <inttypes.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "k.h"
static jmp_buf next_row;
static int32_t trap_code;
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *d) {
  (void)a; (void)b; (void)d;
  trap_code = code;
  longjmp(next_row, 1);
}
int main(int argc, char **argv) {
  const int wrap = argc > 1 && strcmp(argv[1], "wrap") == 0;
  char op[8];
  int64_t a, n;
  while (scanf("%7s %" SCNd64 " %" SCNd64, op, &a, &n) == 3) {
    printf("%s %" PRId64 " %" PRId64 " ", op, a, n);
    fflush(stdout);
    if (setjmp(next_row)) {
      if (trap_code == 1) printf("fail\n");
      else printf("trap %d\n", (int)trap_code);
      continue;
    }
    const int shl = strcmp(op, "shl") == 0;
    int64_t r = wrap ? (shl ? spinel_shl_w(a, n) : spinel_shr_w(a, n))
                     : (shl ? spinel_shl(a, n) : spinel_shr(a, n));
    printf("%" PRId64 "\n", r);
  }
  return 0;
}
