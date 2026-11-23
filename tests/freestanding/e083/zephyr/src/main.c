/* E083 -- the DEVICE leg (Cortex-M33 / RV32 under QEMU).
 *
 * Zephyr glue and nothing else.  The driver is drv/e083_drv.c, byte-identical
 * to the one the native leg compiles; the prototypes come from
 * `spinel-mlirgen --emit-header`.  What is new compared with E079's device:
 * the image holds the SGD loop INSIDE the kernel object -- main.c calls no
 * gradient function and holds no loop; the kernel calls the adjoint through
 * the platform extern the profile declares, and west linked the adjoint
 * object next to it (see ../CMakeLists.txt).
 *
 * The trap hook panics: nothing in the calibration stream is supposed to
 * trap, so the honest hook is the one a sensor node would ship (E067 s5).
 * The E083_TRAP probe build relies on exactly that -- the UNREACHED line
 * must never print because k_panic() does not return.
 */
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>
#include <stdint.h>

#include "spinel_freestanding.h"

void spinel_trap(int32_t code, int64_t a, int64_t b, const char *detail)
{
	printk("E083\tTRAP\tcode=%d a=%lld b=%lld detail=%s\n",
	       (int)code, (long long)a, (long long)b, detail);
	k_panic();
	for (;;) {
	}
}

#define E083_PRINT(...) printk(__VA_ARGS__)
#include "e083_drv.c"

int main(void)
{
	e083_main();
	return 0;
}
