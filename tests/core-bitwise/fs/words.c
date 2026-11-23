/* tests/core-bitwise/fs/words.c -- decision 0042 stage 4: the intrinsics of
 * fs/k.rb at 64 bits.
 *
 *   words      reads rows "op A B" on stdin (words.tsv's op names) and prints
 *              "op A B R": R is the result, or `fail` when the trap hook is
 *              called with the intrinsic code 8. The hook does not return to
 *              the kernel; it jumps back here for the next row.
 *   checksums  prints "name input R" for FNV-1a 32, FNV-1a 64 and CRC-32
 *              over the published check strings, iterating the kernels'
 *              steps over the bytes. */
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
static const struct { const char *op; fn_t fn; } table[] = {
  {"w32_add", spinel_w_w32_add}, {"w32_sub", spinel_w_w32_sub},
  {"w32_mul", spinel_w_w32_mul}, {"w32_neg", spinel_w_w32_neg},
  {"w32_shl", spinel_w_w32_shl}, {"u32_lt", spinel_w_u32_lt},
  {"u32_le", spinel_w_u32_le}, {"u32_gt", spinel_w_u32_gt},
  {"u32_ge", spinel_w_u32_ge}, {"u32_shr", spinel_w_u32_shr},
  {"fixed_mul", spinel_w_fixed_mul}, {"fixed_div", spinel_w_fixed_div},
  {"u32lit", spinel_w_u32lit}, {"w32_add_w", spinel_w_w32_add_w},
  {"w64_add", spinel_w_w64_add}, {"w64_sub", spinel_w_w64_sub},
  {"w64_mul", spinel_w_w64_mul}, {"w64_neg", spinel_w_w64_neg},
  {"w64_shl", spinel_w_w64_shl}, {"u64_lt", spinel_w_u64_lt},
  {"u64_le", spinel_w_u64_le}, {"u64_gt", spinel_w_u64_gt},
  {"u64_ge", spinel_w_u64_ge}, {"u64_shr", spinel_w_u64_shr},
};
static fn_t pick(const char *op) {
  for (size_t i = 0; i < sizeof table / sizeof table[0]; ++i)
    if (strcmp(table[i].op, op) == 0) return table[i].fn;
  return NULL;
}
static void checksums(void) {
  static const char *fnv[] = {"a", "foobar"};
  for (int s = 0; s < 2; ++s) {
    int64_t h32 = spinel_fnv32_seed();
    int64_t h64 = -3750763034362895579; /* 0xcbf29ce484222325 */
    for (const char *p = fnv[s]; *p; ++p) {
      h32 = spinel_fnv32_step(h32, (unsigned char)*p);
      h64 = spinel_fnv64_step(h64, (unsigned char)*p);
    }
    printf("fnv32 %s %" PRId64 "\n", fnv[s], h32);
    printf("fnv64 %s %" PRId64 "\n", fnv[s], h64);
  }
  int64_t c = -1;
  for (const char *p = "123456789"; *p; ++p) c = spinel_crc32_step(c, (unsigned char)*p);
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
    fflush(stdout);
    fn_t fn = pick(op);
    if (!fn) { printf("unknown\n"); continue; }
    if (setjmp(next_row)) {
      if (trap_code == 8) printf("fail\n");
      else printf("trap %d\n", (int)trap_code);
      continue;
    }
    printf("%" PRId64 "\n", fn(a, b));
  }
  return 0;
}
