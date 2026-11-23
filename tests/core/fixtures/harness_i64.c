/* Same host, the i64 boundary. Separate on purpose: the i32 harness exercises
   the boundary narrowing check, this one exercises the internal arithmetic. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include "kernel.h"
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail) {
  printf("TRAP code=%d a=%lld b=%lld detail=%s\n",
         code, (long long)a, (long long)b, detail ? detail : "");
  exit(42);
}
int main(int argc, char **argv) {
  if (argc != 3) { fprintf(stderr, "usage: %s A B\n", argv[0]); return 2; }
  printf("%lld\n", (long long)spinel_add64(strtoll(argv[1], 0, 10),
                                           strtoll(argv[2], 0, 10)));
  return 0;
}
