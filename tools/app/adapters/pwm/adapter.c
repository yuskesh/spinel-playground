/* tools/app/adapters/pwm/adapter.c -- the Pwm adapter over pwm-leds.
 *
 * pwm_set_pulse_dt programs the channel's compare register on the
 * memory-mapped drivers the effect table attests; the value is a 16-bit
 * fraction of the devicetree period, so the caller never names a time. */
#include "adapter.h"

int32_t spc_adapter_pwm_init(const struct pwm_dt_spec *table, uint32_t count)
{
	for (uint32_t i = 0; i < count; i++) {
		if (!pwm_is_ready_dt(&table[i])) {
			return -1;
		}
		if (pwm_set_pulse_dt(&table[i], 0) != 0) {
			return -1;
		}
	}
	return 0;
}

int32_t spc_adapter_pwm_set(const struct pwm_dt_spec *table, uint32_t index, uint32_t value)
{
	uint32_t v = value > 65535u ? 65535u : value;
	uint32_t pulse = (uint32_t)(((uint64_t)table[index].period * v) / 65535u);

	return pwm_set_pulse_dt(&table[index], pulse) == 0 ? 0 : -1;
}

void spc_adapter_pwm_safe(const struct pwm_dt_spec *table, uint32_t count)
{
	for (uint32_t i = 0; i < count; i++) {
		(void)pwm_set_pulse_dt(&table[i], 0);
	}
}
