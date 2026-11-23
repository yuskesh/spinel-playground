/* bm040-frdm: reset and fault entry for the secure Cortex-M33 (CPU0) of the
 * NXP MCX N947, with no RTOS and no C library.
 *
 * The vector table is the first thing in flash (link.ld), where the boot ROM
 * finds the initial stack pointer and the reset vector. Its words 8-10
 * (offsets 0x20-0x2b) are reserved by ARMv8-M and stay zero: Zephyr's image
 * for this board leaves them zero too, and LinkServer-written images in that
 * shape boot from a pin reset (README.md).
 *
 * Reset_Handler does what the boot ROM's hand-over leaves undefined before C
 * runs: it masks interrupts, since the table below has no interrupt entries
 * and the ROM's state is not known; clears MSPLIM, the ARMv8-M stack limit,
 * which a value left by the ROM could put above this image's stack; sets MSP
 * from the linker script; and points VTOR_S (0xE000ED08) at this table, so a
 * fault is taken here rather than through whatever table the ROM used. Then
 * it copies .data, zeroes .bss and runs the driver. Every exception is a
 * fault: it is reported on the console and the core stops.
 */
#include <stdint.h>

#include "bm.h"

extern uint32_t __data_load[], __data_start[], __data_end[];
extern uint32_t __bss_start[], __bss_end[];
extern uint32_t __stack_top[];

void Reset_Handler(void);
void bm_reset_c(void);
void bm_fault(void);

__attribute__((naked, noreturn)) void Reset_Handler(void)
{
	__asm volatile("cpsid i\n"
		       "movs r0, #0\n"
		       "msr msplim, r0\n"
		       "ldr r0, =__stack_top\n"
		       "msr msp, r0\n"
		       "ldr r0, =bm_vectors\n"
		       "ldr r1, =0xe000ed08\n"
		       "str r0, [r1]\n"
		       "dsb\n"
		       "isb\n"
		       "b bm_reset_c\n"
		       ".ltorg\n");
}

void bm_reset_c(void)
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
 * table stops there. Global so that Reset_Handler can name it. */
__attribute__((section(".vectors"), used))
void *const bm_vectors[16] = {
	(void *)__stack_top, (void *)Reset_Handler,
	(void *)bm_fault, (void *)bm_fault, (void *)bm_fault, (void *)bm_fault,
	(void *)bm_fault, (void *)bm_fault,
	0, 0, 0,
	(void *)bm_fault, (void *)bm_fault,
	0,
	(void *)bm_fault, (void *)bm_fault,
};
