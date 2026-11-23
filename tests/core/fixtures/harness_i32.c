/* Calls the i32 core object from an ordinary C host. The trap hook is the one
   extern the profile declares; it prints what it was told and exits 42 so the
   runner can tell a trap from a value. */
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
  printf("%d\n", (int)spinel_add((int32_t)strtol(argv[1], 0, 10),
                                 (int32_t)strtol(argv[2], 0, 10)));
  return 0;
}
