/* The settling probe (decision 0014, Task 10's list: "the 16 interrupt-stack
 * bytes the Task 9 harness does not explain"). It is NOT the reserve harness
 * and no suite runs it: it drives one path only, the system timer's dispatch,
 * and its question is whether the residual bytes are a nested entry's
 * hardware frame (hypothesis 1) or cost inside the dispatch path itself,
 * invisible to the `.su` frames (hypothesis 2). It is kept because the
 * conclusion recorded in 0014 rests on it and has to be reproducible.
 *
 * Three modes, the same image except for SPC_FORCE_NESTING:
 *
 *   excluded (0): the worker holds the scheduler lock and spins while a 1 ms
 *   timer expires. The expiry readies nothing, so no PendSV is ever pending
 *   and every SysTick entry is taken over a running thread, whose hardware
 *   frame lands on the thread's stack, not here.
 *
 *   forced (1): two threads of equal preemptive priority yield to each other
 *   as fast as they can, so PendSV is running a context switch for a large
 *   fraction of the time, while the same 1 ms timer expires. A SysTick entry
 *   taken while PendSV is active pushes its hardware frame onto THIS stack.
 *
 *   depth (3): the excluded run again, with one measurement inside the
 *   callback -- how much of this stack is LIVE when the expiry function runs.
 *   The instrumented callback has a frame of its own, 8 bytes against 0 in
 *   the other modes (this unit's .su), and the reading includes it.
 *
 * Every mode paints the interrupt stack immediately before its window and
 * reads the high-water mark immediately after it, with nothing in between
 * that could touch the stack (no printk, no sleep). Slicing is off in all.
 *
 * Predictions, stated before the run (0014): under (1) excluded marks about
 * 96 and forced at most 96 + 36 = 132; under (2) excluded still marks 112.
 *
 * Measured on Debian, mps2/an521 under QEMU, 2026-09-23:
 *   excluded 112, forced 144, depth_at_callback 73 (excluded 112 again).
 *
 * Neither prediction. Forced - excluded is 32, exactly one Cortex-M hardware
 * exception frame, so nesting IS visible to this method and the excluded run
 * has none of it -- hypothesis 1 does not explain the 112. Nor is the 112
 * invisible cost. The branch actually taken is
 *
 *   sys_clock_isr 16 + sys_clock_announce_locked 32 +
 *   z_timer_expiration_handler 24 + z_add_timeout 40 = 112,
 *
 * the mark exactly. z_add_timeout (40) is the PERIODIC timer re-arming
 * itself, and it runs on the ENTRY path, BEFORE the callback: kernel/timer.c
 * line 107 at the pin, against expiry_fn at line 125. There is no
 * _isr_wrapper frame, because CONFIG_CORTEX_M_SYSTICK_INSTALL_ISR=y puts
 * sys_clock_isr in the vector table itself.
 *
 * What depth_at_callback = 73 establishes, and what it does not: it is what
 * is LIVE when the callback body runs -- 72 (16 + 32 + 24) plus one byte into
 * this unit's 8-byte `expiry` frame in the instrumented build. It confirms
 * that nothing is missing below the callback and that z_add_timeout's frame
 * is not live there. It cannot say WHEN the other 40 bytes were spent, and
 * they were spent before the callback, not after it.
 *
 * So the `.su` sum accounts for this mark to the byte. What was incomplete
 * was the enumeration of the k_timer branch in 0014's observation, which
 * omitted the re-arm and counted z_ready_thread + ready_thread (24) in its
 * place: 40 - 24 = 16, the residual.
 */
#include <stdint.h>
#include <string.h>
#include <zephyr/kernel.h>
#include <zephyr/sys/printk.h>

#ifndef SPC_FORCE_NESTING
#define SPC_FORCE_NESTING 0
#endif
/* mode 3 is the excluded run with the callback-depth measurement */
#define SPC_EXCLUDED (SPC_FORCE_NESTING == 0 || SPC_FORCE_NESTING == 3)
#ifndef SPC_EXPIRIES
#define SPC_EXPIRIES 20u
#endif

