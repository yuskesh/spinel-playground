/* Reserve harness (decision 0014 §9, Task 9): paints its stacks, drives every
 * reserved path, and compares the high-water marks with the reserves it was
 * built against. See ../README.md. Never linked into a deliverable. */
#include <stdint.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/device.h>
#include <zephyr/drivers/uart.h>
#include <zephyr/sys/printk.h>
#include "reserves.h" /* SPC_RESERVE_* from reserves.tsv, for this board */

#define WORKER_STACK 1024
static K_THREAD_STACK_DEFINE(worker_stack, WORKER_STACK);
static struct k_thread worker;
static struct k_timer probe_timer;
static volatile uint32_t expiries;
static volatile uint32_t spins;

/* the harness's own frames on the reserved paths, from its .su file, are
 * passed by reserves.sh as SPC_HARNESS_* so the comparison subtracts them */
#ifndef SPC_HARNESS_WORKER_FRAMES
#define SPC_HARNESS_WORKER_FRAMES 0
#endif
#ifndef SPC_HARNESS_EXPIRY_FRAMES
#define SPC_HARNESS_EXPIRY_FRAMES 0
#endif

static void expiry(struct k_timer *t)
{
	(void)t;
	expiries++;
}

/* the interrupt stack: painted again by the worker before it drives the
 * paths (with interrupts locked, no handler is active, so the whole buffer
 * is free), so the mark read afterwards is this run's, not the boot's */
extern K_KERNEL_STACK_ARRAY_DECLARE(z_interrupt_stacks, CONFIG_MP_MAX_NUM_CPUS, CONFIG_ISR_STACK_SIZE);
static void isr_stack_paint(void)
{
	uint8_t *base = (uint8_t *)K_KERNEL_STACK_BUFFER(z_interrupt_stacks[0]);
	size_t size = K_KERNEL_STACK_SIZEOF(z_interrupt_stacks[0]);
	unsigned int key = irq_lock();

	memset(base, 0xAA, size);
	irq_unlock(key);
}
static size_t isr_stack_used(void)
{
	const uint8_t *base = (const uint8_t *)K_KERNEL_STACK_BUFFER(z_interrupt_stacks[0]);
	size_t size = K_KERNEL_STACK_SIZEOF(z_interrupt_stacks[0]);
	size_t unused = 0;

	while (unused < size && base[unused] == 0xAAu) {
		unused++;
	}
	return size - unused;
}

static void worker_entry(void *a, void *b, void *c)
{
	const struct device *uart = DEVICE_DT_GET(DT_CHOSEN(zephyr_console));
	uint8_t byte;

	(void)a; (void)b; (void)c;
	isr_stack_paint();
	/* thread_switch + thread_kernel_calls: sleep, so PendSV switches away
	 * and back with the hardware frame on this stack */
	k_sleep(K_MSEC(2));
	/* timer_dispatch: a timer expires while this thread spins (busy work,
	 * so SysTick preempts a running thread), then with the thread waiting
	 * on it (z_ready_thread on the dispatch path) */
	k_timer_init(&probe_timer, expiry, NULL);
	k_timer_start(&probe_timer, K_MSEC(1), K_MSEC(1));
	for (uint32_t i = 0; i < 400000u && expiries < 5u; i++) {
		spins++;
	}
	k_timer_status_sync(&probe_timer);
	k_timer_stop(&probe_timer);
	/* uart_calls: the transport's polling calls */
	uart_poll_out(uart, '.');
	(void)uart_poll_in(uart, &byte);
	k_sleep(K_MSEC(1));
}

int main(void)
{
	size_t worker_unused = 0, worker_used, isr_used;
	int refuted = 0;
	/* the worker's requirement: the frames it has on the path plus the
	 * attested terms of the thread inequality (0014 §9, R) */
	const size_t worker_budget = SPC_HARNESS_WORKER_FRAMES + SPC_RESERVE_THREAD_SWITCH +
				     SPC_RESERVE_THREAD_KERNEL_CALLS + SPC_RESERVE_UART_CALLS +
				     SPC_RESERVE_GUARD_AREA;
	/* the interrupt stack: the deepest chain this run forces is SysTick's
	 * dispatch with the expiry function on top, entered over a thread
	 * (its hardware frame is on the thread's stack, not here). This is not
	 * the full interrupt inequality of 0014 section 9, which sums nested
	 * entries with their hardware frames on this stack: the run forces no
	 * nesting, and says so in the README. pendsv is the context switch's
	 * cost on this stack, 0 in this configuration. */
	const size_t isr_budget = SPC_RESERVE_ISR_ENTRY_EXIT + SPC_RESERVE_TIMER_DISPATCH +
				  SPC_RESERVE_PENDSV + SPC_HARNESS_EXPIRY_FRAMES;

	k_thread_create(&worker, worker_stack, WORKER_STACK, worker_entry, NULL, NULL, NULL,
			K_PRIO_PREEMPT(1), 0, K_NO_WAIT);
	k_thread_join(&worker, K_FOREVER);
	if (k_thread_stack_space_get(&worker, &worker_unused) != 0) {
		printk("RESERVES_ERROR stack_space_get failed\n");
		return 1;
	}
	worker_used = WORKER_STACK - worker_unused;
	isr_used = isr_stack_used();
	printk("RESERVES worker_used=%u worker_budget=%u isr_used=%u isr_budget=%u expiries=%u\n",
	       (unsigned)worker_used, (unsigned)worker_budget, (unsigned)isr_used, (unsigned)isr_budget,
	       (unsigned)expiries);
	if (worker_used > worker_budget) {
		printk("RESERVES_REFUTED worker: %u used, %u reserved\n", (unsigned)worker_used, (unsigned)worker_budget);
		refuted = 1;
	}
	if (isr_used > isr_budget) {
		printk("RESERVES_REFUTED isr: %u used, %u reserved\n", (unsigned)isr_used, (unsigned)isr_budget);
		refuted = 1;
	}
	printk("%s\n", refuted ? "RESERVES_REFUTED_END" : "RESERVES_HELD");
	return 0;
}
