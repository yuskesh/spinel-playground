/* tools/app/adapters/led/adapter.c -- the Led adapter over gpio-leds.
 *
 * Non-blocking by construction over a memory-mapped controller: gpio_pin_set_dt
 * is one register write in the drivers the effect table attests (0014 §3). The
 * generated board_port.c holds the table of gpio_dt_spec, one per instance in
 * devicetree order, and the spc_board_<module>_<fn> functions that pass it
 * here; the same adapter serves a split module (an expander instance) with its
 * own table, and the effect table decides what that module may be called
 * from. */
#include "adapter.h"

int32_t spc_adapter_led_init(const struct gpio_dt_spec *table, uint32_t count)
{
	for (uint32_t i = 0; i < count; i++) {
		if (!gpio_is_ready_dt(&table[i])) {
			return -1;
		}
		if (gpio_pin_configure_dt(&table[i], GPIO_OUTPUT_INACTIVE) != 0) {
			return -1;
		}
	}
	return 0;
}

int32_t spc_adapter_led_set(const struct gpio_dt_spec *table, uint32_t index, uint32_t duty)
{
	return gpio_pin_set_dt(&table[index], duty != 0u ? 1 : 0) == 0 ? 0 : -1;
}

void spc_adapter_led_safe(const struct gpio_dt_spec *table, uint32_t count)
{
	for (uint32_t i = 0; i < count; i++) {
		(void)gpio_pin_set_dt(&table[i], 0);
	}
}