#define WORKER_STACK 1024
static K_THREAD_STACK_DEFINE(worker_stack, WORKER_STACK);
static K_THREAD_STACK_DEFINE(peer_stack, WORKER_STACK);
static struct k_thread worker;
static struct k_thread peer;
static struct k_timer probe_timer;
static volatile uint32_t expiries;
static volatile uint32_t spins;
static volatile uint32_t yields;
static volatile int window_open;
static size_t isr_used;

/* mode 3 adds one measurement inside the callback: how much of the interrupt
 * stack is live when the expiry function runs, which names what sits BELOW
 * the callback (the entry, the announce and the expiration handler). It says
 * nothing about when the rest of the mark was spent: the periodic re-arm runs
 * before the callback, not after it. The instrumented callback's own frame is
 * 8 bytes, against 0 in the other modes. */
#if SPC_FORCE_NESTING == 3
static volatile uint32_t depth_at_callback;
#endif

extern K_KERNEL_STACK_ARRAY_DECLARE(z_interrupt_stacks, CONFIG_MP_MAX_NUM_CPUS, CONFIG_ISR_STACK_SIZE);

static void expiry(struct k_timer *t)
{
	(void)t;
#if SPC_FORCE_NESTING == 3
	{
		uint8_t here;
		uintptr_t top = (uintptr_t)K_KERNEL_STACK_BUFFER(z_interrupt_stacks[0]) +
				K_KERNEL_STACK_SIZEOF(z_interrupt_stacks[0]);
		uint32_t d = (uint32_t)(top - (uintptr_t)&here);

		if (d > depth_at_callback) {
			depth_at_callback = d;
		}
	}
#endif
	expiries++;
}

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

/* the peer of the forced mode: it only yields, so the pair keeps PendSV busy */
static void peer_entry(void *a, void *b, void *c)
{
	(void)a; (void)b; (void)c;
	while (window_open) {
		yields++;
		k_yield();
	}
}

static void worker_entry(void *a, void *b, void *c)
{
	(void)a; (void)b; (void)c;

#if !SPC_EXCLUDED
	window_open = 1;
	k_thread_create(&peer, peer_stack, WORKER_STACK, peer_entry, NULL, NULL, NULL,
			K_PRIO_PREEMPT(1), 0, K_NO_WAIT);
	/* the peer is created and ready; the window starts with the paint */
	isr_stack_paint();
	k_timer_init(&probe_timer, expiry, NULL);
	k_timer_start(&probe_timer, K_MSEC(1), K_MSEC(1));
	while (expiries < SPC_EXPIRIES) {
		yields++;
		k_yield();
	}
	k_timer_stop(&probe_timer);
	isr_used = isr_stack_used();
	window_open = 0;
#else
	/* the scheduler lock is taken BEFORE the paint and released after the
	 * mark is read: inside the window no thread can be readied and no
	 * PendSV can be pending, so no SysTick entry can nest over one */
	k_sched_lock();
	isr_stack_paint();
	k_timer_init(&probe_timer, expiry, NULL);
	k_timer_start(&probe_timer, K_MSEC(1), K_MSEC(1));
	while (expiries < SPC_EXPIRIES) {
		spins++;
	}
	k_timer_stop(&probe_timer);
	isr_used = isr_stack_used();
	k_sched_unlock();
#endif
}

int main(void)
{
	k_thread_create(&worker, worker_stack, WORKER_STACK, worker_entry, NULL, NULL, NULL,
			K_PRIO_PREEMPT(1), 0, K_NO_WAIT);
	k_thread_join(&worker, K_FOREVER);
#if !SPC_EXCLUDED
	k_thread_join(&peer, K_FOREVER);
#endif
#if SPC_FORCE_NESTING == 3
	printk("SETTLE depth_at_callback=%u\n", (unsigned)depth_at_callback);
#endif
	printk("SETTLE mode=%s isr_used=%u expiries=%u spins=%u yields=%u isr_size=%u\n",
	       SPC_EXCLUDED ? "excluded" : "forced", (unsigned)isr_used,
	       (unsigned)expiries, (unsigned)spins, (unsigned)yields,
	       (unsigned)CONFIG_ISR_STACK_SIZE);
	printk("SETTLE_END\n");
	return 0;
}
