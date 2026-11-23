/* E083 native leg: e083_drv.c on the host, printf, exiting trap hook.
 * Two objects are linked next to this file: spinel-mlirgen's kernel (which
 * IMPORTS spinel_grad_sq_hinge_loss as a platform extern) and spinel-gradfs's
 * --grads-only object (which defines it).  The "platform" here is the linker
 * and this one hook. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define E083_PRINT(...) printf(__VA_ARGS__)
#include "e083_drv.c"

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail) {
  fflush(stdout);
  fprintf(stderr, "E083\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
          (int)code, (long long)a, (long long)b, detail ? detail : "");
  exit(3);
}

int main(void) { return e083_main(); }
