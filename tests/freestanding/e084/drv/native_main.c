/* E084 native leg: e084_drv.c on the host, printf, exiting trap hook.
 * Two objects are linked next to this file: spinel-mlirgen's kernel (which
 * IMPORTS spinel_grad_sq_hinge_loss AND spinel_hvp_sq_hinge_loss as platform
 * externs) and spinel-gradfs's --grads-only object (which defines both).
 * The "platform" here is the linker and this one hook. */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>

#define E084_PRINT(...) printf(__VA_ARGS__)
#include "e084_drv.c"

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail) {
  fflush(stdout);
  fprintf(stderr, "E084\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
          (int)code, (long long)a, (long long)b, detail ? detail : "");
  exit(3);
}

int main(void) { return e084_main(); }
