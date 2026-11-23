/* tools/app/adapters/clock/adapter.h -- the Clock adapter over the system timer. */
#ifndef SPC_ADAPTER_CLOCK_H
#define SPC_ADAPTER_CLOCK_H
#include <stdint.h>
/* Microseconds of uptime, from the kernel's tick count. */
int64_t spc_adapter_clock_uptime_us(void);
/* The free-running cycle counter of 0014 §4 (k_cycle_get_64, which needs
 * CONFIG_CORTEX_M_SYSTICK_64BIT_CYCLE_COUNTER=y on SysTick boards). */
int64_t spc_adapter_clock_cycles(void);
/* Its low 32 bits as a signed i32 pattern (k_cycle_get_32), for a 32-bit body
 * (decision 0022). */
int32_t spc_adapter_clock_cycles32(void);
#endif
