/* E079 -- the DEVICE leg (Cortex-M33 / RV32 under QEMU).
 *
 * This file is Zephyr glue and nothing else.  The driver is
 * drv/e079_drv.c, byte-identical to the one the native leg compiles, and the
 * prototypes come from `spinel-mlirgen --emit-header` and
 * `spinel-gradfs --emit-header` -- so neither the calibration nor the
 * signatures are transcribed by hand.
 *
 * WHAT IS NEW COMPARED WITH E077's DEVICE: the image contains an Enzyme
 * adjoint.  Nothing about the platform changes because of that -- same one
 * import (`spinel_trap`), same absence of an allocator, same soft float.  The
 * gradient is ordinary code with an unusual provenance.
 *
 * The trap hook panics.  E077 kept a longjmp variant because it needed all its
 * broken cases to run in one image; here nothing is supposed to trap, so the
 * honest hook is the one a sensor node would ship: stop, and do not sign
 * anything else (E067 s5).
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <stdint.h>

#include "spinel_freestanding.h"
#include "spinel_grad.h"

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
	printk("E079\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
}

#define E079_PRINT(...) printk(__VA_ARGS__)
#include "e079_drv.c"

int main(void)
{
	e079_main();
	return 0;
}
