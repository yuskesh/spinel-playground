/* E084 -- the DEVICE leg (Cortex-M33 / RV32 under QEMU).
 *
 * Zephyr glue and nothing else.  The driver is drv/e084_drv.c, byte-identical
 * to the one the native leg compiles; the prototypes come from
 * `spinel-mlirgen --emit-header` plus spinel-gradfs's --emit-header (the hvp
 * prototype).  What is new compared with E083's device: the image holds a
 * NEWTON-CG loop inside the kernel object -- main.c calls no gradient or
 * Hessian-vector function and holds no loop; the kernel reaches BOTH adjoint
 * products through the platform externs the profile declares, and west linked
 * the --grads-only object next to it (see ../CMakeLists.txt).
 *
 * The trap hook panics: nothing in the calibration stream is supposed to
 * trap, so the honest hook is the one a sensor node would ship (E067 s5).
 * The E084_TRAP probe build relies on exactly that -- the UNREACHED line
 * must never print because k_panic() does not return.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <stdint.h>

#include "spinel_freestanding.h"

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
	printk("E084\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
}

#define E084_PRINT(...) printk(__VA_ARGS__)
#include "e084_drv.c"

int main(void)
{
	e084_main();
	return 0;
}
