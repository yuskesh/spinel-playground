/* The extra connected handler control of Task 10: a unit linked into the
 * image that connects IRQ 90 at boot -- an IRQ no device of the mps2/an521
 * devicetree uses, so no inventory entry names it. Step 10's vector
 * classification finds _sw_isr_table[90] pointing at a handler that is not
 * Zephyr's spurious one and has no inventory entry, and refuses the build. */
#include <zephyr/kernel.h>
#include <zephyr/init.h>
#include <zephyr/irq.h>

static void spc_extra_isr(const void *arg)
{
	(void)arg;
}

static int spc_extra_connect(void)
{
	IRQ_CONNECT(90, 3, spc_extra_isr, NULL, 0);
	irq_enable(90);
	return 0;
}
SYS_INIT(spc_extra_connect, APPLICATION, 0);
