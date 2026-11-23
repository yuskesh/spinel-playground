/* bm040: reset and fault entry for the secure Cortex-M33 of QEMU's
 * mps2-an521, with no RTOS and no C library.
 *
 * The vector table is the first thing in the CODE region (link.ld), where the
 * core reads its initial stack pointer and reset vector. Reset_Handler copies
 * .data from its load address, zeroes .bss and runs the driver. Every other
 * exception is a fault here: it is reported on the console and the core
 * stops, so a fault is a line in the log rather than a silent hang.
 */
#include <stdint.h>

#include "bm.h"

extern uint32_t __data_load[], __data_start[], __data_end[];
extern uint32_t __bss_start[], __bss_end[];
extern uint32_t __stack_top[];

void Reset_Handler(void);
void bm_fault(void);

void Reset_Handler(void)
{
	const uint32_t *src = __data_load;
	for (uint32_t *dst = __data_start; dst < __data_end;)
		*dst++ = *src++;
	for (uint32_t *dst = __bss_start; dst < __bss_end;)
		*dst++ = 0;
	bm_main();
	for (;;) {
	}
}

void bm_fault(void)
{
	bm_puts("E040\tFATAL\tfault\n");
	for (;;) {
	}
}

/* Initial SP, reset, then NMI, HardFault, MemManage, BusFault, UsageFault,
 * SecureFault, three reserved, SVCall, DebugMonitor, reserved, PendSV and
 * SysTick (ARMv8-M exception numbers 1-15). No interrupt is enabled, so the
 * table stops there. */
__attribute__((section(".vectors"), used))
static void *const bm_vectors[16] = {
	(void *)__stack_top, (void *)Reset_Handler,
	(void *)bm_fault, (void *)bm_fault, (void *)bm_fault, (void *)bm_fault,
	(void *)bm_fault, (void *)bm_fault,
	0, 0, 0,
	(void *)bm_fault, (void *)bm_fault,
	0,
	(void *)bm_fault, (void *)bm_fault,
};
