/* generated board package for expander (decision 0014 §3): the tables
 * and the spc_board_<module>_<fn> functions over the class adapters. */
#include <stdint.h>
#include <zephyr/devicetree.h>
#include <zephyr/kernel.h>
#include <zephyr/drivers/gpio.h>
#include "adapters/clock/adapter.h"
#include "adapters/led/adapter.h"
#if defined(SPC_VERIFY)
/* a verification build (0014 §10) records each member call and its return,
 * the extern numbered as the trace numbers it: the board's members first, in
 * this order, then the channels', then the application's own */
#include "recorder.h"
#endif

/* Clock: 1 instance(s), isr_ok true, blocking false */
int64_t spc_board_clock_uptime_us(void)
{
#if defined(SPC_VERIFY)
	int64_t r;
	struct spc_rec_arg a[1] = { { 0, 0, 0, 0u } };

	spc_tr_XCALL(spc_rec_ctx, spc_rec_entry, 0u, 0u, a);
	r = spc_adapter_clock_uptime_us();
	spc_tr_XRET(spc_rec_ctx, spc_rec_entry, 0u, (int64_t)r);
	return r;
#else
	return spc_adapter_clock_uptime_us();
#endif
}
int64_t spc_board_clock_cycles(void)
{
#if defined(SPC_VERIFY)
	int64_t r;
	struct spc_rec_arg a[1] = { { 0, 0, 0, 0u } };

	spc_tr_XCALL(spc_rec_ctx, spc_rec_entry, 1u, 0u, a);
	r = spc_adapter_clock_cycles();
	spc_tr_XRET(spc_rec_ctx, spc_rec_entry, 1u, (int64_t)r);
	return r;
#else
	return spc_adapter_clock_cycles();
#endif
}
int32_t spc_board_clock_cycles32(void)
{
#if defined(SPC_VERIFY)
	int32_t r;
	struct spc_rec_arg a[1] = { { 0, 0, 0, 0u } };

	spc_tr_XCALL(spc_rec_ctx, spc_rec_entry, 2u, 0u, a);
	r = spc_adapter_clock_cycles32();
	spc_tr_XRET(spc_rec_ctx, spc_rec_entry, 2u, (int64_t)r);
	return r;
#else
	return spc_adapter_clock_cycles32();
#endif
}
/* Led: 2 instance(s), isr_ok true, blocking false */
const struct gpio_dt_spec spc_board_led_table[2] = {
	GPIO_DT_SPEC_GET(DT_PATH(leds, led_0), gpios), /* led_0: /leds/led_0 */
	GPIO_DT_SPEC_GET(DT_PATH(leds, led_1), gpios), /* led_1: /leds/led_1 */
};
const uint32_t spc_board_led_count = 2u;
int32_t spc_board_led_set(uint32_t index, uint32_t duty)
{
#if defined(SPC_VERIFY)
	int32_t r;
	struct spc_rec_arg a[2] = { { 0u, (int64_t)index, 0, 0u }, { 0u, (int64_t)duty, 0, 0u } };

	spc_tr_XCALL(spc_rec_ctx, spc_rec_entry, 3u, 2u, a);
	r = spc_adapter_led_set(spc_board_led_table, index, duty);
	spc_tr_XRET(spc_rec_ctx, spc_rec_entry, 3u, (int64_t)r);
	return r;
#else
	return spc_adapter_led_set(spc_board_led_table, index, duty);
#endif
}
int32_t spc_board_led_init(void)
{
	return spc_adapter_led_init(spc_board_led_table, 2u);
}
void spc_board_led_safe(void)
{
	spc_adapter_led_safe(spc_board_led_table, 2u);
}

/* LedI2c: 1 instance(s), isr_ok false, blocking true */
const struct gpio_dt_spec spc_board_ledi2c_table[1] = {
	GPIO_DT_SPEC_GET(DT_PATH(leds, led_ext), gpios), /* led_ext: /leds/led_ext */
};
const uint32_t spc_board_ledi2c_count = 1u;
int32_t spc_board_ledi2c_set(uint32_t index, uint32_t duty)
{
#if defined(SPC_VERIFY)
	int32_t r;
	struct spc_rec_arg a[2] = { { 0u, (int64_t)index, 0, 0u }, { 0u, (int64_t)duty, 0, 0u } };

	spc_tr_XCALL(spc_rec_ctx, spc_rec_entry, 4u, 2u, a);
	r = spc_adapter_led_set(spc_board_ledi2c_table, index, duty);
	spc_tr_XRET(spc_rec_ctx, spc_rec_entry, 4u, (int64_t)r);
	return r;
#else
	return spc_adapter_led_set(spc_board_ledi2c_table, index, duty);
#endif
}
int32_t spc_board_ledi2c_init(void)
{
	return spc_adapter_led_init(spc_board_ledi2c_table, 1u);
}
void spc_board_ledi2c_safe(void)
{
	spc_adapter_led_safe(spc_board_ledi2c_table, 1u);
}
