/* tests/fs-helper-buffers/drive.c -- the x86_64 host build of k.rb (a 64-bit
 * body). Prints the same lines as run.mjs does for wasm32: each row fills its
 * buffers, calls one entry and prints what comes back. The trap hook does not
 * return to the kernel; it jumps back here, the row prints "trap CODE A B"
 * (for code 4, the index and the length) and the next row runs. */
#include <inttypes.h>
#include <setjmp.h>
#include <stdint.h>
#include <stdio.h>
#include "k.h"

static jmp_buf back;
static int32_t t_code;
static int64_t t_a, t_b;
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail) {
  (void)detail;
  t_code = code; t_a = a; t_b = b;
  longjmp(back, 1);
}

static int32_t A[8], B[8];
static float F[8];

static void ints(const int32_t *xs, int n) {
  for (int i = 0; i < n; ++i) printf(" %" PRId32, xs[i]);
}
static void set3(int32_t *xs, int32_t a, int32_t b, int32_t c) { xs[0] = a; xs[1] = b; xs[2] = c; }

/* RESULT(expr): prints " <value>" or " trap CODE A B". */
#define RESULT(expr)                                                         \
  do {                                                                       \
    if (setjmp(back)) printf(" trap %d %" PRId64 " %" PRId64, (int)t_code, t_a, t_b); \
    else printf(" %" PRId32, (expr));                                        \
  } while (0)

int main(void) {
  for (int i = 0; i < 4; ++i) F[i] = 9;
  printf("fill_all");
  RESULT(spinel_fill_all(F, 4));
  for (int i = 0; i < 4; ++i) printf(" %g", (double)F[i]);
  printf("\n");

  for (int i = 0; i < 5; ++i) A[i] = -1;
  printf("lend_on");
  RESULT(spinel_lend_on(A, 5));
  ints(A, 5);
  printf("\n");

  set3(A, 10, 20, 30); B[0] = 7; B[1] = 8;
  printf("two");
  RESULT(spinel_two(A, 3, B, 2));
  ints(A, 3); ints(B, 2);
  printf("\n");

  static const int32_t ij[3][2] = {{2, 1}, {3, 0}, {0, 2}};
  for (int r = 0; r < 3; ++r) {
    set3(A, 10, 20, 30); B[0] = 7; B[1] = 8;
    printf("past %d %d", (int)ij[r][0], (int)ij[r][1]);
    RESULT(spinel_past(A, 3, B, 2, ij[r][0], ij[r][1]));
    printf(" a"); ints(A, 3); printf(" b"); ints(B, 2);
    printf("\n");
  }

  set3(A, 3, 4, 5);
  printf("sum_in");
  RESULT(spinel_sum_in(A, 3));
  printf("\n");

  set3(A, 1, 1, 1); set3(B, 0, 0, 0);
  printf("each_lent");
  RESULT(spinel_each_lent(A, B, 3));
  ints(B, 3);
  printf("\n");

  for (int32_t extra = 0; extra < 2; ++extra) {
    set3(A, 0, 0, 0);
    printf("via_entry %d", (int)extra);
    RESULT(spinel_via_entry(A, 3, extra));
    ints(A, 3);
    printf("\n");
  }

  static const int32_t at[2] = {1, 3};
  for (int r = 0; r < 2; ++r) {
    set3(A, 0, 0, 0);
    printf("checked_put %d", (int)at[r]);
    RESULT(spinel_checked_put(A, 3, at[r]));
    ints(A, 3);
    printf("\n");
  }
  A[0] = 5; B[0] = 0; B[4] = 9;
  printf("modes");
  RESULT(spinel_modes(A, B, B + 4, 1));
  ints(B, 1); ints(B + 4, 1);
  printf("\n");

  /* A 3-element buffer with a canary after it: an unchecked store at index
   * 3 would overwrite the 91. */
  static const int32_t ci[2] = {1, 3};
  for (int r = 0; r < 2; ++r) {
    A[0] = 0; A[1] = 0; A[2] = 0; A[3] = 91;
    printf("chain %d", (int)ci[r]);
    RESULT(spinel_chain(A, 3, ci[r]));
    ints(A, 4);
    printf("\n");
  }
  for (int r = 0; r < 2; ++r) {
    A[0] = 0; A[1] = 0; A[2] = 0; A[3] = 91;
    printf("chain2 %d", (int)ci[r]);
    RESULT(spinel_chain2(A, 3, ci[r]));
    ints(A, 4);
    printf("\n");
  }
  return 0;
}

