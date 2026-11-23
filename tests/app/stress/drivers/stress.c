/* The content-failure counter of decision 0014 Task 12, an ordinary
 * application provider: no allocation, no blocking call, no interrupt
 * configuration, and no call outside this file -- a provider's evidence is
 * its own frame (tools/app/lib/core_app/pipeline.rb, step 5). The
 * application's checks call it where they see a torn message or a
 * half-written cross-context word; `seen` counts what the inbound consumer
 * received. Nothing is printed here: `check` runs on the 224-byte scheduler
 * stack, where printk's path overran into the transport thread's stack. The
 * build's sampling source (--stress, tools/app/templates/stress_timer.c.erb)
 * reads these words on every sample and prints the lines stress.sh reads,
 * STRESS_FAIL and STRESS_SEEN, in the form they always had, from the
 * interrupt stack. The sampling is that source's too, not this file's: a
 * sampler called from an interrupt entry sees only tick boundaries. */
#include <stdint.h>

/* per kind (1 a torn message, 2 a half-written shared word, 3 a sequence
 * that did not rise); any other kind is counted in [0]. One writer each: the
 * consumer (interrupt) reports 1 and 3, `check` (thread) reports 2 */
volatile uint32_t spc_stress_fails[4];
/* every 1000th message received: the count, its sequence and the three
 * failure counts at that moment, published by `spc_stress_marks` after the
 * five words are written */
volatile uint32_t spc_stress_mark[5];
volatile uint32_t spc_stress_marks;
/* one more for every change to the words above: the sampler reads only this
 * word on a sample with nothing new to print. Two contexts add to it, so the
 * add is atomic (ldrex/strex on the M33, no call) */
volatile uint32_t spc_stress_events;
static uint32_t spc_stress_seen;

int32_t spc_app_stress_fail(uint32_t kind)
{
	spc_stress_fails[kind < 4u ? kind : 0u]++;
	__atomic_fetch_add(&spc_stress_events, 1u, __ATOMIC_RELAXED);
	return 0;
}

int32_t spc_app_stress_seen(uint32_t seq)
{
	spc_stress_seen++;
	if ((spc_stress_seen % 1000u) == 0u) {
		spc_stress_mark[0] = spc_stress_seen;
		spc_stress_mark[1] = seq;
		spc_stress_mark[2] = spc_stress_fails[1];
		spc_stress_mark[3] = spc_stress_fails[2];
		spc_stress_mark[4] = spc_stress_fails[3];
		__asm__ volatile("" ::: "memory"); /* the five words before the count that publishes them */
		spc_stress_marks = spc_stress_marks + 1u;
		__atomic_fetch_add(&spc_stress_events, 1u, __ATOMIC_RELAXED);
	}
	return 0;
}
