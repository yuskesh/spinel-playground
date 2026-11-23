/* The glue-screen control of Task 10 (interrupt configuration): a glue unit
 * (--mutate-glue) that disables an interrupt. Glue may block, since it runs
 * a thread of 0014 §4, but may not reconfigure interrupts (§9); the screen
 * of §6 refuses it at step 5, naming arm_irq_disable (what irq_disable expands to on Cortex-M). */
#include <zephyr/kernel.h>
#include <zephyr/irq.h>
void spc_glue_irq_off(void)
{
	irq_disable(90);
}
