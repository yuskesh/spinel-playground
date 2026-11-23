/* stand-in: see README.md */
#ifndef STUB_ZEPHYR_PWM_H
#define STUB_ZEPHYR_PWM_H
#include <stdint.h>
#include <stdbool.h>
struct pwm_dt_spec { const void *dev; uint32_t channel; uint32_t period; uint32_t flags; };
#define PWM_DT_SPEC_GET(node) { 0, 0, 0, 0 }
bool pwm_is_ready_dt(const struct pwm_dt_spec *s);
int pwm_set_pulse_dt(const struct pwm_dt_spec *s, uint32_t pulse);
#endif
