/* tests/core-bitwise/fs/powers.c -- `abs` and `**` of fs/k.rb at 64 bits.
 * argv[1] is `trap` (ab, pw, pkE) or `wrap` (ab_w, pw_w, pkE_w). Reads rows
 * "abs A N", "pow A N" or "powk A E" on stdin and prints "op A N R": R is the
 * result, `fail` when the trap hook is called with the overflow code 1, or
 * `negative` when it is called with code 7. The hook does not return to the
 * kernel; it jumps back here for the next row. */
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
typedef int64_t (*fn_t)(int64_t, int64_t);
/* The function a row names, or NULL for a row this driver does not know. */
static fn_t pick(const char *op, int64_t n, int wrap) {
  if (strcmp(op, "abs") == 0) return wrap ? spinel_ab_w : spinel_ab;
  if (strcmp(op, "pow") == 0) return wrap ? spinel_pw_w : spinel_pw;
  if (strcmp(op, "powk") != 0) return NULL;
  switch (n) {
  case 0: return wrap ? spinel_pk0_w : spinel_pk0;
  case 1: return wrap ? spinel_pk1_w : spinel_pk1;
  case 2: return wrap ? spinel_pk2_w : spinel_pk2;
  case 31: return wrap ? spinel_pk31_w : spinel_pk31;
  case 63: return wrap ? spinel_pk63_w : spinel_pk63;
  default: return NULL;
  }
}
int main(int argc, char **argv) {
  const int wrap = argc > 1 && strcmp(argv[1], "wrap") == 0;
  char op[8];
  int64_t a, n;
  while (scanf("%7s %" SCNd64 " %" SCNd64, op, &a, &n) == 3) {
    printf("%s %" PRId64 " %" PRId64 " ", op, a, n);
    fflush(stdout);
    fn_t fn = pick(op, n, wrap);
    if (!fn) {
      printf("unknown\n");
      continue;
    }
    if (setjmp(next_row)) {
      if (trap_code == 1) printf("fail\n");
      else if (trap_code == 7) printf("negative\n");
      else printf("trap %d\n", (int)trap_code);
      continue;
    }
    printf("%" PRId64 "\n", fn(a, n));
  }
  return 0;
}
