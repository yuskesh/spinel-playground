/* tools/app/adapters/clock/adapter.c -- the Clock adapter over the system
 * timer. Both reads are interrupt-safe kernel primitives. */
#include "adapter.h"
#include <zephyr/kernel.h>

int64_t spc_adapter_clock_uptime_us(void)
{
	return k_ticks_to_us_floor64(k_uptime_ticks());
}

int64_t spc_adapter_clock_cycles(void)
{
	return (int64_t)k_cycle_get_64();
}

/* The low 32 bits of the cycle counter, as the signed i32 pattern a 32-bit
 * body takes (decision 0022, the owner's decision of 2026-10-21): a body
 * computes a span with core_w32_sub, so the wrap is harmless while the span
 * is shorter than one period of the counter (17.9 s at 240 MHz). */
int32_t spc_adapter_clock_cycles32(void)
{
	return (int32_t)k_cycle_get_32();
}
