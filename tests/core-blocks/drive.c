/* tests/core-blocks/drive.c -- calls each entry of src/ok.rb and prints one
 * line per call: the inputs, the status, and the result (or buffer). A failed
 * call prints `-` for the result, which the status ABI leaves unspecified. */
#include <stdint.h>
#include <stdio.h>
#include "bl.h"
static int32_t buf[4];
static void fill(void) { for (int k = 0; k < 4; k++) buf[k] = 5 + k; }
#define MAX INT64_MAX
#define MIN INT64_MIN
#define CALL(fn, a, b, n) (fill(), r = -7, spinel_core_bl_##fn((a), (b), buf, (n), &r))
static void line(const char *what, const char *args, int32_t st, int64_t r) {
  if (st == 0) printf("%s %s %d %lld\n", what, args, st, (long long)r);
  else printf("%s %s %d -\n", what, args, st);
}
int main(void) {
  int64_t r; int32_t st;
  st = CALL(times, 4, 0, 4); line("times", "4 0", st, r);
  st = CALL(times, 0, 0, 4); line("times", "0 0", st, r);
  st = CALL(times, -2, 0, 4); line("times", "-2 0", st, r);
  st = CALL(upto, 1, 3, 4); line("upto", "1 3", st, r);
  st = CALL(upto, 3, 1, 4); line("upto", "3 1", st, r);
  st = CALL(downto, 3, 1, 4); line("downto", "3 1", st, r);
  st = CALL(downto, 1, 3, 4); line("downto", "1 3", st, r);
  st = CALL(upto_count, MAX - 2, MAX, 4); line("upto_count", "max-2 max", st, r);
  st = CALL(downto_count, MIN + 2, MIN, 4); line("downto_count", "min+2 min", st, r);
  st = CALL(each, 0, 0, 4); line("each", "4", st, r);
  st = CALL(each, 0, 0, 0); line("each", "0", st, r);
  st = CALL(each_with_index, 0, 0, 4); line("each_with_index", "4", st, r);
  st = CALL(write, 1, 0, 4);
  printf("write 4 %d %lld %d,%d,%d,%d\n", st, (long long)r, buf[0], buf[1], buf[2], buf[3]);
  st = CALL(next, 4, 0, 4); line("next", "4", st, r);
  st = CALL(break, 4, 0, 4); line("break", "4", st, r);
  st = CALL(return, 4, 0, 4); line("return", "4", st, r);
  st = CALL(return, 1, 0, 4); line("return", "1", st, r);
  st = CALL(nested, 3, 3, 4); line("nested", "3 3", st, r);
  st = CALL(hidden, 3, 0, 4); line("hidden", "3", st, r);
  st = CALL(local, 3, 0, 4); line("local", "3", st, r);
  st = CALL(overflow, MAX - 1, MAX, 4); line("overflow", "max-1 max", st, r);
  st = CALL(bounds, 4, 0, 4); line("bounds", "4", st, r);
  st = CALL(bounds, 5, 0, 4); line("bounds", "5", st, r);
  st = CALL(return_all, 3, 0, 4); line("return_all", "3", st, r);
  st = CALL(return_all, 0, 0, 4); line("return_all", "0", st, r);
  st = CALL(break_all, 3, 0, 4); line("break_all", "3", st, r);
  st = CALL(return_upto, 2, 5, 4); line("return_upto", "2 5", st, r);
  st = CALL(return_upto, 5, 2, 4); line("return_upto", "5 2", st, r);
  return 0;
}
