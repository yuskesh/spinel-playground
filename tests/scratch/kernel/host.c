/* Decision 0041 stage 2: the kernel's data stack, driven from C on the host.
 * tick and tick2 (work.rb) share one 256-byte region: an 8-byte offset word
 * and 31 i64 elements. 64 canary bytes follow it. Each call must leave the
 * offset at 0 and the canary whole. The values are written by hand. */
#include <stdint.h>
#include <stdio.h>
#include <string.h>
#include "tick.h"
#include "tick2.h"

static struct { _Alignas(8) uint8_t region[256]; uint8_t after[64]; } m;

static int check(const char *what, int64_t in, int32_t want_status, int64_t want_out) {
  int64_t inp[1] = {in}, out[1] = {-7};
  int32_t s = spinel_core_tick2(inp, out, m.region);
  uint64_t off;
  memcpy(&off, m.region, 8);
  int ok = s == want_status && (s != 0 || out[0] == want_out) && (s == 0 || out[0] == -7) && off == 0;
  for (int i = 0; i < 64; i++)
    if (m.after[i] != 0xA5) ok = 0;
  printf("%s %s: tick2(%lld) status %d out %lld offset %llu\n", ok ? "PASS " : "FAIL ", what, (long long)in, s,
         (long long)out[0], (unsigned long long)off);
  return ok;
}

int main(void) {
  memset(m.after, 0xA5, sizeof m.after);
  int64_t out[1] = {0};
  int32_t s = spinel_core_tick(out, m.region);
  int ok = s == 0 && out[0] == 23;
  printf("%s tick makes 4: status %d out %lld\n", ok ? "PASS " : "FAIL ", s, (long long)out[0]);
  /* work(n): a = [5, 2 + 2, 0...], then 3 more each; the sum, plus n */
  ok &= check("four elements", 4, 0, 23);
  ok &= check("two elements", 2, 0, (5 + 3) + (2 + 3) + 2);
  ok &= check("the whole region, 31 elements", 31, 0, 8 + 5 + 29 * 3 + 31);
  ok &= check("one element past the region is CAPACITY", 32, 4, 0);
  ok &= check("a negative size is BOUNDS", -1, 3, 0);
  ok &= check("a[1] of a 1-element array is BOUNDS", 1, 3, 0);
  ok &= check("after the failures the region is free", 4, 0, 23);
  s = spinel_core_tick(out, 0);
  printf("%s a null region is ARGUMENT: status %d\n", s == 1 ? "PASS " : "FAIL ", s);
  ok &= s == 1;
  return !ok;
}
