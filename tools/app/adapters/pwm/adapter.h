/* tools/app/adapters/pwm/adapter.h -- the Pwm adapter over pwm-leds. */
#ifndef SPC_ADAPTER_PWM_H
#define SPC_ADAPTER_PWM_H
#include <stdint.h>
#include <zephyr/drivers/pwm.h>
int32_t spc_adapter_pwm_init(const struct pwm_dt_spec *table, uint32_t count);
/* Sets the pulse of channel `index` to value/65535 of its period; a value
 * above 65535 is clamped to the full period. */
int32_t spc_adapter_pwm_set(const struct pwm_dt_spec *table, uint32_t index, uint32_t value);
/* The safe state (0014 §4, failure): every channel at 0. */
void spc_adapter_pwm_safe(const struct pwm_dt_spec *table, uint32_t count);
#endif
