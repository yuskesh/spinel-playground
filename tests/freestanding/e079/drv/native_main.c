/* E079 native leg: the same e079_drv.c, on the host, with printf and an
 * exiting trap hook.  `platform: none` in arm64-host.yaml means the platform
 * API is exactly one function and this file is all of it. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define E079_PRINT(...) printf(__VA_ARGS__)
#include "e079_drv.c"

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail) {
  fprintf(stderr, "E079\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
          (int)code, (long long)a, (long long)b, detail ? detail : "");
  exit(3);
}

int main(void) { return e079_main(); }
