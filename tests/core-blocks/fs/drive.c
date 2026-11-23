/* tests/core-blocks/fs/drive.c -- calls each function of fs/k.rb and prints
 * one line per call. A trap prints its code and stops. */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "k.h"
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *d) {
  (void)a; (void)b;
  printf("trap %d %s\n", code, d);
  exit(3);
}
int main(void) {
  int32_t buf[4] = {5, 6, 7, 8};
  printf("tri 4 %d\n", spinel_tri(4));
  printf("tri 0 %d\n", spinel_tri(0));
  printf("tri -3 %d\n", spinel_tri(-3));
  printf("span 1 3 %d\n", spinel_span(1, 3));
  printf("span 3 1 %d\n", spinel_span(3, 1));
  printf("order 1 3 %d\n", spinel_order(1, 3));
  printf("sum 4 %d\n", spinel_sum(buf, 4));
  printf("sum 0 %d\n", spinel_sum(buf, 0));
  printf("edge max-2 %d\n", spinel_edge(2147483645));
  printf("first 3 %d\n", spinel_first(3));
  printf("first 0 %d\n", spinel_first(0));
  return 0;
}
