/* tests/core-bitwise/fs/drive.c -- calls each function of fs/k.rb and prints
 * one line per call. A trap prints its code and stops. */
#include <inttypes.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include "k.h"
void spinel_trap(int32_t code, int64_t a, int64_t b, const char *d) {
  (void)a; (void)b;
  printf("trap %d %s\n", code, d);
  exit(3);
}
#define P(label, v) printf("%s %" PRId64 "\n", label, (int64_t)(v))
int main(void) {
  P("band 12 10", spinel_band(12, 10));
  P("band -12 255", spinel_band(-12, 255));
  P("band MIN -1", spinel_band(INT64_MIN, -1));
  P("bor 12 3", spinel_bor(12, 3));
  P("bor -16 5", spinel_bor(-16, 5));
  P("bxor 12 10", spinel_bxor(12, 10));
  P("bxor -1 5", spinel_bxor(-1, 5));
  P("bxor MIN -1", spinel_bxor(INT64_MIN, -1));
  P("bnot 5", spinel_bnot(5));
  P("bnot MAX", spinel_bnot(INT64_MAX));
  P("bnot MIN", spinel_bnot(INT64_MIN));
  P("field 0xa7", spinel_field(0xa7));
  P("set_clear 0x41", spinel_set_clear(0x41));
  P("mask32 -1", spinel_mask32(-1));
  P("op_write 0x1234", spinel_op_write(0x1234));
  P("opw_shift 3", spinel_opw_shift(3));
  P("opw_pow 3", spinel_opw_pow(3));
  return 0;
}
