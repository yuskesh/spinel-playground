/* tools/app/ring/cycles.h -- each core's cycle counter, for the stamp of a
 * put and the time of a get between the FRDM-IMXRT1186's cores (decision
 * 0027 stage 2; owner, 2026-10-26).
 *
 * The counter is the Cortex-M DWT's CYCCNT (0xE000_1004), at the core clock,
 * which is each build's CYCLES_PER_SECOND. A channel unit reads it with one
 * load and calls nothing. The glue turns it on at start, and touches nothing
 * else of the DWT: DEMCR.TRCENA (bit 24 of 0xE000_EDFC) and DWT_CTRL.CYCCNTENA
 * (bit 0 of 0xE000_1000), each set by an OR, so a debugger that already
 * turned them on, or uses the DWT's other functions, is left as it was; the
 * counter is never written. An implementation without the counter says so
 * in DWT_CTRL.NOCYCCNT (bit 25), and the alignment is then not made.
 *
 * A host harness (SPC_RING_HOST) supplies spc_host_cycles() instead. */
#ifndef SPC_CYCLES_H
#define SPC_CYCLES_H
#include <stdint.h>

#define SPC_DWT_CTRL (*(volatile uint32_t *)0xE0001000u)
#define SPC_DWT_CYCCNT (*(volatile uint32_t *)0xE0001004u)
#define SPC_DEMCR (*(volatile uint32_t *)0xE000EDFCu)
#define SPC_DEMCR_TRCENA (1u << 24)
#define SPC_DWT_CTRL_CYCCNTENA (1u << 0)
#define SPC_DWT_CTRL_NOCYCCNT (1u << 25)

#if defined(SPC_RING_HOST)
uint32_t spc_host_cycles(void);
static inline uint32_t spc_cycles(void)
{
	return spc_host_cycles();
}
#else
static inline uint32_t spc_cycles(void)
{
	return SPC_DWT_CYCCNT;
}

/* the glue's, at start: 1 when the counter runs, 0 when there is none */
static inline uint32_t spc_cycles_start(void)
{
	SPC_DEMCR |= SPC_DEMCR_TRCENA;
	__asm__ volatile("dsb" ::: "memory");
	if (SPC_DWT_CTRL & SPC_DWT_CTRL_NOCYCCNT) {
		return 0u;
	}
	SPC_DWT_CTRL |= SPC_DWT_CTRL_CYCCNTENA;
	return 1u;
}
#endif
#endif
